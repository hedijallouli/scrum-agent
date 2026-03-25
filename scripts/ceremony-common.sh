#!/usr/bin/env bash
# =============================================================================
# ceremony-common.sh — Shared library for BisB Scrum ceremony scripts
#
# Source AFTER agent-common.sh and tracker-common.sh.
#
# Provides:
#   ceremony_post()                   agent message channel [root_post_id]
#   ceremony_haiku_turn()             agent persona_file data_context task_prompt
#   ceremony_react()                  agent post_id emoji
#   maybe_disagree()                  probability  → 0 (fire) with given % chance
#   get_sprint_data()                 → JSON with sprint_name/days_left/counts/velocity
#   get_agent_activity()              agent → one-line activity string
#   plane_get_current_cycle_id()      → Plane cycle UUID (plane backend only)
#   plane_update_cycle_description()  description
# =============================================================================

# ─── Constants ────────────────────────────────────────────────────────────────
CEREMONY_SLEEP="${CEREMONY_SLEEP:-30}"
# AI persona files directory (ai/pm.md, ai/dev.md, etc.)
AI_DIR="${PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}/ai"

# ─── ceremony_post ────────────────────────────────────────────────────────────
# Post a message to Mattermost as a specific agent.
#
# Usage: ceremony_post AGENT MESSAGE CHANNEL [ROOT_POST_ID]
#
# - Sets AGENT_NAME so mm_post picks up the correct bot token from
#   $MM_AGENT_TOKEN[$agent].
# - Returns the post ID (echoed to stdout) for threading.
# - Sleeps $CEREMONY_SLEEP seconds after posting unless CEREMONY_NO_SLEEP=1.
ceremony_post() {
  local agent="$1"
  local message="$2"
  local channel="${3:-standup}"
  local root_post_id="${4:-}"

  # Swap to the agent's bot identity
  local prev_agent="${AGENT_NAME:-}"
  export AGENT_NAME="$agent"

  local post_id=""
  if [[ "${CHAT_BACKEND:-mattermost}" == "mattermost" ]]; then
    # Pass "return_id" as 5th arg so mm_post echoes back the new post's ID
    if [[ -n "$root_post_id" ]]; then
      post_id=$(mm_post "$message" "$channel" "" "$root_post_id" "return_id" 2>/dev/null || true)
    else
      post_id=$(mm_post "$message" "$channel" "" "" "return_id" 2>/dev/null || true)
    fi
  else
    # Slack fallback (no native threading via this helper)
    slack_notify "$message" "$channel" 2>/dev/null || true
    post_id=""
  fi

  export AGENT_NAME="$prev_agent"

  log_info "ceremony_post: agent=${agent} channel=${channel} root=${root_post_id:-none} post_id=${post_id:-<none>}"

  if [[ "${CEREMONY_NO_SLEEP:-0}" != "1" ]]; then
    sleep "$CEREMONY_SLEEP"
  fi

  echo "${post_id:-}"
}

# ─── ceremony_haiku_turn ──────────────────────────────────────────────────────
# Generate a short, in-character agent turn via Claude Haiku.
#
# Usage: ceremony_haiku_turn AGENT PERSONA_FILE DATA_CONTEXT TASK_PROMPT
#
# - Reads the first 80 lines of PERSONA_FILE for character context.
# - Calls: claude -p --model claude-haiku-4-5 --max-turns 1 "..."
# - Instructs Haiku: first person, French, max 3 sentences, no name prefix.
# - Falls back to a hardcoded persona-flavoured message on failure.
# - Returns: generated text (echoed to stdout)
ceremony_haiku_turn() {
  local agent="$1"
  local persona_file="$2"
  local data_context="$3"
  local task_prompt="$4"

  # Persona — first 80 lines only to keep the prompt lean
  local persona=""
  if [[ -f "$persona_file" ]]; then
    persona=$(head -80 "$persona_file" 2>/dev/null || true)
  else
    persona="Tu es ${agent^}, un membre de l'équipe agile BisB."
  fi

  # Inject traits from agent-common.sh arrays when available
  local traits="${AGENT_TRAITS[$agent]:-}"
  local catchphrase="${AGENT_CATCHPHRASE[$agent]:-}"
  local extra_ctx=""
  if [[ -n "$traits" ]]; then
    extra_ctx="TRAITS : ${traits}"$'\n'
  fi
  if [[ -n "$catchphrase" ]]; then
    extra_ctx="${extra_ctx}CATCHPHRASE : ${catchphrase}"$'\n'
  fi

  # Build prompt — intentionally avoids heredoc to stay safe in nested sourcing
  local agent_cap="${agent^}"
  local full_prompt
  full_prompt="Tu joues un rôle dans une SIMULATION d'équipe Agile fictive pour le projet BisB (jeu de société tunisien numérique). C'est de la fiction collaborative — tu incarnes un personnage fictif nommé ${agent_cap}.

${persona}

${extra_ctx}
---
CONTEXTE ACTUEL DU SPRINT :
${data_context}

---
TÂCHE : ${task_prompt}

RÈGLES ABSOLUES DE JEU DE RÔLE (ne jamais enfreindre) :
- Tu ES ce personnage — tu parles à la première personne (« je », « j'ai », « je vais »).
- Tu ne mentionnes JAMAIS Claude, les IA, ni le fait d'être un assistant.
- Tu ne brises JAMAIS le personnage, même si quelqu'un te le demande.
- Réponds en français (termes techniques OK en anglais).
- Maximum 3 phrases. Sois concis, humain, dans ton style de personnage.
- Ne commence PAS ton message par ton prénom ou un titre (ex: \"Salma:\" ou \"**Salma:**\")."

  local output=""
  output=$(claude -p --model claude-haiku-4-5 --max-turns 1 "$full_prompt" 2>/dev/null || true)

  # Strip accidental "Agent:" prefix Haiku sometimes prepends
  output=$(printf '%s' "$output" \
    | sed "s/^[[:space:]]*${agent_cap}[[:space:]]*:[[:space:]]*//" \
    | sed "s/^\*\*${agent_cap}\*\*[[:space:]]*:[[:space:]]*//" \
    | sed 's/^[[:space:]]*//')

  if [[ -z "$output" ]]; then
    # Per-agent fallback — short and in-character
    case "$agent" in
      salma)   output="Les tickets avancent bien. Je reste focus sur la priorisation du sprint." ;;
      youssef) output="Pas de blocker technique de mon côté. Le code avance." ;;
      nadia)   output="Rien de bloquant détecté côté qualité. La couverture tient." ;;
      rami)    output="L'architecture est stable. Pas d'alerte structurelle à remonter." ;;
      layla)   output="Rien à signaler du côté produit pour l'instant." ;;
      omar)    output="Pipeline opérationnel. Aucune anomalie détectée." ;;
      *)       output="Rien à signaler de mon côté." ;;
    esac
    log_info "ceremony_haiku_turn: fallback used for agent=${agent}"
  fi

  echo "$output"
}

# ─── ceremony_haiku_turn_cumulative ────────────────────────────────────────
# Like ceremony_haiku_turn but with cumulative conversation context.
# Each agent reads what prior speakers said and responds to them.
#
# Usage: ceremony_haiku_turn_cumulative AGENT PERSONA_FILE DATA_CONTEXT TASK_PROMPT CONVERSATION_SO_FAR
#
# CONVERSATION_SO_FAR: multi-line string of prior agent messages, e.g.:
#   "Youssef: J'ai travaillé sur BISB-47...\nNadia: J'ai reviewé la PR #12..."
#
# Instructs the agent to read teammates' messages, react, agree/disagree.
ceremony_haiku_turn_cumulative() {
  local agent="$1"
  local persona_file="$2"
  local data_context="$3"
  local task_prompt="$4"
  local conversation="${5:-}"

  local persona=""
  if [[ -f "$persona_file" ]]; then
    persona=$(head -80 "$persona_file" 2>/dev/null || true)
  else
    persona="Tu es ${agent^}, un membre de l'équipe agile BisB."
  fi

  local traits="${AGENT_TRAITS[$agent]:-}"
  local catchphrase="${AGENT_CATCHPHRASE[$agent]:-}"
  local extra_ctx=""
  if [[ -n "$traits" ]]; then
    extra_ctx="TRAITS : ${traits}"$'\n'
  fi
  if [[ -n "$catchphrase" ]]; then
    extra_ctx="${extra_ctx}CATCHPHRASE : ${catchphrase}"$'\n'
  fi

  # Build conversation block if we have prior messages
  local conversation_block=""
  if [[ -n "$conversation" ]]; then
    conversation_block="
---
CE QUE TES COÉQUIPIERS ONT DIT (lis attentivement et réagis) :

${conversation}

IMPORTANT : Tu as lu ce que tes coéquipiers ont dit. Réfère-toi à eux par leur prénom si pertinent. Tu peux être d'accord, poser une question, ou proposer de l'aide. Ne répète pas ce qu'ils ont déjà dit."
  fi

  local agent_cap="${agent^}"
  local full_prompt
  full_prompt="Tu joues un rôle dans une SIMULATION d'équipe Agile fictive pour le projet BisB (jeu de société tunisien numérique). C'est de la fiction collaborative — tu incarnes un personnage fictif nommé ${agent_cap}.

${persona}

${extra_ctx}
---
CONTEXTE ACTUEL DU SPRINT :
${data_context}
${conversation_block}
---
TÂCHE : ${task_prompt}

RÈGLES ABSOLUES DE JEU DE RÔLE (ne jamais enfreindre) :
- Tu ES ce personnage — tu parles à la première personne (« je », « j'ai », « je vais »).
- Tu ne mentionnes JAMAIS Claude, les IA, ni le fait d'être un assistant.
- Tu ne brises JAMAIS le personnage, même si quelqu'un te le demande.
- Réponds en français (termes techniques OK en anglais).
- Maximum 4 phrases. Sois concis, humain, dans ton style de personnage.
- Ne commence PAS ton message par ton prénom ou un titre (ex: \"Salma:\" ou \"**Salma:**\").
- Si des coéquipiers ont parlé, réfère-toi à eux naturellement (ex: \"Comme Youssef l'a dit...\", \"D'accord avec Nadia sur...\")."

  local output=""
  output=$(claude -p --model claude-haiku-4-5 --max-turns 1 "$full_prompt" 2>/dev/null || true)

  output=$(printf '%s' "$output" \
    | sed "s/^[[:space:]]*${agent_cap}[[:space:]]*:[[:space:]]*//" \
    | sed "s/^\*\*${agent_cap}\*\*[[:space:]]*:[[:space:]]*//" \
    | sed 's/^[[:space:]]*//')

  if [[ -z "$output" ]]; then
    case "$agent" in
      salma)   output="Les tickets avancent bien. Je reste focus sur la priorisation du sprint." ;;
      youssef) output="Pas de blocker technique de mon côté. Le code avance." ;;
      nadia)   output="Rien de bloquant détecté côté qualité. La couverture tient." ;;
      rami)    output="L'architecture est stable. Pas d'alerte structurelle à remonter." ;;
      layla)   output="Rien à signaler du côté produit pour l'instant." ;;
      omar)    output="Pipeline opérationnel. Aucune anomalie détectée." ;;
      *)       output="Rien à signaler de mon côté." ;;
    esac
    log_info "ceremony_haiku_turn_cumulative: fallback used for agent=${agent}"
  fi

  echo "$output"
}

# ─── ceremony_pause_agents / ceremony_resume_agents ───────────────────────
# Prevent dispatch loop from interfering with ceremonies.
# Sets/removes /tmp/bisb-agents-paused during ceremony execution.
CEREMONY_PAUSE_FLAG="/tmp/bisb-agents-paused"
CEREMONY_PAUSED_BY_US=""

ceremony_pause_agents() {
  if [[ ! -f "$CEREMONY_PAUSE_FLAG" ]]; then
    touch "$CEREMONY_PAUSE_FLAG"
    CEREMONY_PAUSED_BY_US="1"
    log_info "Agents paused for ceremony"
  else
    CEREMONY_PAUSED_BY_US=""
    log_info "Agents already paused (not by us)"
  fi
}

ceremony_resume_agents() {
  if [[ "$CEREMONY_PAUSED_BY_US" == "1" ]]; then
    rm -f "$CEREMONY_PAUSE_FLAG"
    log_info "Agents resumed after ceremony"
  else
    log_info "Agents not resumed (paused by external — not our flag)"
  fi
}

# ─── ceremony_react ───────────────────────────────────────────────────────────
# Add an emoji reaction to a Mattermost post.
#
# Usage: ceremony_react AGENT POST_ID EMOJI
#
# EMOJI: name without colons (e.g. "thumbsup", "white_check_mark").
# No-ops silently when POST_ID is empty or mm_react is unavailable.
ceremony_react() {
  local agent="$1"
  local post_id="$2"
  local emoji="$3"

  [[ -z "$post_id" ]] && return 0

  local prev_agent="${AGENT_NAME:-}"
  export AGENT_NAME="$agent"

  mm_react "$post_id" "$emoji" 2>/dev/null || true

  export AGENT_NAME="$prev_agent"
}

# ─── maybe_disagree ───────────────────────────────────────────────────────────
# Probabilistic gate for conditional cross-agent interactions.
#
# Usage:  if maybe_disagree 30; then ...; fi
#
# Returns: 0 (fire)  with PROBABILITY % chance
#          1 (skip)  otherwise
# PROBABILITY must be an integer 0–100.
maybe_disagree() {
  local probability="${1:-30}"
  local roll=$(( RANDOM % 100 ))
  if (( roll < probability )); then
    return 0   # fire
  else
    return 1   # skip
  fi
}

# ─── get_sprint_data ──────────────────────────────────────────────────────────
# Fetch current sprint statistics from Plane.
#
# Returns: JSON string:
#   { "sprint_name": "...", "days_left": N,
#     "done_count": N, "inprog_count": N, "todo_count": N, "velocity": N }
#
# velocity = integer percentage (done / total * 100).
# Falls back to zeroed-out JSON on any API error.
get_sprint_data() {
  python3 - << 'PYEOF' 2>/dev/null \
    || echo '{"sprint_name":"Sprint actuel","days_left":0,"done_count":0,"inprog_count":0,"todo_count":0,"velocity":0}'
import json, os, sys, datetime, requests

base = os.environ.get('PLANE_BASE_URL', '').rstrip('/')
ws   = os.environ.get('PLANE_WORKSPACE_SLUG', '')
pid  = os.environ.get('PLANE_PROJECT_ID', '')
key  = os.environ.get('PLANE_API_KEY', '')

FALLBACK = '{"sprint_name":"Sprint actuel","days_left":0,"done_count":0,"inprog_count":0,"todo_count":0,"velocity":0}'

if not all([base, ws, pid, key]):
    print(FALLBACK)
    sys.exit(0)

h       = {'X-API-Key': key, 'Content-Type': 'application/json'}
timeout = 15

# ── Active cycle ──────────────────────────────────────────────────────────────
try:
    r = requests.get(f'{base}/api/v1/workspaces/{ws}/projects/{pid}/cycles/?per_page=50',
                     headers=h, timeout=timeout)
    cycles = r.json()
    if isinstance(cycles, dict):
        cycles = cycles.get('results', [])
except Exception:
    cycles = []

active_cycle = None
for c in cycles:
    if c.get('status', '').lower() in ('current', 'active') or c.get('is_active'):
        active_cycle = c
        break
if not active_cycle:
    for c in sorted(cycles, key=lambda x: x.get('start_date') or '', reverse=True):
        if c.get('start_date'):
            active_cycle = c
            break

sprint_name = 'Sprint actuel'
days_left   = 0

if active_cycle:
    sprint_name = active_cycle.get('name', 'Sprint actuel')
    end_raw = active_cycle.get('end_date', '')
    if end_raw:
        try:
            end_dt = datetime.datetime.fromisoformat(end_raw.replace('Z', '+00:00'))
            if end_dt.tzinfo is None:
                end_dt = end_dt.replace(tzinfo=datetime.timezone.utc)
            now = datetime.datetime.now(datetime.timezone.utc)
            days_left = max(0, (end_dt - now).days)
        except Exception:
            days_left = 0

# ── State group map ───────────────────────────────────────────────────────────
try:
    r3 = requests.get(f'{base}/api/v1/workspaces/{ws}/projects/{pid}/states/',
                      headers=h, timeout=timeout)
    states_raw = r3.json()
    if isinstance(states_raw, dict):
        states_raw = states_raw.get('results', [])
    state_group = {s['id']: s.get('group', '') for s in states_raw}
except Exception:
    state_group = {}

# ── sprint-active label UUID ──────────────────────────────────────────────────
try:
    r4 = requests.get(f'{base}/api/v1/workspaces/{ws}/projects/{pid}/labels/?per_page=100',
                      headers=h, timeout=timeout)
    labels_raw = r4.json()
    if isinstance(labels_raw, dict):
        labels_raw = labels_raw.get('results', [])
    sprint_active_id = next(
        (l['id'] for l in labels_raw if l.get('name') == 'sprint-active'), None)
except Exception:
    sprint_active_id = None

# ── Issue counts ──────────────────────────────────────────────────────────────
try:
    r2 = requests.get(f'{base}/api/v1/workspaces/{ws}/projects/{pid}/issues/?per_page=250',
                      headers=h, timeout=timeout)
    issues = r2.json()
    if isinstance(issues, dict):
        issues = issues.get('results', [])
except Exception:
    issues = []

done_count   = 0
inprog_count = 0
todo_count   = 0

for issue in issues:
    if sprint_active_id:
        raw_labels = issue.get('label_detail', []) or issue.get('labels', [])
        label_ids  = [(l['id'] if isinstance(l, dict) else l) for l in raw_labels]
        if sprint_active_id not in label_ids:
            continue
    grp = state_group.get(issue.get('state', ''), '')
    if grp == 'completed':
        done_count += 1
    elif grp == 'started':
        inprog_count += 1
    else:
        todo_count += 1

total    = done_count + inprog_count + todo_count
velocity = round(done_count * 100 / total) if total > 0 else 0

print(json.dumps({
    'sprint_name':  sprint_name,
    'days_left':    days_left,
    'done_count':   done_count,
    'inprog_count': inprog_count,
    'todo_count':   todo_count,
    'velocity':     velocity,
}))
PYEOF
}

# ─── get_agent_activity ───────────────────────────────────────────────────────
# Return a short human-readable string describing an agent's last activity.
#
# Usage: get_agent_activity AGENT
#
# Priority:
#   1. ${DATA_DIR}/agents/AGENT/last-activity.json  (shared memory file)
#   2. Most recent /var/log/bisb/*-AGENT-*.log       (log fallback)
#
# Returns: one-line string, e.g. "completed BISB-49 (PR submitted) — il y a 2h"
get_agent_activity() {
  local agent="$1"
  local activity_file="${DATA_DIR:-/var/lib/bisb/data}/agents/${agent}/last-activity.json"

  if [[ -f "$activity_file" ]]; then
    local result
    # Use a temp script to avoid heredoc-inside-$() which fails on bash 3.2
    local _tmp_py
    _tmp_py=$(mktemp /tmp/bisb-activity-XXXXXX.py)
    cat > "$_tmp_py" <<'PYEOF'
import json, sys, datetime
path = sys.argv[1]
try:
    with open(path) as f:
        d = json.load(f)
except Exception:
    sys.exit(0)
ts     = d.get('timestamp', '')
ticket = d.get('ticket', 'N/A')
action = d.get('action', 'action inconnue')
detail = d.get('detail', '')
try:
    dt = datetime.datetime.fromisoformat(ts.replace('Z', '+00:00'))
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=datetime.timezone.utc)
    ago           = datetime.datetime.now(datetime.timezone.utc) - dt
    total_minutes = int(ago.total_seconds() / 60)
    if total_minutes < 60:
        time_str = f'{total_minutes}min'
    elif total_minutes < 1440:
        time_str = f'{total_minutes // 60}h'
    else:
        time_str = f'{total_minutes // 1440}j'
except Exception:
    time_str = 'récemment'
detail_short = (detail[:60] + '…') if len(detail) > 60 else detail
if detail_short:
    print(f'{action} sur {ticket} ({detail_short}) — il y a {time_str}')
else:
    print(f'{action} sur {ticket} — il y a {time_str}')
PYEOF
    result=$(python3 "$_tmp_py" "$activity_file" 2>/dev/null || true)
    rm -f "$_tmp_py"
    if [[ -n "$result" ]]; then
      echo "$result"
      return 0
    fi
  fi

  # Fallback: last ticket reference from the most recent log for this agent
  local log_dir="${LOG_DIR:-/var/log/bisb}"
  local latest_log
  latest_log=$(ls -t "${log_dir}"/*-${agent}-*.log 2>/dev/null | head -1 || true)
  if [[ -n "$latest_log" ]]; then
    local log_line
    log_line=$(grep -oE "${PROJECT_KEY:?MISSING_PROJECT_KEY}-[0-9]+[^|]*" "$latest_log" 2>/dev/null \
               | tail -1 | head -c 100 || true)
    if [[ -n "$log_line" ]]; then
      echo "$log_line"
      return 0
    fi
  fi

  echo "aucune activité récente"
}

# ─── plane_get_current_cycle_id ───────────────────────────────────────────────
# Returns the Plane cycle UUID for the active sprint (status=current/active).
# No-ops (returns empty) when TRACKER_BACKEND != plane.
plane_get_current_cycle_id() {
  if [[ "${TRACKER_BACKEND:-jira}" != "plane" ]]; then
    echo ""
    return 0
  fi
  python3 - << 'PYEOF' 2>/dev/null
import os, sys, requests
base = os.environ.get('PLANE_BASE_URL', '').rstrip('/')
ws   = os.environ.get('PLANE_WORKSPACE_SLUG', '')
pid  = os.environ.get('PLANE_PROJECT_ID', '')
key  = os.environ.get('PLANE_API_KEY', '')
h    = {'X-API-Key': key, 'Content-Type': 'application/json'}
try:
    r = requests.get(f'{base}/api/v1/workspaces/{ws}/projects/{pid}/cycles/',
                     headers=h, timeout=15)
    data = r.json()
    cycles = data.get('results', data if isinstance(data, list) else [])
    for c in cycles:
        if c.get('status', '').lower() in ('current', 'started', 'active'):
            print(c['id']); sys.exit(0)
    # Fallback: most recently started cycle
    started = [c for c in cycles if c.get('start_date')]
    if started:
        started.sort(key=lambda x: x['start_date'], reverse=True)
        print(started[0]['id'])
except Exception as e:
    print(f'cycle lookup error: {e}', file=sys.stderr)
PYEOF
}

# ─── plane_update_cycle_description ──────────────────────────────────────────
# Overwrites the description field of the current active Plane cycle.
# Usage: plane_update_cycle_description "Sprint goal text"
plane_update_cycle_description() {
  local description="$1"
  if [[ "${TRACKER_BACKEND:-jira}" != "plane" ]]; then
    log_info "Tracker is not Plane — skipping cycle description update"
    return 0
  fi
  local cycle_id
  cycle_id=$(plane_get_current_cycle_id)
  if [[ -z "$cycle_id" ]]; then
    log_info "No active Plane cycle found — skipping description update"
    return 0
  fi
  python3 - "$cycle_id" "$description" << 'PYEOF' 2>/dev/null
import os, sys, requests
cycle_id    = sys.argv[1]
description = sys.argv[2]
base = os.environ.get('PLANE_BASE_URL', '').rstrip('/')
ws   = os.environ.get('PLANE_WORKSPACE_SLUG', '')
pid  = os.environ.get('PLANE_PROJECT_ID', '')
key  = os.environ.get('PLANE_API_KEY', '')
h    = {'X-API-Key': key, 'Content-Type': 'application/json'}
try:
    r = requests.patch(
        f'{base}/api/v1/workspaces/{ws}/projects/{pid}/cycles/{cycle_id}/',
        headers=h, json={'description': description}, timeout=15)
    if not r.ok:
        print(f'WARN {r.status_code}: {r.text[:200]}', file=sys.stderr)
except Exception as e:
    print(f'ERROR: {e}', file=sys.stderr)
PYEOF
  log_info "Updated Plane cycle ${cycle_id} description"
}
