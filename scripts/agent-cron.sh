#!/bin/bash
# ─── Agent Cron — Full Autonomy Mode ──────────────────────────────────
# All agents run in PARALLEL, each has its own lock file via run-agent.sh
# Sprint ceremonies fully automated: review → retro → close → refinement → planning
# Test branch auto-build and deploy to port 3002

set -euo pipefail

# ─── Flags ───────────────────────────────────────────────────────────────────
# --force : bypass work-hours check (used when Omar triggers via DM)
FORCE_RUN=false
for arg in "$@"; do
  [[ "$arg" == "--force" ]] && FORCE_RUN=true
done

AGENT_NAME="dispatcher"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/agent-common.sh"

# Prevent overlapping dispatcher runs (after agent-common.sh sets PROJECT_PREFIX)
CRON_LOCKFILE="/tmp/${PROJECT_PREFIX}-agent-cron.lock"
exec 200>"$CRON_LOCKFILE"
flock -n 200 || { echo "[$(date)] Previous dispatcher still running, skipping this cycle."; exit 0; }

init_log "$AGENT_NAME" "cron"

log_info "=== ${PROJECT_KEY} agent cron starting ==="

# ─── Clean expired state ──────────────────────────────────────────────────────
clean_blacklist 2>/dev/null || true
clean_backoff 2>/dev/null || true

# ─── Auto-degradation check ──────────────────────────────────────────────────
DEGRADE_LEVEL=$(auto_degrade_check 2>/dev/null || echo "0")
if (( DEGRADE_LEVEL >= 3 )); then
  log_info "EMERGENCY degradation (level 3) — skipping entire dispatch cycle"
  event_log "SYSTEM" "dispatcher" "emergency_stop" "{\"level\":${DEGRADE_LEVEL}}" 2>/dev/null || true
  exit 0
fi
if (( DEGRADE_LEVEL > 0 )); then
  log_info "Degradation active: level ${DEGRADE_LEVEL} — $(degrade_status 2>/dev/null || true)"
fi

# ─── Work Hours: 09:00–21:00 Tunis time (UTC+1), Mon–Fri ────────────────────
# Tunis is always UTC+1 (no DST since 2008)
# Force base-10 to avoid bash treating "08"/"09" as invalid octal
HOUR_UTC=$(( 10#$(date -u +%H) ))
HOUR_TUNIS=$(( HOUR_UTC + 1 ))
DOW=$(date -u +%u)  # 1=Mon … 7=Sun
if [[ "$FORCE_RUN" == "true" ]]; then
  log_info "Work-hours check bypassed (--force flag set by Omar)"
elif [[ "$DOW" -ge 6 ]] || [[ "$HOUR_UTC" -lt 8 || "$HOUR_UTC" -ge 20 ]]; then
  log_info "Outside work hours ($(date -u '+%H:%M') UTC = ${HOUR_TUNIS}:$(date -u +%M) Tunis | work: Mon-Fri 09:00-21:00 Tunis). Skipping."
  exit 0
fi

# Safety: ensure main repo stays on base branch
cd "$PROJECT_DIR" && git checkout "${BASE_BRANCH}" -q 2>/dev/null || git checkout -B "${BASE_BRANCH}" "origin/${BASE_BRANCH}" -q 2>/dev/null || true

# ─── Pause check ────────────────────────────────────────────────────────────
PAUSE_FLAG="/tmp/${PROJECT_PREFIX}-agents-paused"
if [[ -f "$PAUSE_FLAG" ]]; then
  log_info "Agents paused (flag exists). Checking if ceremony needed..."
  # Even when paused, check if we need to run sprint ceremony
  # (ceremony creates new sprint and removes pause flag)
    CEREMONY_FLAG="/tmp/${PROJECT_PREFIX}-ceremony-done-$(date -u +%Y%m%d)"
    if [[ ! -f "$CEREMONY_FLAG" ]]; then
      log_info "Agents paused but ceremony not done today — falling through to ceremony check..."
      # Don't exit — fall through to ceremony check defined later in the script
    else
      log_info "Agents paused and ceremony already done today. Exiting."
      exit 0
    fi
fi

# ─── Self-update ─────────────────────────────────────────────────────────────
SCRIPT_HASH_BEFORE=$(md5sum "${BASH_SOURCE[0]}" | cut -d' ' -f1)
cd "$PROJECT_DIR"
git checkout "${BASE_BRANCH}" -q 2>/dev/null || true
git stash -q 2>/dev/null || true
git pull origin "${BASE_BRANCH}" --rebase 2>&1 | tail -3 || echo "[WARNING] git pull failed, continuing"

# Auto-sync scrum-agent scripts (pull latest from origin)
if [[ -d "${SCRIPT_DIR}/../.git" ]]; then
  cd "${SCRIPT_DIR}/.."
  git pull origin master --rebase -q 2>/dev/null || echo "[WARNING] scrum-agent pull failed"
  cd "$PROJECT_DIR"
fi

sync
SCRIPT_HASH_AFTER=$(md5sum "${BASH_SOURCE[0]}" | cut -d' ' -f1)
if [[ "$SCRIPT_HASH_BEFORE" != "$SCRIPT_HASH_AFTER" ]]; then
  log_info "Cron script updated, re-executing..."
  exec "${BASH_SOURCE[0]}"
fi

# ─── Safety: Max 2 sprints per week ─────────────────────────────────────────
SPRINT_WEEK_FILE="/tmp/${PROJECT_PREFIX}-sprints-this-week-$(date -u +%Y-W%V)"
SPRINTS_THIS_WEEK=$(cat "$SPRINT_WEEK_FILE" 2>/dev/null || echo 0)
MAX_SPRINTS_PER_WEEK=2

# ═══════════════════════════════════════════════════════════════════════════
# PHASE 1: Check Hedi's Slack Messages
# ═══════════════════════════════════════════════════════════════════════════
check_hedi_messages() {
  # Skip DM check for Mattermost (DM routing handled by n8n webhooks)
  if [[ "${CHAT_BACKEND:-slack}" == "mattermost" ]]; then
    return 0
  fi

  local CHANNEL_ID="${SLACK_CHANNEL_PIPELINE:-}"
  [[ -z "$CHANNEL_ID" ]] && return 0
  [[ -z "${SLACK_BOT_TOKEN:-}" ]] && return 0

  local LAST_CHECK_FILE="/tmp/${PROJECT_PREFIX}-hedi-lastcheck"
  local OLDEST
  OLDEST=$(cat "$LAST_CHECK_FILE" 2>/dev/null || echo "0")

  local API_RESPONSE
  API_RESPONSE=$(curl -s -H "Authorization: Bearer ${SLACK_BOT_TOKEN}" \
    "https://slack.com/api/conversations.history?channel=${CHANNEL_ID}&oldest=${OLDEST}&limit=20" 2>/dev/null) || return 0

  local LATEST_TS
  LATEST_TS=$(echo "$API_RESPONSE" | python3 -c "
import sys, json, re, os

data = json.load(sys.stdin)
if not data.get('ok'):
    sys.exit(0)

msg_dir = '/tmp/${PROJECT_PREFIX}-hedi-messages'
os.makedirs(msg_dir, exist_ok=True)
valid_agents = ['salma', 'youssef', 'nadia', 'omar', 'layla', 'rami']
latest_ts = '0'

for msg in data.get('messages', []):
    ts = msg.get('ts', '0')
    if ts > latest_ts:
        latest_ts = ts
    if 'bot_id' in msg or msg.get('subtype'):
        continue
    text = msg.get('text', '')

    # Check for pause/stop command  
    text_lower = text.lower()
    if any(cmd in text_lower for cmd in ['pause', 'stop', 'arreter']):
        open('/tmp/${PROJECT_PREFIX}-agents-paused', 'w').write('Paused by Hedi via Slack')
        print('PAUSE_REQUESTED', file=sys.stderr)

    agent = None
    content = None
    m = re.match(r'@(\w+)\s+(.*)', text, re.DOTALL)
    if m and m.group(1).lower() in valid_agents:
        agent, content = m.group(1).lower(), m.group(2).strip()
    if not agent:
        m = re.match(r'(\w+)[,:]\s+(.*)', text, re.DOTALL)
        if m and m.group(1).lower() in valid_agents:
            agent, content = m.group(1).lower(), m.group(2).strip()

    if agent and content:
        safe_ts = ts.replace('.', '-')
        filepath = os.path.join(msg_dir, f'{agent}-{safe_ts}.md')
        with open(filepath, 'w') as f:
            f.write(content)
        print(f'Saved message for {agent}', file=sys.stderr)

print(latest_ts)
" 2>>"${LOG_FILE:-/dev/null}") || true

  if [[ -n "$LATEST_TS" && "$LATEST_TS" != "0" ]]; then
    echo "$LATEST_TS" > "$LAST_CHECK_FILE"
  fi
}

check_hedi_messages

# Exit if pause was requested
if [[ -f "$PAUSE_FLAG" ]]; then
  log_info "Pause requested by Hedi via Slack"
  slack_notify "omar" "Agents paused by Hedi's Slack command"
  exit 0
fi

# ═══════════════════════════════════════════════════════════════════════════
# PHASE 1b: Cost Budget Enforcement
# ═══════════════════════════════════════════════════════════════════════════
# Track daily API calls. If budget thresholds are exceeded, throttle agents.
# Thresholds (daily): WARNING at 80 calls, THROTTLE at 120, HARD STOP at 150.
BUDGET_MODE="normal"
TODAY=$(date -u +%Y-%m-%d)
COST_FILE="${DATA_DIR}/costs/daily/${TODAY}.json"
DAILY_CALLS=0

if [[ -f "$COST_FILE" ]]; then
  DAILY_CALLS=$(python3 -c "
import json
with open('$COST_FILE') as f:
    d = json.load(f)
totals = d.get('totals', {})
print(sum(t.get('calls', 0) for t in totals.values()))
" 2>/dev/null || echo "0")
fi

BUDGET_LIMIT="${PROJECT_BUDGET_DAILY:-150}"
BUDGET_THROTTLE=$(( BUDGET_LIMIT * 80 / 100 ))
BUDGET_WARNING=$(( BUDGET_LIMIT * 53 / 100 ))

if (( DAILY_CALLS >= BUDGET_LIMIT )); then
  BUDGET_MODE="stopped"
  log_info "Budget HARD STOP: ${DAILY_CALLS} calls today (limit: ${BUDGET_LIMIT}). Only Omar health checks will run."
  # Post alert once per hour
  BUDGET_ALERT_FLAG="/tmp/${PROJECT_PREFIX}-budget-alert-$(date -u +%Y-%m-%d-%H)"
  if [[ ! -f "$BUDGET_ALERT_FLAG" ]]; then
    slack_notify "Budget HARD STOP: ${DAILY_CALLS} API calls today. Only health checks running. Agents resume tomorrow." "alerts" "danger"
    touch "$BUDGET_ALERT_FLAG"
  fi
elif (( DAILY_CALLS >= BUDGET_THROTTLE )); then
  BUDGET_MODE="throttled"
  log_info "Budget THROTTLED: ${DAILY_CALLS} calls today (limit: ${BUDGET_THROTTLE}). Only Rami (merges) + Omar running."
  BUDGET_ALERT_FLAG="/tmp/${PROJECT_PREFIX}-budget-throttle-$(date -u +%Y-%m-%d-%H)"
  if [[ ! -f "$BUDGET_ALERT_FLAG" ]]; then
    slack_notify "Budget throttled: ${DAILY_CALLS} API calls. Only merge + health check agents active." "alerts" "warning"
    touch "$BUDGET_ALERT_FLAG"
  fi
elif (( DAILY_CALLS >= BUDGET_WARNING )); then
  BUDGET_MODE="warning"
  log_info "Budget WARNING: ${DAILY_CALLS} calls today"
fi

# If budget is hard-stopped, skip straight to Omar health checks only
if [[ "$BUDGET_MODE" == "stopped" ]]; then
  log_info "Budget stopped — skipping all agents, running Omar only"
  "${SCRIPT_DIR}/agent-omar.sh" &
  OMAR_PID=$!
  wait "$OMAR_PID" 2>/dev/null || true
  log_info "Budget-stopped cycle complete (Omar only)"
  exit 0
fi

# ═══════════════════════════════════════════════════════════════════════════
# PHASE 1c: Needs-Human Escalation (active push — notifies Hedi immediately)
# ═══════════════════════════════════════════════════════════════════════════
check_needs_human_escalation() {
  [[ "${TRACKER_BACKEND:-jira}" != "plane" ]] && return
  local NOTIFY_DIR="/tmp/${PROJECT_PREFIX}-needs-human-notified"
  mkdir -p "$NOTIFY_DIR"

  # Get all active needs-human tickets from Plane (temp file to avoid heredoc-in-$() issues)
  local _nh_script
  _nh_script=$(mktemp /tmp/${PROJECT_PREFIX}-nh-XXXXXX.py)
  cat > "$_nh_script" << 'NHPYEOF'
import os, requests
HEDI_ID = "635b2c8a-9532-49f8-8562-1fd182e09cd1"
base = os.environ.get('PLANE_BASE_URL','').rstrip('/')
ws   = os.environ.get('PLANE_WORKSPACE_SLUG','')
pid  = os.environ.get('PLANE_PROJECT_ID','')
key  = os.environ.get('PLANE_API_KEY','')
h    = {'X-API-Key': key, 'Content-Type': 'application/json'}
# Labels removed — use state name 'Needs Human' instead
sr = requests.get(f'{base}/api/v1/workspaces/{ws}/projects/{pid}/states/', headers=h, timeout=10)
states = sr.json() if isinstance(sr.json(), list) else sr.json().get('results', [])
done_ids  = {s['id'] for s in states if s.get('group') == 'completed'}
state_name = {s['id']: s.get('name','') for s in states}
r = requests.get(f'{base}/api/v1/workspaces/{ws}/projects/{pid}/issues/?per_page=200', headers=h, timeout=15)
issues = r.json().get('results', [])
for issue in issues:
    if issue.get('state') in done_ids:
        continue
    if state_name.get(issue.get('state',''), '') != 'Needs Human':
        continue
    seq     = issue.get('sequence_id', '?')
    name    = issue.get('name', '').replace('|', '/')
    iid     = issue.get('id', '')
    current = issue.get('assignees', [])
    # Needs Human = unassign everyone, assign Hedi only (he makes the decision)
    if not (current == [HEDI_ID]):
        requests.patch(
            f'{base}/api/v1/workspaces/{ws}/projects/{pid}/issues/{iid}/',
            headers=h, json={'assignees': [HEDI_ID]}, timeout=10)
    print(f'BISB-{seq}|{name}')
NHPYEOF
  local nh_tickets
  nh_tickets=$(python3 "$_nh_script" 2>/dev/null || echo "")
  rm -f "$_nh_script"

  [[ -z "$nh_tickets" ]] && return

  while IFS='|' read -r ticket_key title; do
    [[ -z "$ticket_key" ]] && continue
    local notify_flag="${NOTIFY_DIR}/${ticket_key}"
    [[ -f "$notify_flag" ]] && continue  # already escalated this ticket

    # Read last feedback for context
    local feedback_snippet=""
    if [[ -f "/tmp/${PROJECT_PREFIX}-feedback/${ticket_key}.txt" ]]; then
      feedback_snippet=$(tail -8 "/tmp/${PROJECT_PREFIX}-feedback/${ticket_key}.txt" 2>/dev/null | head -c 600)
    fi

    log_info "Escalating needs-human ticket: ${ticket_key} — assigned to Hedi in Plane"

    local msg="🆘 **Intervention humaine requise**
**${ticket_key}**: ${title}

Un agent est bloqué et a besoin d'une décision humaine. Le ticket t'a été assigné dans Plane.
$([ -n "$feedback_snippet" ] && printf 'Dernier feedback:\n```\n%s\n```' "$feedback_snippet")

→ Action: Ouvre Plane, lis le commentaire d'agent, et prends une décision."

    AGENT_NAME="omar" slack_notify "$msg" "pipeline" "danger" 2>/dev/null || true

    touch "$notify_flag"
    log_info "Escalation posted and Hedi assigned for ${ticket_key}"
  done <<< "$nh_tickets"
}

check_needs_human_escalation

# ═══════════════════════════════════════════════════════════════════════════
# PHASE 2: Dispatch Retro-Action Agents (parallel)
# ═══════════════════════════════════════════════════════════════════════════
RETRO_PIDS=()
if [[ "$BUDGET_MODE" != "throttled" ]]; then
for retro_agent in omar layla rami; do
  RETRO_JQL="project = ${JIRA_PROJECT} AND labels = 'agent:${retro_agent}' AND labels = 'retro-action' AND labels NOT IN ('enriched','blocked') AND statusCategory != 'Done' ORDER BY priority DESC, created ASC"
  RETRO_TICKET=$(jira_search_keys "$RETRO_JQL" "1" 2>/dev/null | head -1 || echo "")
  if [[ -n "$RETRO_TICKET" ]]; then
    log_info "Dispatching ${retro_agent}-retro for $RETRO_TICKET"
    "${SCRIPT_DIR}/agent-${retro_agent}-retro.sh" "$RETRO_TICKET" &
    RETRO_PIDS+=($!)
  fi
done

# Youssef self-improve: retro-action tickets about scripts/pipeline (label: self-improve)
SELF_IMPROVE_JQL="project = ${JIRA_PROJECT} AND labels = 'agent:youssef' AND labels = 'self-improve' AND labels NOT IN ('blocked') AND statusCategory != 'Done' ORDER BY priority DESC, created ASC"
SELF_IMPROVE_TICKET=$(jira_search_keys "$SELF_IMPROVE_JQL" "1" 2>/dev/null | head -1 || echo "")
if [[ -n "$SELF_IMPROVE_TICKET" ]]; then
  log_info "Dispatching youssef-self-improve for $SELF_IMPROVE_TICKET"
  "${SCRIPT_DIR}/agent-youssef-self-improve.sh" "$SELF_IMPROVE_TICKET" &
  RETRO_PIDS+=($!)
fi
fi  # end budget_mode != throttled

# ═══════════════════════════════════════════════════════════════════════════

# ─── 2b. Worktree cleanup ──────────────────────────────────────────────────
log_info "Cleaning up stale worktrees..."
cd "$PROJECT_DIR"
git worktree prune 2>/dev/null || true
if [[ -d "$WORKTREE_BASE" ]]; then
  for wt_dir in "${WORKTREE_BASE}"/feature/${PROJECT_KEY}-*; do
    [[ -d "$wt_dir" ]] || continue
    wt_branch="feature/$(basename "$wt_dir")"
    # Check if remote branch still exists (if not, PR was merged/closed)
    if ! git ls-remote --heads origin "$wt_branch" 2>/dev/null | grep -q .; then
      log_info "Removing stale worktree (branch deleted): $(basename "$wt_dir")"
      git worktree remove "$wt_dir" --force 2>/dev/null || rm -rf "$wt_dir"
    fi
  done
  git worktree prune 2>/dev/null || true
fi

# PHASE 3: Dispatch Main Agents (parallel)
# ═══════════════════════════════════════════════════════════════════════════
process_agent() {
  local agent="$1"
  local max_tickets="${2:-3}"

  # ─── Degradation check: skip blocked agents ──────────────────────────────
  if ! dispatch_allowed "$agent" 2>/dev/null; then
    log_info "Agent ${agent} blocked by degradation (level $(degrade_get 2>/dev/null || echo '?')) — skipping"
    return
  fi

  local tickets
  # ─── Assignment-based dispatch (Plane native) ─────────────────────────────
  # When using Plane as tracker, use assignee-based queries instead of labels.
  # This is cleaner, standard agile practice, and removes agent:X label pollution.
  if [[ "${TRACKER_BACKEND:-jira}" == "plane" ]] && declare -f plane_get_assigned_tickets &>/dev/null; then
    tickets=$(plane_get_assigned_tickets "$agent" "$max_tickets" 2>/dev/null || echo "")
    # State-based dispatch for specific agents
    case "$agent" in
      salma)
        # Salma also picks up unassigned Todo tickets
        if declare -f plane_get_unassigned_todo &>/dev/null; then
          local unassigned_todos
          unassigned_todos=$(plane_get_unassigned_todo 2>/dev/null || echo "")
          if [[ -n "$unassigned_todos" ]]; then
            tickets="${tickets} ${unassigned_todos}"
          fi
        fi
        ;;
      youssef)
        # Youssef picks up unassigned Ready tickets
        if declare -f plane_get_unassigned_by_state &>/dev/null; then
          local ready_tickets
          ready_tickets=$(plane_get_unassigned_by_state "Ready" "$max_tickets" 2>/dev/null || echo "")
          if [[ -n "$ready_tickets" ]]; then
            tickets="${tickets} ${ready_tickets}"
          fi
        fi
        ;;
      nadia)
        # Nadia picks up unassigned In Review tickets
        if declare -f plane_get_unassigned_by_state &>/dev/null; then
          local inreview_tickets
          inreview_tickets=$(plane_get_unassigned_by_state "In Review" "$max_tickets" 2>/dev/null || echo "")
          if [[ -n "$inreview_tickets" ]]; then
            tickets="${tickets} ${inreview_tickets}"
          fi
        fi
        ;;
      rami)
        # Rami picks up QA-passed tickets (state=QA) for DevOps review + merge
        if declare -f plane_get_unassigned_by_state &>/dev/null; then
          local qa_tickets
          qa_tickets=$(plane_get_unassigned_by_state "QA" "$max_tickets" 2>/dev/null || echo "")
          if [[ -n "$qa_tickets" ]]; then
            tickets="${tickets} ${qa_tickets}"
          fi
        fi
        ;;
      omar)
        # Omar also picks up Done tickets assigned to him (for merge tracking)
        if declare -f plane_get_assigned_tickets &>/dev/null; then
          local done_tickets
          done_tickets=$(plane_get_assigned_tickets "omar" "$max_tickets" 2>/dev/null || echo "")
          if [[ -n "$done_tickets" ]]; then
            tickets="${tickets} ${done_tickets}"
          fi
        fi
        # Omar self-assigns any blocked tickets (any state) with no assignee or wrong assignee
        # After self-assigning, the blocker-triage ceremony decides what happens next
        if [[ "${TRACKER_BACKEND:-jira}" == "plane" ]]; then
          local blocked_tickets
          blocked_tickets=$(python3 - << 'PYEOF'
import os, requests
base = os.environ.get('PLANE_BASE_URL','').rstrip('/')
ws   = os.environ.get('PLANE_WORKSPACE_SLUG','')
pid  = os.environ.get('PLANE_PROJECT_ID','')
key  = os.environ.get('PLANE_API_KEY','')
h    = {'X-API-Key': key, 'Content-Type': 'application/json'}
OMAR_ID  = "435563ee-fef1-4cab-9048-653e0e7bb74a"
# Labels removed — use state name 'Blocked' instead
sr = requests.get(f'{base}/api/v1/workspaces/{ws}/projects/{pid}/states/', headers=h, timeout=10)
states = sr.json() if isinstance(sr.json(), list) else sr.json().get('results', [])
state_name = {s['id']: s.get('name','') for s in states}
done_groups = {s['id'] for s in states if s.get('group') == 'completed'}
# Get all issues
issues = []
page = 1
while True:
    r = requests.get(f'{base}/api/v1/workspaces/{ws}/projects/{pid}/issues/?per_page=100&page={page}', headers=h, timeout=15)
    data = r.json()
    issues.extend(data.get('results', []))
    if not data.get('next_page_results', False):
        break
    page += 1
results = []
for issue in issues:
    if issue.get('state') in done_groups:
        continue
    if state_name.get(issue.get('state',''), '') != 'Blocked':
        continue
    assignees = issue.get('assignees', [])
    if OMAR_ID in assignees and len(assignees) == 1:
        continue  # already assigned to Omar only — nothing to do
    # Blocked = unassign everyone, assign Omar only (he owns the unblocking)
    r2 = requests.patch(
        f'{base}/api/v1/workspaces/{ws}/projects/{pid}/issues/{issue["id"]}/',
        headers=h, json={'assignees': [OMAR_ID]}, timeout=10)
    if r2.status_code in (200, 201):
        seq = issue.get('sequence_id','?')
        results.append(f'BISB-{seq}')
if results:
    print(' '.join(results))
PYEOF
2>/dev/null || echo "")
          if [[ -n "$blocked_tickets" ]]; then
            log_info "Omar self-assigned blocked tickets: ${blocked_tickets}"
            tickets="${tickets} ${blocked_tickets}"

            # ── Triage threshold check ────────────────────────────────────
            # Trigger when: 5+ blocked tickets OR ALL active tickets are blocked
            local blocked_count active_count
            blocked_count=$(echo "$blocked_tickets" | tr ' ' '\n' | grep -c '[A-Z]' || echo 0)
            active_count=$(python3 - << 'PYEOF' 2>/dev/null || echo 99
import os, requests
base = os.environ.get('PLANE_BASE_URL','').rstrip('/')
ws   = os.environ.get('PLANE_WORKSPACE_SLUG','')
pid  = os.environ.get('PLANE_PROJECT_ID','')
key  = os.environ.get('PLANE_API_KEY','')
h    = {'X-API-Key': key}
DONE_STATES = {'completed'}
r = requests.get(f'{base}/api/v1/workspaces/{ws}/projects/{pid}/states/', headers=h, timeout=10)
states = r.json() if isinstance(r.json(), list) else r.json().get('results', [])
done_ids = {s['id'] for s in states if s.get('group','') == 'completed'}
r2 = requests.get(f'{base}/api/v1/workspaces/{ws}/projects/{pid}/issues/?per_page=200', headers=h, timeout=15)
issues = r2.json().get('results', [])
active = sum(1 for i in issues if i.get('state') not in done_ids)
print(active)
PYEOF
)
            local should_triage=false
            if (( blocked_count >= 5 )); then
              should_triage=true
              log_info "Triage threshold: ${blocked_count} blocked tickets (≥5)"
            elif (( active_count > 0 && blocked_count >= active_count )); then
              should_triage=true
              log_info "Triage threshold: ALL ${active_count} active tickets are blocked"
            else
              log_info "Triage: ${blocked_count} blocked / ${active_count} active — below threshold (need 5+ or all blocked)"
            fi

            # Trigger triage (with 1h cooldown)
            TRIAGE_COOLDOWN_FILE="/tmp/${PROJECT_PREFIX}-triage-cooldown-cron"
            TRIAGE_COOLDOWN_AGE=0
            if [[ -f "$TRIAGE_COOLDOWN_FILE" ]]; then
              TRIAGE_COOLDOWN_AGE=$(( $(date +%s) - $(stat -c %Y "$TRIAGE_COOLDOWN_FILE" 2>/dev/null || echo 0) ))
            fi
            if [[ "$should_triage" == "true" ]]; then
              if (( TRIAGE_COOLDOWN_AGE > 3600 )) || [[ ! -f "$TRIAGE_COOLDOWN_FILE" ]]; then
                "${SCRIPT_DIR}/ceremony-blocker-triage.sh" >> ${LOG_DIR}/blocker-triage.log 2>&1 &
                touch "$TRIAGE_COOLDOWN_FILE"
                log_info "Blocker triage ceremony triggered for: ${blocked_tickets}"
                slack_notify "omar" "🚨 **Blocker Triage déclenchée** (${blocked_count} bloqués / ${active_count} actifs)\nTickets : **${blocked_tickets}**\nTable ronde en cours — décision : split / pivot / déblocage / escalade humain." "pipeline" "warning" 2>/dev/null || true
              else
                log_info "Triage cooldown active (< 1h) — triage skipped this cycle"
              fi
            fi
          fi
        fi
        ;;
    esac
    # Deduplicate and limit
    tickets=$(echo "$tickets" | tr ' ' '\n' | grep -v '^$' | sort -u | head -"$max_tickets" | tr '\n' ' ' || true)
    # Fallback to label-based if assignee query returns nothing (transition period)
    if [[ -z "$(echo "$tickets" | tr -d ' \n')" ]]; then
      local jql="project = ${JIRA_PROJECT} AND labels = 'agent:${agent}' AND labels = 'sprint-active' AND labels NOT IN ('blocked','needs-human-review') AND statusCategory != 'Done' ORDER BY priority DESC, created ASC"
      tickets=$(jira_search_keys "$jql" "$max_tickets" 2>/dev/null || echo "")
    fi
  else
    # ─── Label-based dispatch (Jira or fallback) ─────────────────────────────
    local jql="project = ${JIRA_PROJECT} AND labels = 'agent:${agent}' AND labels = 'sprint-active' AND labels NOT IN ('blocked','needs-human-review') AND statusCategory != 'Done' ORDER BY priority DESC, created ASC"
    tickets=$(jira_search_keys "$jql" "$max_tickets" 2>/dev/null || echo "")
  fi

  if [[ -z "$(echo "$tickets" | tr -d ' \n')" ]]; then
    return
  fi

  while IFS= read -r ticket; do
    [[ -z "$ticket" ]] && continue
    # ─── Blacklist check: skip tickets that recently hit max retries ─────
    if is_blacklisted "$ticket"; then
      log_info "Skipping blacklisted ticket ${ticket} (cooldown active)"
      continue
    fi
    log_info "Dispatching ${agent} for ${ticket}"
    "${SCRIPT_DIR}/run-agent.sh" "$ticket" "$agent" &
    AGENT_PIDS+=($!)
  done <<< "$(echo "$tickets" | tr ' ' '\n' | grep -v '^$' || true)"
}

# ─── WIP Counter ─────────────────────────────────────────────────────────────
# Count currently-running agent jobs by counting their non-stale lock files.
# For per-ticket agents (youssef, nadia, rami): LOCK_FILE = /tmp/${PROJECT_PREFIX}-agent-AGENT-TICKET.lock
# For single-lock agents (salma, layla, omar): LOCK_FILE = /tmp/${PROJECT_PREFIX}-agent-AGENT.lock
count_active_wip() {
  local agent="$1"
  local max_age=1800  # 30 min (matches LOCK_MAX_AGE in agent-common.sh)
  local count=0
  local now
  now=$(date +%s)
  for lf in /tmp/${PROJECT_PREFIX}-agent-${agent}-BISB-*.lock /tmp/${PROJECT_PREFIX}-agent-${agent}-${PROJECT_KEY}-*.lock; do
    [[ -f "$lf" ]] || continue
    local mtime
    mtime=$(stat -c %Y "$lf" 2>/dev/null || stat -f %m "$lf" 2>/dev/null || echo 0)
    if (( now - mtime < max_age )); then
      (( count++ )) || true
    fi
  done
  echo "$count"
}

AGENT_PIDS=()

if [[ "$BUDGET_MODE" == "throttled" ]]; then
  # Throttled: only Rami (for merges) + Omar (health checks)
  log_info "Budget throttled — dispatching only Rami + Omar"
  process_agent "rami" 3
  "${SCRIPT_DIR}/agent-omar.sh" &
  AGENT_PIDS+=($!)
else
  # Normal/warning: all agents run
  # Salma (PM) — up to 3 tickets
  process_agent "salma" 3

  # Youssef (Dev) — WIP limit: max 2 concurrent tickets (git worktrees are expensive)
  YOUSSEF_WIP=$(count_active_wip "youssef")
  if (( YOUSSEF_WIP >= 2 )); then
    log_info "WIP limit: Youssef has ${YOUSSEF_WIP} active ticket(s) (limit 2) — skipping new dispatch"
  else
    YOUSSEF_SLOTS=$(( 2 - YOUSSEF_WIP ))
    log_info "WIP: Youssef has ${YOUSSEF_WIP} active → dispatching up to ${YOUSSEF_SLOTS} more"
    process_agent "youssef" "$YOUSSEF_SLOTS"
  fi

  # Nadia (QA) — up to 3 parallel reviews (per-ticket locks)
  process_agent "nadia" 3

  # Layla (Product) — WIP limit: max 1 ticket (single-lock agent)
  if [[ -f "/tmp/${PROJECT_PREFIX}-agent-layla.lock" ]]; then
    LAYLA_LOCK_AGE=$(( $(date +%s) - $(stat -c %Y /tmp/${PROJECT_PREFIX}-agent-layla.lock 2>/dev/null || echo 0) ))
    if (( LAYLA_LOCK_AGE < 1800 )); then
      log_info "WIP limit: Layla already running (lock age ${LAYLA_LOCK_AGE}s) — skipping dispatch"
    else
      process_agent "layla" 1
    fi
  else
    process_agent "layla" 1
  fi

  # Rami (Architect + DevOps) — up to 3 tickets (handles both architecture review and merge)
  process_agent "rami" 3

  # Omar (Ops) — health checks (no ticket needed)
  "${SCRIPT_DIR}/agent-omar.sh" &
  AGENT_PIDS+=($!)

  # ─── Layla Daily Report (once per day) ─────────────────────────────────
  DAILY_FLAG="/tmp/${PROJECT_PREFIX}-layla-daily-$(date -u +%Y-%m-%d)"
  if [[ ! -f "$DAILY_FLAG" ]]; then
    log_info "Running Layla daily report..."
    "${SCRIPT_DIR}/agent-layla-daily.sh" &
    AGENT_PIDS+=($!)
  fi

  # ─── Layla Weekly Report (Monday only) ─────────────────────────────────
  DAY_OF_WEEK=$(date -u +%u)  # 1=Monday
  WEEKLY_FLAG="/tmp/${PROJECT_PREFIX}-layla-weekly-$(date -u +%Y-W%V)"
  if [[ "$DAY_OF_WEEK" == "1" ]] && [[ ! -f "$WEEKLY_FLAG" ]]; then
    log_info "Running Layla weekly report (Monday)..."
    "${SCRIPT_DIR}/agent-layla-weekly.sh" &
    AGENT_PIDS+=($!)
  fi
fi

# ═══════════════════════════════════════════════════════════════════════════
# PHASE 4: Wait for all agents
# ═══════════════════════════════════════════════════════════════════════════
ALL_PIDS=("${RETRO_PIDS[@]}" "${AGENT_PIDS[@]}")
FAILURES=0
for pid in "${ALL_PIDS[@]}"; do
  wait "$pid" 2>/dev/null || ((FAILURES++)) || true
done
log_info "All agents complete. Failures: $FAILURES/${#ALL_PIDS[@]}"

# ═══════════════════════════════════════════════════════════════════════════
# PHASE 5: Sprint Ceremony (if sprint is complete)
# ═══════════════════════════════════════════════════════════════════════════
run_sprint_ceremony_if_needed() {
  # Runs ceremony-review.sh + ceremony-retro.sh when all In Progress tickets are done (Plane-based).
  # Sprint transition (close/open) is handled manually via n8n webhook.
  local CEREMONY_FLAG="/tmp/${PROJECT_PREFIX}-ceremony-done-$(date -u +%Y%m%d)"
  if [[ -f "$CEREMONY_FLAG" ]]; then
    log_info "Sprint ceremony already ran today"
    return
  fi

  # Count Plane tickets still in started/unstarted states
  local REMAINING=99
  local _tmp_plane
  _tmp_plane=$(mktemp /tmp/${PROJECT_PREFIX}-plane-check-XXXXXX.py)
  cat > "$_tmp_plane" << 'PLANE_PYEOF'
import os, sys, requests
base = os.environ.get('PLANE_BASE_URL', '').rstrip('/')
ws   = os.environ.get('PLANE_WORKSPACE_SLUG', '')
pid  = os.environ.get('PLANE_PROJECT_ID', '')
key  = os.environ.get('PLANE_API_KEY', '')
h    = {'X-API-Key': key, 'Content-Type': 'application/json'}
try:
    r  = requests.get(f'{base}/api/v1/workspaces/{ws}/projects/{pid}/states/', headers=h, timeout=15)
    states = r.json()
    if isinstance(states, dict): states = states.get('results', [])
    active_ids = {s['id'] for s in states if s.get('group') in ('started', 'unstarted')}
    r2 = requests.get(f'{base}/api/v1/workspaces/{ws}/projects/{pid}/issues/?per_page=250', headers=h, timeout=15)
    issues = r2.json()
    if isinstance(issues, dict): issues = issues.get('results', [])
    remaining = sum(1 for i in issues if i.get('state') in active_ids)
    print(remaining)
except Exception:
    print(99)
PLANE_PYEOF
  REMAINING=$(python3 "$_tmp_plane" 2>/dev/null || echo 99)
  rm -f "$_tmp_plane"
  REMAINING=$(echo "$REMAINING" | tr -d ' ')

  if [[ "$REMAINING" -gt 0 ]]; then
    log_info "Sprint not complete: ${REMAINING} non-done tickets remaining"
    return
  fi

  # Safety: max 2 ceremonies per week
  local CEREMONY_WEEK_COUNT
  CEREMONY_WEEK_COUNT=$(find /tmp -maxdepth 1 -name "${PROJECT_PREFIX}-ceremony-done-*" -mtime -7 2>/dev/null | wc -l || echo 0)
  if [[ "$CEREMONY_WEEK_COUNT" -ge "${MAX_SPRINTS_PER_WEEK:-2}" ]]; then
    log_info "Max sprint ceremonies this week reached. Skipping."
    return
  fi

  log_info "All tickets done — running sprint end ceremony..."
  slack_notify "omar" "Sprint complet ! Lancement de la review + retro..."

  # Phase 1: Sprint Review
  log_info "Ceremony Phase 1/2: Sprint Review"
  CEREMONY_SLEEP=5 bash "${SCRIPT_DIR}/ceremony-review.sh" 2>&1 || log_error "ceremony-review.sh failed"
  sleep 30

  # Phase 2: Retrospective
  log_info "Ceremony Phase 2/2: Sprint Retrospective"
  CEREMONY_SLEEP=5 bash "${SCRIPT_DIR}/ceremony-retro.sh" 2>&1 || log_error "ceremony-retro.sh failed"

  touch "$CEREMONY_FLAG"
  log_success "Sprint end ceremony complete. Trigger sprint transition via n8n when ready."
  slack_notify "omar" "Ceremonies Review + Retro terminees. Lance le sprint suivant via n8n."
}

run_sprint_ceremony_if_needed

# ═══════════════════════════════════════════════════════════════════════════
# PHASE 5.5: New Sprint Detection → Auto-trigger Planning Ceremony
# ═══════════════════════════════════════════════════════════════════════════
trigger_planning_if_new_sprint() {
  # Only relevant for Plane backend (Jira uses sprint labels, no cycle UUID)
  [[ "${TRACKER_BACKEND:-jira}" != "plane" ]] && return

  local LAST_CYCLE_FILE="/tmp/${PROJECT_PREFIX}-last-cycle-id"

  # Fetch the current active Plane cycle ID
  local CURRENT_CYCLE
  CURRENT_CYCLE=$(python3 - << 'PYEOF' 2>/dev/null
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
    sys.stderr.write(f'cycle lookup error: {e}\n')
PYEOF
  )

  [[ -z "$CURRENT_CYCLE" ]] && { log_info "Could not determine current Plane cycle — skipping planning check"; return; }

  local LAST_CYCLE
  LAST_CYCLE=$(cat "$LAST_CYCLE_FILE" 2>/dev/null || echo "")

  # First run ever: just record the cycle, don't trigger planning (sprint already in progress)
  if [[ -z "$LAST_CYCLE" ]]; then
    echo "$CURRENT_CYCLE" > "$LAST_CYCLE_FILE"
    log_info "First cycle ID recorded (${CURRENT_CYCLE}) — planning will auto-trigger on next sprint"
    return
  fi

  # Same cycle as last run — no change
  [[ "$CURRENT_CYCLE" == "$LAST_CYCLE" ]] && return

  # ── New sprint detected! ──────────────────────────────────────────────────
  echo "$CURRENT_CYCLE" > "$LAST_CYCLE_FILE"
  log_info "New sprint detected (${LAST_CYCLE} → ${CURRENT_CYCLE}) — triggering planning ceremony"

  # Idempotency: don't re-plan the same sprint if the cron ran twice in quick succession
  local PLANNING_FLAG="/tmp/${PROJECT_PREFIX}-planning-done-${CURRENT_CYCLE}"
  if [[ -f "$PLANNING_FLAG" ]]; then
    log_info "Planning already ran for cycle ${CURRENT_CYCLE} — skipping"
    return
  fi
  touch "$PLANNING_FLAG"

  slack_notify "omar" "Nouveau sprint detecte (${CURRENT_CYCLE:0:8}...) — lancement du Sprint Planning !" "sprint"
  nohup bash "${SCRIPT_DIR}/ceremony-planning.sh" >> ${LOG_DIR}/planning.log 2>&1 &
  log_info "Planning ceremony launched in background (PID=$!)"
}

trigger_planning_if_new_sprint

# ═══════════════════════════════════════════════════════════════════════════
# PHASE 6: Backlog Health Check (daily)
# ═══════════════════════════════════════════════════════════════════════════
check_backlog_health() {
  local HEALTH_FLAG="/tmp/${PROJECT_PREFIX}-backlog-check-$(date -u +%Y-%m-%d)"
  [[ -f "$HEALTH_FLAG" ]] && return

  # Count Plane backlog tickets (Todo/Backlog state, not in 'Blocked' state)
  local BACKLOG_COUNT
  local _tmp_bl
  _tmp_bl=$(mktemp /tmp/${PROJECT_PREFIX}-backlog-XXXXXX.py)
  cat > "$_tmp_bl" << 'PLANE_PYEOF'
import os, requests, json
base = os.environ.get('PLANE_BASE_URL','').rstrip('/')
ws   = os.environ.get('PLANE_WORKSPACE_SLUG','')
pid  = os.environ.get('PLANE_PROJECT_ID','')
key  = os.environ.get('PLANE_API_KEY','')
h    = {'X-API-Key': key}
try:
    r  = requests.get(f'{base}/api/v1/workspaces/{ws}/projects/{pid}/states/', headers=h, timeout=15)
    states = r.json()
    if isinstance(states, dict): states = states.get('results', [])
    state_name = {s['id']: s.get('name','') for s in states}
    todo_ids = {s['id'] for s in states if s.get('group') in ('backlog', 'unstarted')}

    r3 = requests.get(f'{base}/api/v1/workspaces/{ws}/projects/{pid}/issues/?per_page=250', headers=h, timeout=15)
    issues = r3.json()
    if isinstance(issues, dict): issues = issues.get('results', [])

    count = 0
    for i in issues:
        if i.get('state') not in todo_ids: continue
        # Labels removed — 'Blocked' is now a workflow state, exclude from backlog
        if state_name.get(i.get('state',''), '') == 'Blocked': continue
        count += 1
    print(count)
except Exception:
    print(0)
PLANE_PYEOF
  BACKLOG_COUNT=$(python3 "$_tmp_bl" 2>/dev/null || echo 0)
  rm -f "$_tmp_bl"
  BACKLOG_COUNT=$(echo "$BACKLOG_COUNT" | tr -d ' ')

  if [[ "$BACKLOG_COUNT" -lt 5 ]]; then
    slack_notify "omar" "⚠️ *Backlog Health Alert*: ${BACKLOG_COUNT} tickets actionnables en backlog. Pipeline peut stagner."
  fi

  touch "$HEALTH_FLAG"
}

check_backlog_health

# ═══════════════════════════════════════════════════════════════════════════
# PHASE 7: Build & Deploy Test Branch
# ═══════════════════════════════════════════════════════════════════════════
build_and_deploy_test() {
  # Safety: ensure we are on base branch before building
  cd "$PROJECT_DIR" && git checkout "${BASE_BRANCH}" -q 2>/dev/null || true
  local LAST_BUILD_HASH="/tmp/${PROJECT_PREFIX}-last-build-hash"
  local CURRENT_HASH
  CURRENT_HASH=$(cd "$PROJECT_DIR" && git rev-parse HEAD 2>/dev/null || echo "")
  local PREVIOUS_HASH
  PREVIOUS_HASH=$(cat "$LAST_BUILD_HASH" 2>/dev/null || echo "")
  
  if [[ "$CURRENT_HASH" == "$PREVIOUS_HASH" ]]; then
    return  # No new commits, skip build
  fi
  
  log_info "Building test branch for deployment..."
  cd "$PROJECT_DIR"
  
  # Install deps if needed
  npm install --silent 2>/dev/null || true
  
  # Build web app (use project config or skip if no build command)
  local BUILD_CMD="${PROJECT_BUILD_CMD:-npm run build}"
  local DEPLOY_DIR="${PROJECT_DEPLOY_DIR:-}"

  if [[ -z "$DEPLOY_DIR" ]]; then
    log_info "No PROJECT_DEPLOY_DIR configured, skipping build deploy"
    return
  fi

  if bash -c "$BUILD_CMD" 2>/dev/null; then
    # Try common output dirs
    for out_dir in dist build packages/web/dist; do
      if [[ -d "$out_dir" ]]; then
        cp -r "$out_dir"/* "$DEPLOY_DIR" 2>/dev/null || true
        break
      fi
    done
    echo "$CURRENT_HASH" > "$LAST_BUILD_HASH"
    log_info "Build deployed to ${DEPLOY_DIR}"
  else
    log_error "Build failed for test branch"
  fi
}

build_and_deploy_test

# ═══════════════════════════════════════════════════════════════════════════
# PHASE 8: Omar Cycle Summary (hourly, not every 15 min)
# ═══════════════════════════════════════════════════════════════════════════
generate_cycle_summary() {
  # Runs every cycle — Omar reads the actual agent logs and summarises what happened
  local CYCLE_TIME
  CYCLE_TIME=$(date -u '+%H:%M')

  # Build stuck ticket list
  local STUCK_TICKETS=""
  for retry_file in /tmp/${PROJECT_PREFIX}-retries/${PROJECT_KEY}-*; do
    [[ -f "$retry_file" ]] || continue
    local count
    count=$(cat "$retry_file" 2>/dev/null || echo 0)
    if [[ "$count" -ge 2 ]]; then
      STUCK_TICKETS+="$(basename "$retry_file")(${count}x) "
    fi
  done

  # Collect log snippets from agent runs that finished in the last 20 min
  local LOG_SNIPPETS=""
  local cutoff
  cutoff=$(date -u -d '20 minutes ago' +%s 2>/dev/null || date -u -v-20M +%s 2>/dev/null || echo 0)
  for lf in ${LOG_DIR}/BISB-*-*.log; do
    [[ -f "$lf" ]] || continue
    local mtime
    mtime=$(stat -c %Y "$lf" 2>/dev/null || stat -f %m "$lf" 2>/dev/null || echo 0)
    (( mtime >= cutoff )) || continue
    local fname
    fname=$(basename "$lf")
    # Extract last line (SUCCESS/FAIL) and any ERROR lines
    local last_line
    last_line=$(tail -1 "$lf" 2>/dev/null | grep -oE '\[(SUCCESS|ERROR|INFO)\].*' | head -c 120 || true)
    local errors
    errors=$(grep -E '\[ERROR\]|\[FAIL\]' "$lf" 2>/dev/null | tail -2 | head -c 200 || true)
    LOG_SNIPPETS+="• ${fname}: ${last_line:-?}"$'\n'
    [[ -n "$errors" ]] && LOG_SNIPPETS+="  ↳ ${errors}"$'\n'
  done

  log_info "Generating Omar cycle summary (${FAILURES} failures, stuck: ${STUCK_TICKETS:-None})..."

  local SUMMARY
  SUMMARY=$(claude -p --model haiku --max-turns 1 "Tu es Omar, le watchdog ops de ${PROJECT_KEY}. Rédige un résumé Slack COURT (max 3 lignes) du cycle de cron qui vient de se terminer.

Heure: ${CYCLE_TIME} UTC
Résultats: ${FAILURES}/${#ALL_PIDS[@]} runs ont échoué.
Tickets bloqués (≥2 tentatives): ${STUCK_TICKETS:-aucun}
Logs des agents ce cycle:
${LOG_SNIPPETS:-Aucun log disponible}

Règles: sois factuel, mentionne les tickets spécifiques si bloqués, pas de remplissage générique. Max 2 emojis. Utilise **gras** pour les tickets." 2>&1) || true

  if [[ -n "$SUMMARY" && "$SUMMARY" != *"Not logged"* && ${#SUMMARY} -gt 10 ]]; then
    slack_notify "omar" "$SUMMARY" "pipeline"
    log_info "Omar cycle summary posted"
  else
    # Fallback: concise plain text
    slack_notify "omar" "📊 **Cycle ${CYCLE_TIME} UTC** — ${FAILURES}/${#ALL_PIDS[@]} échecs. Bloqués: ${STUCK_TICKETS:-aucun}." "pipeline"
    log_info "Omar fallback summary posted"
  fi
}

log_info "Running Omar cycle summary..."
generate_cycle_summary

# ═══════════════════════════════════════════════════════════════════════════
# PHASE 9: Daily Health Digest (once per day)
# ═══════════════════════════════════════════════════════════════════════════
daily_health_digest() {
  local DIGEST_FLAG="/tmp/${PROJECT_PREFIX}-daily-digest-$(date -u +%Y-%m-%d)"
  [[ -f "$DIGEST_FLAG" ]] && return
  
  # Only run at ~08:00 UTC (first cycle of the workday)
  local HOUR=$(date -u +%H)
  [[ "$HOUR" -lt 7 ]] && return
  
  local DONE_COUNT IN_PROGRESS_COUNT BLOCKED_COUNT TOTAL_COUNT
  DONE_COUNT=$(jira_search_keys "project = ${JIRA_PROJECT} AND labels = 'sprint-active' AND statusCategory = 'Done'" "50" 2>/dev/null | wc -l || echo 0)
  TOTAL_COUNT=$(jira_search_keys "project = ${JIRA_PROJECT} AND labels = 'sprint-active'" "50" 2>/dev/null | wc -l || echo 0)
  BLOCKED_COUNT=$(jira_search_keys "project = ${JIRA_PROJECT} AND labels IN ('blocked','needs-human-review')" "50" 2>/dev/null | wc -l || echo 0)
  IN_PROGRESS_COUNT=$((TOTAL_COUNT - DONE_COUNT))
  
  DONE_COUNT=$(echo "$DONE_COUNT" | tr -d ' ')
  TOTAL_COUNT=$(echo "$TOTAL_COUNT" | tr -d ' ')
  BLOCKED_COUNT=$(echo "$BLOCKED_COUNT" | tr -d ' ')
  
  local ERROR_COUNT
  ERROR_COUNT=$(grep -c "ERROR\|FAIL" ${LOG_DIR}/cron.log 2>/dev/null || echo 0)
  
  local PCT=0
  if [[ "$TOTAL_COUNT" -gt 0 ]]; then
    PCT=$((DONE_COUNT * 100 / TOTAL_COUNT))
  fi
  
  slack_notify "omar" "📊 *${PROJECT_KEY} Daily Health Digest*
🏃 Sprint: ${DONE_COUNT}/${TOTAL_COUNT} done (${PCT}%)
🔧 In progress: ${IN_PROGRESS_COUNT}
🚫 Blocked: ${BLOCKED_COUNT}
⚠️ Errors (24h): ${ERROR_COUNT}
🌐 Test: http://49.13.225.201:3002
🎮 Alpha: http://49.13.225.201:3000"
  
  touch "$DIGEST_FLAG"
}

daily_health_digest

log_info "=== ${PROJECT_KEY} agent cron complete ==="
