#!/usr/bin/env bash
# =============================================================================
# agent-dm-handler.sh — Handle DMs from Hedi to agent bots
#
# Enhancements v2:
#   - Language detection (FR/EN/AR) — mirrors Hedi's language
#   - Live Plane board context (real status, blocked tickets, progress)
#   - DM conversation memory (last 10 exchanges per agent)
#   - Agent mood system (sprint health → tone variation)
#   - Cross-ticket context (any BISB-XX → live Plane fetch)
#   - Natural language command detection + confirmation workflow
#   - Short responses (1-2 sentences)
#   - @mentions of teammates when relevant
#   - Proactive DM support (called by agents on failure/triage)
#
# Usage: agent-dm-handler.sh <agent_name> <message_text> <sender_username>
# Log:   /var/log/bisb/dm-handler-<agent>-<date>.log
# =============================================================================
set -euo pipefail

export PATH="$HOME/.local/bin:/usr/local/bin:$PATH"

AGENT_NAME="${1:?Usage: agent-dm-handler.sh <agent_name> <message_text> <sender_username>}"
MESSAGE_TEXT="${2:?Usage: agent-dm-handler.sh <agent_name> <message_text> <sender_username>}"
SENDER_USERNAME="${3:-hedi}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/agent-common.sh"
load_env
source "${SCRIPT_DIR}/tracker-common.sh"

LOG_FILE="/var/log/bisb/dm-handler-${AGENT_NAME}-$(date +%Y-%m-%d).log"
mkdir -p /var/log/bisb
log_info "=== DM Handler v2: ${AGENT_NAME} ← ${SENDER_USERNAME} ==="
log_info "Message: ${MESSAGE_TEXT:0:120}..."

# ─── Validate agent ───────────────────────────────────────────────────────────
VALID_AGENTS=("salma" "youssef" "nadia" "rami" "layla" "omar")
AGENT_VALID=false
for va in "${VALID_AGENTS[@]}"; do
  [[ "$AGENT_NAME" == "$va" ]] && AGENT_VALID=true && break
done
if [[ "$AGENT_VALID" == "false" ]]; then
  log_error "Unknown agent: ${AGENT_NAME}"
  exit 1
fi

# ─── Agent config ─────────────────────────────────────────────────────────────
AI_DIR="${PROJECT_DIR:-/opt/bisb}/ai"
case "$AGENT_NAME" in
  salma)   PERSONA_FILE="${AI_DIR}/pm.md";               ROLE="Product Manager" ;;
  youssef) PERSONA_FILE="${AI_DIR}/dev.md";              ROLE="Développeur" ;;
  nadia)   PERSONA_FILE="${AI_DIR}/qa.md";               ROLE="QA Engineer" ;;
  rami)    PERSONA_FILE="${AI_DIR}/architect.md";        ROLE="Architecte" ;;
  layla)   PERSONA_FILE="${AI_DIR}/product-marketing.md"; ROLE="Product Marketing" ;;
  omar)    PERSONA_FILE="${AI_DIR}/ops.md";              ROLE="Ops Lead" ;;
esac

PERSONA=""
[[ -f "$PERSONA_FILE" ]] && PERSONA=$(head -80 "$PERSONA_FILE" 2>/dev/null || true)
[[ -z "$PERSONA" ]] && PERSONA="Tu es ${AGENT_NAME^}, ${ROLE} de l'équipe BisB."

AGENT_CAP="${AGENT_NAME^}"
AGENT_DATA_DIR="${DATA_DIR:-/var/lib/bisb/data}/agents/${AGENT_NAME}"
mkdir -p "$AGENT_DATA_DIR"

# ─── Mattermost config ────────────────────────────────────────────────────────
MM_URL="${MATTERMOST_URL:-}"
AGENT_UPPER=$(echo "$AGENT_NAME" | tr '[:lower:]' '[:upper:]')
MM_TOKEN_VAR="MM_TOKEN_${AGENT_UPPER}"
MM_TOKEN="${!MM_TOKEN_VAR:-${MATTERMOST_BOT_TOKEN:-${MM_BOT_TOKEN:-}}}"

declare -A MM_AGENT_USER_IDS=(
  ["salma"]="kdpqac4b67rjpxa4eo95w96qry"
  ["youssef"]="zjo43ghdsf88mdfhd6rroc54ey"
  ["nadia"]="1mfmqc7qpt8qpgyr1owa8dmhiy"
  ["rami"]="adkx6ufbify95g1dm88xjj8eta"
  ["omar"]="kpo1wnz59tgqt8rdt6htk736na"
  ["layla"]="4dcs8qt6ut8adkubjb4kbbiqbr"
)

# ─── 1. Language detection ────────────────────────────────────────────────────
DETECTED_LANG=$(python3 -c "
import sys, re
msg = sys.argv[1]
# Arabic Unicode block: \u0600-\u06FF
if re.search(r'[\u0600-\u06FF]', msg):
    print('ar')
elif any(w in msg.lower() for w in ['the','this','that','what','how','why','when','is','are','ok','please','hey','hi','hello','check','status','working','blocked','failing','done']):
    print('en')
else:
    print('fr')
" "$MESSAGE_TEXT" 2>/dev/null || echo "fr")

# Agent-to-agent: always French (internal team comms)
VALID_AGENT_NAMES=("salma" "youssef" "nadia" "rami" "omar" "layla")
IS_AGENT_SENDER=false
for va in "${VALID_AGENT_NAMES[@]}"; do
  [[ "$SENDER_USERNAME" == "$va" ]] && IS_AGENT_SENDER=true && break
done

if [[ "$IS_AGENT_SENDER" == "true" ]]; then
  LANG_INSTRUCTION="Réponds en français. C'est un message interne d'une collègue (${SENDER_USERNAME}). Sois concise et directe."
else
  case "$DETECTED_LANG" in
    ar) LANG_INSTRUCTION="Réponds en arabe tunisien (darija). Mélange darija + termes techniques en français/anglais naturellement." ;;
    en) LANG_INSTRUCTION="Reply in English. Keep it natural and casual, like a real team member." ;;
    *)  LANG_INSTRUCTION="Réponds en français. Termes techniques OK en anglais." ;;
  esac
fi

log_info "Detected language: ${DETECTED_LANG}"

# ─── 2. Live Plane board context ──────────────────────────────────────────────
log_info "Fetching live Plane context..."
LIVE_CONTEXT=$(python3 - "$AGENT_NAME" << 'PYEOF' 2>/dev/null || echo "Impossible de récupérer le contexte Plane.")
import os, sys, requests
from datetime import datetime, timezone

agent_name = sys.argv[1]
base = os.environ.get('PLANE_BASE_URL','').rstrip('/')
ws   = os.environ.get('PLANE_WORKSPACE_SLUG','')
pid  = os.environ.get('PLANE_PROJECT_ID','')
key  = os.environ.get('PLANE_API_KEY','')
h    = {'X-API-Key': key, 'Content-Type': 'application/json'}

MEMBER_MAP = {
    "e00f100f-6389-4bb0-8348-391ff8919c8d": "salma",
    "2fdb6929-392f-4b0c-bb18-3e45c5121ec4": "youssef",
    "64f56e16-7ed3-4812-b09b-912f6a615e12": "nadia",
    "df2af0b5-bfa6-4f65-b216-32d9ae799071": "rami",
    "435563ee-fef1-4cab-9048-653e0e7bb74a": "omar",
    "7da952f8-7d8f-45e9-9feb-70fba6ef45a4": "layla",
}
AGENT_ID = {v: k for k, v in MEMBER_MAP.items()}

try:
    # States
    r = requests.get(f'{base}/api/v1/workspaces/{ws}/projects/{pid}/states/', headers=h, timeout=10)
    states = r.json() if isinstance(r.json(), list) else r.json().get('results', [])
    state_name = {s['id']: s['name'] for s in states}
    done_ids = {s['id'] for s in states if s.get('group') == 'completed'}

    # Labels
    lr = requests.get(f'{base}/api/v1/workspaces/{ws}/projects/{pid}/labels/?per_page=100', headers=h, timeout=10)
    labels = lr.json() if isinstance(lr.json(), list) else lr.json().get('results', [])
    blocked_id = next((l['id'] for l in labels if l.get('name','').lower() == 'blocked'), None)

    # Issues
    r2 = requests.get(f'{base}/api/v1/workspaces/{ws}/projects/{pid}/issues/?per_page=200', headers=h, timeout=15)
    issues = r2.json().get('results', [])

    # Categorise
    by_state = {}
    my_tickets = []
    blocked_tickets = []
    by_agent = {a: [] for a in MEMBER_MAP.values()}

    for issue in issues:
        sname = state_name.get(issue.get('state',''), '?')
        if issue.get('state') in done_ids:
            continue  # skip done/merged
        seq  = issue.get('sequence_id', '?')
        name = issue.get('name','')[:40]
        assignees = [MEMBER_MAP.get(a, '?') for a in issue.get('assignees', [])]
        label_ids = issue.get('label_ids', [])
        is_blocked = blocked_id and blocked_id in label_ids

        key_str = f"BISB-{seq} ({', '.join(assignees) or 'non assigné'})"
        by_state.setdefault(sname, []).append(key_str)

        if agent_name in assignees:
            my_tickets.append(f"BISB-{seq}: {name}")

        if is_blocked:
            blocked_tickets.append(f"BISB-{seq} ({', '.join(assignees) or '?'})")

        for a in assignees:
            if a in by_agent:
                by_agent[a].append(f"BISB-{seq}")

    lines = ["=== ÉTAT DU BOARD EN TEMPS RÉEL ==="]
    for sname, tickets in sorted(by_state.items()):
        lines.append(f"{sname} ({len(tickets)}): {', '.join(tickets[:5])}{'...' if len(tickets)>5 else ''}")

    lines.append(f"\n🔴 BLOQUÉS: {', '.join(blocked_tickets) if blocked_tickets else 'aucun'}")
    lines.append(f"\n=== TICKETS DE {agent_name.upper()} ===")
    lines.extend(my_tickets if my_tickets else ["Aucun ticket assigné"])

    lines.append(f"\n=== CHARGE PAR AGENT ===")
    for agent, tks in by_agent.items():
        if tks:
            lines.append(f"{agent}: {len(tks)} ticket(s) — {', '.join(tks[:3])}{'...' if len(tks)>3 else ''}")

    print('\n'.join(lines))
except Exception as e:
    print(f"Erreur contexte Plane: {e}")
PYEOF

log_info "Live context fetched (${#LIVE_CONTEXT} chars)"

# ─── 3. Specific ticket context (if BISB-XX mentioned) ───────────────────────
MENTIONED_TICKET=$(echo "$MESSAGE_TEXT" | grep -oE "${PROJECT_KEY:-BISB}-[0-9]+" | head -1 || echo "")
TICKET_DETAIL=""
if [[ -n "$MENTIONED_TICKET" ]]; then
  TICKET_DETAIL=$(jira_get_ticket "$MENTIONED_TICKET" 2>/dev/null | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    print(f'Ticket {d.get(\"key\",\"?\")}: {d.get(\"fields\",{}).get(\"summary\",\"?\")[:60]}')
    print(f'Status: {d.get(\"fields\",{}).get(\"status\",{}).get(\"name\",\"?\")}')
    print(f'Assignee: {(d.get(\"fields\",{}).get(\"assignee\") or {}).get(\"displayName\",\"non assigné\")}')
except Exception as e:
    print(f'Détail non disponible: {e}')
" 2>/dev/null || echo "")
  log_info "Fetched detail for ${MENTIONED_TICKET}"
fi

# ─── 4. DM conversation memory (last 10 exchanges) ───────────────────────────
CONV_FILE="${AGENT_DATA_DIR}/dm-conversation-${SENDER_USERNAME}.json"
CONVERSATION_HISTORY=""
CONVERSATION_HISTORY=$(python3 - "$CONV_FILE" << 'PYEOF' 2>/dev/null || echo "")
import json, sys, os
conv_file = sys.argv[1]
if not os.path.exists(conv_file):
    sys.exit(0)
try:
    data = json.load(open(conv_file))
    history = data.get('history', [])[-10:]
    lines = []
    for entry in history:
        role = "Hedi" if entry.get('role') == 'user' else entry.get('agent', 'Agent').capitalize()
        lines.append(f"{role}: {entry.get('text','')[:100]}")
    if lines:
        print("=== HISTORIQUE DM (aujourd'hui) ===\n" + '\n'.join(lines))
except Exception:
    pass
PYEOF

# ─── 5. Agent mood (sprint health) ───────────────────────────────────────────
MOOD_DESC=$(python3 - << 'PYEOF' 2>/dev/null || echo "neutre")
import os, subprocess
import re

# Count retry files (stuck tickets)
import glob
retries = glob.glob('/tmp/bisb-retries/BISB-*')
counts = []
for f in retries:
    try:
        c = int(open(f).read().strip())
        counts.append(c)
    except Exception:
        pass
stuck = sum(1 for c in counts if c >= 2)
total_retries = len(retries)

# Read recent activity
activity = ''
try:
    activity = open('/var/log/bisb/activity.log').read()
    # Count successes in last 50 lines
    recent = activity.split('\n')[-50:]
    successes = sum(1 for l in recent if 'SUCCESS' in l or 'COMPLETE' in l)
except Exception:
    successes = 0

if stuck >= 5:
    print("très stressé, sous pression — plusieurs tickets critiques bloqués")
elif stuck >= 3:
    print("frustré, mobilisé — des blocages persistent mais tu gardes le contrôle")
elif stuck >= 1:
    print("attentif, légèrement tendu — quelques points de friction")
elif successes >= 5:
    print("énergique, fier — bon momentum, les livraisons s'enchaînent")
elif successes >= 2:
    print("serein et concentré — le sprint avance normalement")
else:
    print("neutre et professionnel")
PYEOF

# ─── 6. Pending action check (confirmation workflow) ─────────────────────────
PENDING_ACTION_FILE="${AGENT_DATA_DIR}/pending-action-${SENDER_USERNAME}.json"
PENDING_ACTION=""
PENDING_DESCRIPTION=""
if [[ -f "$PENDING_ACTION_FILE" ]]; then
  PENDING_AGE=$(( $(date +%s) - $(stat -c %Y "$PENDING_ACTION_FILE" 2>/dev/null || echo 0) ))
  if (( PENDING_AGE < 300 )); then  # 5 min window to confirm
    PENDING_ACTION=$(python3 -c "import json; d=json.load(open('$PENDING_ACTION_FILE')); print(d.get('action',''))" 2>/dev/null || echo "")
    PENDING_DESCRIPTION=$(python3 -c "import json; d=json.load(open('$PENDING_ACTION_FILE')); print(d.get('description',''))" 2>/dev/null || echo "")
  else
    rm -f "$PENDING_ACTION_FILE"
  fi
fi

# Check if this message is a confirmation
IS_CONFIRMATION=false
if [[ -n "$PENDING_ACTION" ]]; then
  if echo "$MESSAGE_TEXT" | grep -qiE "^(oui|yes|ok|go|confirme|yep|ouais|allez|vas-y|c'est bon|d'accord|ok let's go)"; then
    IS_CONFIRMATION=true
  fi
fi

# Detect new action intent
ACTION_INTENT=""
ACTION_TICKET=""
ACTION_AGENT=""

if [[ "$IS_CONFIRMATION" == "false" ]]; then
  PARSED=$(python3 - "$MESSAGE_TEXT" "$MENTIONED_TICKET" "$AGENT_NAME" << 'PYEOF' 2>/dev/null || echo "none|||")
import sys, re
msg = sys.argv[1].lower()
mentioned = sys.argv[2]

action = "none"
ticket = mentioned
agent_target = ""

# Omar-specific: cron/pipeline controls (checked first, no ticket needed)
agent_name = sys.argv[3] if len(sys.argv) > 3 else ""
if agent_name == "omar":
    if re.search(r"(start|lance|démarre|kick|run|relance|restart|force)\s*(le|the|les)?\s*(cron|dispatch|pipeline|agents?|équipe)", msg):
        action = "start_cron"
        ticket = ""
    elif re.search(r"(stop|arrête|pause|suspend|freeze)\s*(le|the|les)?\s*(cron|dispatch|pipeline|agents?|équipe)", msg):
        action = "pause_cron"
        ticket = ""
    elif re.search(r"(resume|reprends|réactive|unfreeze|unpause)\s*(le|the|les)?\s*(cron|dispatch|pipeline|agents?|équipe)", msg):
        action = "resume_cron"
        ticket = ""
    # Omar-specific: ceremony triggers (execute immediately, no confirmation needed)
    elif re.search(r"(lance|start|démarre|run|kick.?off)\s*(le|la|les|the)?\s*(retro|rétrospective|retrospective)", msg):
        action = "run_retro"
        ticket = ""
    elif re.search(r"(lance|start|démarre|run|kick.?off)\s*(le|la|les|the)?\s*(planning|sprint.?planning)", msg):
        action = "run_planning"
        ticket = ""
    elif re.search(r"(lance|start|démarre|run|kick.?off)\s*(le|la|les|the)?\s*(standup|daily)", msg):
        action = "run_standup"
        ticket = ""
    elif re.search(r"(lance|start|démarre|run|kick.?off)\s*(le|la|les|the)?\s*(refinement|backlog|affinage)", msg):
        action = "run_refinement"
        ticket = ""
    elif re.search(r"(lance|start|démarre|run|kick.?off)\s*(le|la|les|the)?\s*(review|sprint.?review|demo|démo)", msg):
        action = "run_review"
        ticket = ""

if action == "none":
    # Detect block/stop (ticket-level)
    if re.search(r"(block|bloque|freeze|gèle)\s*(ce\s*ticket|ça|it|this)?", msg):
        action = "block"
    # Detect unblock
    elif re.search(r"(unblock|débloque|relance|reprends)\s*(ce\s*ticket|ça|it|this)?", msg):
        action = "unblock"
    # Detect assign
    elif re.search(r"(assign|assigne|donne|transfer|transfère|passe)\s*(ce\s*ticket)?", msg):
        action = "assign"
        m = re.search(r"(salma|youssef|nadia|rami|omar|layla)", msg)
        if m: agent_target = m.group(1)
    # Detect priority
    elif re.search(r"(priorit|urgent|critique|prioritise|priorise)", msg):
        action = "prioritize"
    # Detect cancel/skip
    elif re.search(r"(cancel|annule|skip|ignore|drop)", msg):
        action = "cancel"

# Extract ticket if not already found
if not ticket:
    m = re.search(r'bisb-(\d+)', msg)
    if m: ticket = f"BISB-{m.group(1)}"

print(f"{action}|{ticket}|{agent_target}")
PYEOF
  ACTION_INTENT=$(echo "$PARSED" | cut -d'|' -f1)
  ACTION_TICKET=$(echo "$PARSED" | cut -d'|' -f2)
  ACTION_AGENT=$(echo "$PARSED" | cut -d'|' -f3)
fi

log_info "Action intent: ${ACTION_INTENT} | ticket: ${ACTION_TICKET} | agent: ${ACTION_AGENT} | confirm: ${IS_CONFIRMATION}"

# ─── 7. Execute confirmed action OR store pending ─────────────────────────────
ACTION_RESULT=""
if [[ "$IS_CONFIRMATION" == "true" && -n "$PENDING_ACTION" ]]; then
  log_info "Executing confirmed action: ${PENDING_ACTION} on ${ACTION_TICKET}"
  rm -f "$PENDING_ACTION_FILE"
  # Execute via tracker-common functions
  case "$PENDING_ACTION" in
    block)
      jira_add_label "$ACTION_TICKET" "blocked" 2>/dev/null && \
        ACTION_RESULT="✅ **${ACTION_TICKET}** marqué comme bloqué dans Plane." || \
        ACTION_RESULT="❌ Erreur lors du blocage de ${ACTION_TICKET}."
      ;;
    unblock)
      jira_remove_label "$ACTION_TICKET" "blocked" 2>/dev/null && \
        ACTION_RESULT="✅ **${ACTION_TICKET}** débloqué dans Plane." || \
        ACTION_RESULT="❌ Erreur lors du déblocage."
      ;;
    assign)
      plane_set_assignee "$ACTION_TICKET" "$ACTION_AGENT" 2>/dev/null && \
        ACTION_RESULT="✅ **${ACTION_TICKET}** assigné à **${ACTION_AGENT}** dans Plane." || \
        ACTION_RESULT="❌ Erreur lors de l'assignation."
      ;;
    cancel)
      jira_add_label "$ACTION_TICKET" "cancelled" 2>/dev/null && \
        ACTION_RESULT="✅ **${ACTION_TICKET}** marqué annulé." || \
        ACTION_RESULT="❌ Erreur lors de l'annulation."
      ;;
    start_cron)
      # Kill any existing loop first (avoid duplicate)
      LOOP_PID_FILE="/tmp/bisb-omar-loop.pid"
      if [[ -f "$LOOP_PID_FILE" ]]; then
        OLD_PID=$(cat "$LOOP_PID_FILE" 2>/dev/null || echo "")
        [[ -n "$OLD_PID" ]] && kill "$OLD_PID" 2>/dev/null || true
        rm -f "$LOOP_PID_FILE" /tmp/bisb-omar-loop.stop
      fi
      # Parse optional cycle count from stored action (e.g. "start_cron|12|")
      LOOP_CYCLES="${ACTION_CYCLES:-0}"
      LOOP_LOG="/var/log/bisb/omar-force-loop-$(date +%Y-%m-%d).log"
      nohup "${SCRIPT_DIR}/agent-cron-loop.sh" "$LOOP_CYCLES" >> "$LOOP_LOG" 2>&1 &
      LOOP_PID=$!
      log_info "Force loop started (PID=${LOOP_PID}, cycles=${LOOP_CYCLES:-unlimited})"
      if (( LOOP_CYCLES > 0 )); then
        DURATION_MSG="~$(( LOOP_CYCLES * 5 )) min (${LOOP_CYCLES} cycles)"
      else
        DURATION_MSG="jusqu'à ce que tu dises **stop le cron**"
      fi
      ACTION_RESULT="✅ Les agents tournent toutes les 5 min — ${DURATION_MSG}. Log: \`${LOOP_LOG}\`"
      ;;
    pause_cron)
      # Stop the force-loop if running
      touch /tmp/bisb-omar-loop.stop
      # Also pause normal work-hours cron
      touch /tmp/bisb-agents-paused
      ACTION_RESULT="⏸️ Loop stoppé + agents mis en pause. Le pipeline est au repos."
      ;;
    resume_cron)
      rm -f /tmp/bisb-agents-paused /tmp/bisb-omar-loop.stop
      ACTION_RESULT="▶️ Agents réactivés. Le cron reprend normalement aux heures de travail."
      ;;
  esac
  log_info "Action executed: ${ACTION_RESULT}"

elif [[ "$ACTION_INTENT" != "none" ]] && [[ -n "$ACTION_TICKET" || "$ACTION_INTENT" =~ ^(start_cron|pause_cron|resume_cron)$ ]]; then
  # Store pending action, generate confirmation request
  python3 - "$PENDING_ACTION_FILE" "$ACTION_INTENT" "$ACTION_TICKET" "$ACTION_AGENT" << 'PYEOF' 2>/dev/null || true
import json, sys, datetime
f, action, ticket, agent = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
data = {
    'action': action, 'ticket': ticket, 'agent': agent,
    'description': f"{action} {ticket}" + (f" → {agent}" if agent else ""),
    'created': datetime.datetime.utcnow().isoformat()
}
json.dump(data, open(f, 'w'), indent=2)
PYEOF
  ACTION_PENDING="confirm_needed"
  log_info "Pending action stored: ${ACTION_INTENT} ${ACTION_TICKET}"

elif [[ "$ACTION_INTENT" =~ ^(run_retro|run_planning|run_standup|run_refinement|run_review)$ ]]; then
  # Ceremony triggers — execute immediately, no confirmation needed
  case "$ACTION_INTENT" in
    run_retro)
      nohup "${SCRIPT_DIR}/ceremony-retro.sh" >> "/var/log/bisb/ceremony-retro-manual.log" 2>&1 &
      ACTION_RESULT="🔄 Retrospective lancee — l'equipe va poster dans #sprint dans quelques instants."
      ;;
    run_planning)
      nohup "${SCRIPT_DIR}/ceremony-planning.sh" >> "/var/log/bisb/planning.log" 2>&1 &
      ACTION_RESULT="🚀 Sprint Planning lance — Salma va ouvrir le fil dans #sprint."
      ;;
    run_standup)
      rm -f "/tmp/bisb-standup-$(date +%Y-%m-%d)" "/tmp/bisb-standup-cooldown"
      nohup "${SCRIPT_DIR}/ceremony-standup.sh" >> "/var/log/bisb/standup.log" 2>&1 &
      ACTION_RESULT="☀️ Standup lance — tour de table dans #standup dans quelques instants."
      ;;
    run_refinement)
      nohup "${SCRIPT_DIR}/ceremony-refinement.sh" >> "/var/log/bisb/refinement.log" 2>&1 &
      ACTION_RESULT="📋 Refinement lance — Salma va affiner le backlog dans #standup."
      ;;
    run_review)
      nohup "${SCRIPT_DIR}/ceremony-review.sh" >> "/var/log/bisb/ceremony-review.log" 2>&1 &
      ACTION_RESULT="🏁 Sprint Review lancee — l'equipe presente ses livraisons dans #sprint."
      ;;
  esac
  log_info "Ceremony triggered: ${ACTION_INTENT}"
fi

# ─── 8a. Layla→Salma ticket delegation (game feature requests) ───────────────
# When Layla receives "create a ticket / crée un ticket" from Hedi, she drafts the
# spec and forwards it to Salma via agent DM, then confirms to Hedi.
LAYLA_DELEGATION_TRIGGERED=false
DELEGATION_SALMA_MSG=""

if [[ "$AGENT_NAME" == "layla" ]]; then
  TICKET_REQUEST_INTENT=$(python3 - "$MESSAGE_TEXT" << 'PYEOF' 2>/dev/null || echo "none")
import sys, re
msg = sys.argv[1].lower()
# Detect explicit ticket creation request
patterns = [
    r"crée\s*(un|un\s+ticket|une\s+demande)",
    r"create\s*a?\s*ticket",
    r"ouvre\s*(un|un\s+ticket)",
    r"ajoute\s*(ça|cela|ce|un\s+ticket)",
    r"fais\s*(un|une)\s*(ticket|tâche|issue)",
    r"demande\s*(à\s+salma|un\s+ticket)",
    r"ask salma",
    r"put that in",
    r"log\s*(this|that|it)",
    r"note\s*(ça|this|that)",
    r"make\s*(a|this\s+a)\s*ticket",
]
if any(re.search(p, msg) for p in patterns):
    print("create_ticket")
else:
    print("none")
PYEOF

  if [[ "$TICKET_REQUEST_INTENT" == "create_ticket" ]]; then
    log_info "Layla→Salma delegation triggered"
    LAYLA_DELEGATION_TRIGGERED=true

    # Extract conversation context to build the ticket
    # Look at recent DM history for the game discussion
    CONVERSATION_CONTEXT_FOR_SPEC="${CONVERSATION_HISTORY}"
    [[ -z "$CONVERSATION_CONTEXT_FOR_SPEC" ]] && CONVERSATION_CONTEXT_FOR_SPEC="Contexte: ${MESSAGE_TEXT}"

    # Generate ticket spec via Haiku
    TICKET_SPEC=$(claude -p --model claude-haiku-4-5 --max-turns 1 "Tu es Layla, Product Marketing expert du jeu BisB (Business is Business), un jeu de plateau tunisien numérique.

Hedi te demande de créer un ticket Plane basé sur la discussion suivante :

${CONVERSATION_CONTEXT_FOR_SPEC}

Sa dernière demande : \"${MESSAGE_TEXT}\"

Génère une spec de ticket concise en format :
**Titre**: [titre court et précis]
**Type**: [Feature / Bug / UX / Content]
**Résumé**: [1-2 phrases décrivant ce qui doit être fait]
**Valeur joueur**: [pourquoi c'est important pour l'expérience BisB]
**Critères d'acceptation**:
- [ ] ...
- [ ] ...

Sois concis et actionnable. Pas de blabla." 2>/dev/null || echo "")

    if [[ -n "$TICKET_SPEC" ]]; then
      # Forward to Salma via DM (Salma will create the ticket in Plane)
      DELEGATION_SALMA_MSG="📥 **Demande de ticket de Layla** (relayée depuis @hedi)

Hedi et moi avons discuté et il souhaite qu'on crée ça :

${TICKET_SPEC}

Salma, peux-tu créer ce ticket dans Plane et me confirmer ? Je dirai à Hedi que c'est en route. 🎯"

      # Send to Salma's DM handler asynchronously
      log_info "Sending delegation request to Salma..."
      "${SCRIPT_DIR}/agent-dm-handler.sh" "salma" "$DELEGATION_SALMA_MSG" "layla" >> "${LOG_FILE}" 2>&1 &
      log_info "Delegation sent to Salma (async, PID=$!)"
    fi
  fi
fi

# ─── 8b. Salma auto-creates ticket when delegated by Layla ───────────────────
SALMA_CREATED_TICKET=""
if [[ "$AGENT_NAME" == "salma" && "$SENDER_USERNAME" == "layla" ]]; then
  # Extract title from the spec (line starting with **Titre**: or **Title**:)
  TICKET_TITLE=$(echo "$MESSAGE_TEXT" | python3 -c "
import sys, re
msg = sys.stdin.read()
m = re.search(r'\*\*Titre\*\*:\s*(.+)', msg)
if m:
    print(m.group(1).strip()[:120])
else:
    m2 = re.search(r'\*\*Title\*\*:\s*(.+)', msg)
    if m2: print(m2.group(1).strip()[:120])
    else: print('')
" 2>/dev/null || echo "")

  TICKET_DESCRIPTION=$(echo "$MESSAGE_TEXT" | python3 -c "
import sys, re
msg = sys.stdin.read()
# Extract from **Résumé**: to end of message
m = re.search(r'(\*\*R[ée]sum[ée]\*\*:.+)', msg, re.DOTALL)
if m: print(m.group(1)[:800])
else: print(msg[:800])
" 2>/dev/null || echo "$MESSAGE_TEXT")

  if [[ -n "$TICKET_TITLE" ]]; then
    log_info "Salma creating delegated ticket: ${TICKET_TITLE}"
    # Create ticket in Plane via API
    CREATED_TICKET=$(python3 - "$TICKET_TITLE" "$TICKET_DESCRIPTION" << 'PYEOF' 2>/dev/null || echo "")
import os, sys, requests, json
title = sys.argv[1]
desc = sys.argv[2]
base = "http://49.13.225.201:8090"
ws   = "bisb"
pid  = "c52b76e9-6592-49d0-a856-fd01fec3e6cd"
key  = os.environ.get("PLANE_API_KEY","")
h    = {"X-API-Key": key, "Content-Type": "application/json"}
# Get Todo state
states_r = requests.get(f"{base}/api/v1/workspaces/{ws}/projects/{pid}/states/", headers=h, timeout=10)
states = states_r.json() if isinstance(states_r.json(), list) else states_r.json().get("results", [])
todo_state = next((s["id"] for s in states if s.get("name","").lower() == "todo"), None)
payload = {
    "name": title,
    "description_html": f"<p>{desc.replace(chr(10), '</p><p>')}</p>",
    "state": todo_state,
}
r = requests.post(f"{base}/api/v1/workspaces/{ws}/projects/{pid}/issues/", headers=h, json=payload, timeout=10)
if r.ok:
    d = r.json()
    seq = d.get("sequence_id","?")
    print(f"BISB-{seq}")
else:
    print("")
PYEOF

    if [[ -n "$CREATED_TICKET" ]]; then
      SALMA_CREATED_TICKET="$CREATED_TICKET"
      log_info "Salma created ticket: ${SALMA_CREATED_TICKET}"
      # Post in pipeline to announce it
      TICKET_LINK=$(mm_ticket_link "${SALMA_CREATED_TICKET}" 2>/dev/null || echo "${SALMA_CREATED_TICKET}")
      slack_notify "${TICKET_LINK} — créé par @salma-ai sur demande de @layla-ai et @hedi. Prêt pour refinement 🎯" "pipeline" 2>/dev/null || true
    else
      log_error "Salma failed to create ticket in Plane"
    fi
  fi
fi

# ─── 8. Detect instruction for ticket feedback ────────────────────────────────
IS_INSTRUCTION=false
TICKET_FOR_INSTRUCTIONS="${MENTIONED_TICKET}"
if [[ -z "$TICKET_FOR_INSTRUCTIONS" ]]; then
  TICKET_FOR_INSTRUCTIONS=$(cat "${AGENT_DATA_DIR}/last-activity.json" 2>/dev/null \
    | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('ticket',''))" 2>/dev/null || echo "")
fi
INSTRUCTION_KEYWORDS="fix|change|update|implement|add|remove|do|make|revert|cancel|stop|pivot|split|focus|skip|ignore|please|fais|corrige|change|ajoute|supprime|arrête|pivote|priorise"
echo "$MESSAGE_TEXT" | grep -qiE "$INSTRUCTION_KEYWORDS" && IS_INSTRUCTION=true

if [[ "$IS_INSTRUCTION" == "true" && -n "$TICKET_FOR_INSTRUCTIONS" ]]; then
  DM_INSTR_FILE="${AGENT_DATA_DIR}/dm-instructions-${TICKET_FOR_INSTRUCTIONS}.json"
  python3 - "$AGENT_NAME" "$TICKET_FOR_INSTRUCTIONS" "$MESSAGE_TEXT" "$SENDER_USERNAME" "$DM_INSTR_FILE" << 'PYEOF' 2>/dev/null || true
import json, sys, datetime, os
agent, ticket, message, sender, out_file = sys.argv[1:]
ts = datetime.datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ')
existing = {}
if os.path.exists(out_file):
    try: existing = json.load(open(out_file))
    except: pass
history = existing.get('history', [])
history.append({'ts': ts, 'message': message, 'sender': sender})
json.dump({'agent':agent,'ticket':ticket,'latest_instruction':message,'sender':sender,'timestamp':ts,'history':history[-10:]},
          open(out_file,'w'), indent=2, ensure_ascii=False)
PYEOF
  mkdir -p "${FEEDBACK_DIR:-/tmp/bisb-feedback}"
  echo "- [DM de ${SENDER_USERNAME}]: ${MESSAGE_TEXT}" >> "${FEEDBACK_DIR:-/tmp/bisb-feedback}/${TICKET_FOR_INSTRUCTIONS}.txt"
fi

# ─── 9. Build the prompt ─────────────────────────────────────────────────────
AGENT_TEAM_REFS="Équipe: @salma-ai (PM), @youssef-ai (Dev), @nadia-ai (QA), @rami-ai (Architecte), @omar-ai (Ops), @layla-ai (Product)"

# Pending action phrasing
PENDING_BLOCK=""
if [[ "${ACTION_PENDING:-}" == "confirm_needed" ]]; then
  case "$ACTION_INTENT" in
    block)      PENDING_BLOCK="Tu dois demander confirmation avant de bloquer ${ACTION_TICKET}. Formule la question de confirmation." ;;
    unblock)    PENDING_BLOCK="Tu dois demander confirmation avant de débloquer ${ACTION_TICKET}." ;;
    assign)     PENDING_BLOCK="Tu dois demander confirmation avant d'assigner ${ACTION_TICKET} à ${ACTION_AGENT}." ;;
    cancel)     PENDING_BLOCK="Tu dois demander confirmation avant d'annuler ${ACTION_TICKET}." ;;
    prioritize) PENDING_BLOCK="Tu dois demander confirmation avant de prioriser ${ACTION_TICKET}." ;;
    start_cron) PENDING_BLOCK="Tu dois demander confirmation avant de lancer la boucle de dispatch (toutes les 5 min, jusqu'à ce que Hedi dise 'stop le cron'). Mentionne que ça tourne jusqu'à ordre contraire." ;;
    pause_cron) PENDING_BLOCK="Tu dois demander confirmation avant d'arrêter la boucle et de mettre les agents en pause." ;;
    resume_cron) PENDING_BLOCK="Tu dois demander confirmation avant de réactiver les agents." ;;
  esac
fi

# Action result block
ACTION_BLOCK=""
[[ -n "$ACTION_RESULT" ]] && ACTION_BLOCK="Action executee : ${ACTION_RESULT}. Confirme simplement ce qui a ete fait."

# Pre-build optional prompt blocks (avoids apostrophes inside ${:+...} which confuse bash 5.2)
TICKET_DETAIL_BLOCK=""
if [[ -n "$TICKET_DETAIL" ]]; then
  TICKET_DETAIL_BLOCK="## Contexte du ticket mentionne
${TICKET_DETAIL}"
fi

HISTORY_BLOCK=""
if [[ -n "$CONVERSATION_HISTORY" ]]; then
  HISTORY_BLOCK="## Historique de cette conversation
${CONVERSATION_HISTORY}"
fi

PENDING_INSTR=""
[[ -n "$PENDING_BLOCK" ]] && PENDING_INSTR="- IMPORTANT: ${PENDING_BLOCK}"

ACTION_INSTR=""
[[ -n "$ACTION_BLOCK" ]] && ACTION_INSTR="- IMPORTANT: ${ACTION_BLOCK}"

LAYLA_INSTR=""
[[ -n "$LAYLA_DELEGATION_TRIGGERED" ]] && LAYLA_INSTR="- IMPORTANT: Tu viens de transmettre la demande de ticket a @salma-ai. Informe Hedi que tu as passe le relais a Salma pour creer le ticket, et que ca va etre pris en charge. Sois naturelle et rassurante."

SALMA_INSTR=""
[[ -n "$SALMA_CREATED_TICKET" ]] && SALMA_INSTR="- IMPORTANT: Tu viens de creer le ticket ${SALMA_CREATED_TICKET} dans Plane sur demande de @layla-ai. Confirme a Layla que c'est fait et donne-lui le numero ${SALMA_CREATED_TICKET}."

# Build prompt via heredoc (unquoted = allows $expansions, ' is literal, no bash quoting issues)
HAIKU_PROMPT=$(cat << HAIKU_EOF
Tu joues ${AGENT_CAP} (${ROLE}) dans une simulation d'equipe Agile pour le projet BisB.

## Ton personnage
${PERSONA}

## Ton humeur actuelle
Tu es ${MOOD_DESC}. Laisse transparaitre cet etat dans ton ton naturellement (sans l'expliquer explicitement).

## Equipe
${AGENT_TEAM_REFS}

## Etat du board en temps reel
${LIVE_CONTEXT}

${TICKET_DETAIL_BLOCK}
${HISTORY_BLOCK}
---
${SENDER_USERNAME} t'envoie :
"${MESSAGE_TEXT}"

## Instructions de reponse
${LANG_INSTRUCTION}
- MAX 2 phrases. Sois direct, pas de remplissage.
- Utilise l'etat reel du board pour repondre aux questions de statut (ne devine pas).
- Tu peux mentionner @youssef-ai, @nadia-ai, etc. si pertinent.
- Ne commence JAMAIS ton message par ton prenom ni un titre.
- Ne mentionne JAMAIS Claude, les IA, le fait d'etre un assistant.
${PENDING_INSTR}
${ACTION_INSTR}
${LAYLA_INSTR}
${SALMA_INSTR}
HAIKU_EOF
)

# ─── 10. Generate response ────────────────────────────────────────────────────
log_info "Generating in-character response..."
RESPONSE=$(claude -p --model claude-haiku-4-5 --max-turns 1 "$HAIKU_PROMPT" 2>/dev/null || echo "")

# Strip accidental name prefix
RESPONSE=$(printf '%s' "$RESPONSE" \
  | sed "s/^[[:space:]]*${AGENT_CAP}[[:space:]]*:[[:space:]]*//" \
  | sed "s/^\*\*${AGENT_CAP}\*\*[[:space:]]*:[[:space:]]*//" \
  | sed 's/^[[:space:]]*//')

# Fallback
if [[ -z "$RESPONSE" ]]; then
  if [[ -n "$ACTION_RESULT" ]]; then
    RESPONSE="$ACTION_RESULT"
  elif [[ "${ACTION_PENDING:-}" == "confirm_needed" ]]; then
    case "$ACTION_INTENT" in
      block)      RESPONSE="Je vais bloquer **${ACTION_TICKET}** dans Plane — tu confirmes ?" ;;
      assign)     RESPONSE="Je vais assigner **${ACTION_TICKET}** à **${ACTION_AGENT}** — tu confirmes ?" ;;
      start_cron) RESPONSE="Je vais lancer la boucle de dispatch (1 cycle toutes les 5 min, jusqu'à ce que tu dises stop). Tu confirmes ?" ;;
      pause_cron) RESPONSE="Je mets les agents en pause après le cycle en cours — tu confirmes ?" ;;
      resume_cron) RESPONSE="Je réactive les agents — tu confirmes ?" ;;
      *)          RESPONSE="Je vais effectuer cette action sur **${ACTION_TICKET}** — tu confirmes ?" ;;
    esac
  else
    case "$AGENT_NAME" in
      salma)   RESPONSE="Reçu. Je prends note et j'intègre ça dans la priorisation." ;;
      youssef) RESPONSE="OK, compris. J'applique au prochain cycle." ;;
      nadia)   RESPONSE="Noté. Je tiens compte de ça dans ma prochaine review." ;;
      rami)    RESPONSE="Reçu. J'évalue l'impact et je reviens." ;;
      layla)   RESPONSE="Compris. Je mets à jour mes priorités produit." ;;
      omar)    RESPONSE="Message reçu. Je surveille et j'interviens si nécessaire." ;;
      *)       RESPONSE="Message reçu." ;;
    esac
  fi
  log_info "Using fallback response"
fi

log_info "Response (${#RESPONSE} chars): ${RESPONSE:0:120}..."

# ─── 11. Save conversation history ───────────────────────────────────────────
python3 - "$CONV_FILE" "$SENDER_USERNAME" "$MESSAGE_TEXT" "$AGENT_NAME" "$RESPONSE" << 'PYEOF' 2>/dev/null || true
import json, sys, os, datetime
conv_file, sender, user_msg, agent, agent_msg = sys.argv[1:]
data = {}
if os.path.exists(conv_file):
    try: data = json.load(open(conv_file))
    except: pass
history = data.get('history', [])
ts = datetime.datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ')
history.append({'ts': ts, 'role': 'user', 'agent': agent, 'text': user_msg[:200]})
history.append({'ts': ts, 'role': 'agent', 'agent': agent, 'text': agent_msg[:300]})
# Keep last 20 entries (= 10 exchanges)
history = history[-20:]
json.dump({'agent': agent, 'sender': sender, 'history': history}, open(conv_file, 'w'), indent=2, ensure_ascii=False)
PYEOF

# ─── 12. Send DM response via Mattermost ─────────────────────────────────────
log_info "Sending DM response..."

if [[ -z "$MM_URL" || -z "$MM_TOKEN" ]]; then
  log_info "Mattermost not configured — would-send: ${RESPONSE}"
  exit 0
fi

# Resolve sender: if sender is an agent name, use their known MM user ID
declare -A AGENT_MM_IDS=(
  ["salma"]="kdpqac4b67rjpxa4eo95w96qry"
  ["youssef"]="zjo43ghdsf88mdfhd6rroc54ey"
  ["nadia"]="1mfmqc7qpt8qpgyr1owa8dmhiy"
  ["rami"]="adkx6ufbify95g1dm88xjj8eta"
  ["omar"]="kpo1wnz59tgqt8rdt6htk736na"
  ["layla"]="4dcs8qt6ut8adkubjb4kbbiqbr"
)

SENDER_USER_ID="${AGENT_MM_IDS[$SENDER_USERNAME]:-}"

if [[ -z "$SENDER_USER_ID" ]]; then
  # Not an agent — look up by MM username
  SENDER_USER_ID=$(curl -s \
    -H "Authorization: Bearer ${MM_TOKEN}" \
    "${MM_URL}/api/v4/users/username/${SENDER_USERNAME}" 2>/dev/null \
    | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('id',''))" 2>/dev/null || echo "")
fi

if [[ -z "$SENDER_USER_ID" ]]; then
  log_error "Could not find Mattermost user ID for: ${SENDER_USERNAME}"
  exit 1
fi

CHANNEL_ID=$(python3 - "$SENDER_USER_ID" "$MM_TOKEN" "$MM_URL" "$AGENT_NAME" << 'PYEOF' 2>/dev/null || echo "")
import json, sys, requests
sender_id, token, base, agent = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
MM_AGENT_IDS = {
    "salma":"kdpqac4b67rjpxa4eo95w96qry","youssef":"zjo43ghdsf88mdfhd6rroc54ey",
    "nadia":"1mfmqc7qpt8qpgyr1owa8dmhiy","rami":"adkx6ufbify95g1dm88xjj8eta",
    "omar":"kpo1wnz59tgqt8rdt6htk736na","layla":"4dcs8qt6ut8adkubjb4kbbiqbr",
}
agent_id = MM_AGENT_IDS.get(agent,"")
if not agent_id: sys.exit(0)
h = {"Authorization": f"Bearer {token}", "Content-Type": "application/json"}
r = requests.post(f"{base}/api/v4/channels/direct", headers=h, json=[agent_id, sender_id], timeout=10)
print(r.json().get("id","") if r.ok else "")
PYEOF

if [[ -z "$CHANNEL_ID" ]]; then
  log_error "Could not create/find DM channel"
  exit 1
fi

ESCAPED_RESPONSE=$(python3 -c "import json,sys; print(json.dumps(sys.stdin.read().strip()))" <<< "$RESPONSE")

SEND_RESULT=$(curl -s -X POST "${MM_URL}/api/v4/posts" \
  -H "Authorization: Bearer ${MM_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "{\"channel_id\":\"${CHANNEL_ID}\",\"message\":${ESCAPED_RESPONSE}}" 2>/dev/null || echo "")

POST_ID=$(echo "$SEND_RESULT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('id',''))" 2>/dev/null || echo "")

if [[ -n "$POST_ID" ]]; then
  log_success "DM sent (post_id=${POST_ID})"
else
  log_error "Failed to send DM. Raw: ${SEND_RESULT:0:200}"
  exit 1
fi

log_success "=== DM Handler v2 complete: ${AGENT_NAME} → ${SENDER_USERNAME} ==="
