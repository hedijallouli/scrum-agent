#!/usr/bin/env bash
# =============================================================================
# agent-omar.sh — Ops Watchdog: Monitors pipeline health (no Claude calls)
# Runs every 15 minutes alongside other agents via agent-cron.sh.
# Pure automated checks — no AI calls.
# =============================================================================
AGENT_NAME="omar"
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/agent-common.sh"

init_log "ops" "omar"
log_info "=== Omar (Ops) starting health checks ==="

# ─── Webhook retry helper ────────────────────────────────────────────────────
# Tries a webhook POST up to N times with exponential backoff.
# Usage: trigger_webhook <url> <payload> <label> [max_retries]
trigger_webhook() {
  local url="$1" payload="$2" label="$3" max_retries="${4:-3}"
  local attempt=1 wait_secs=5

  while (( attempt <= max_retries )); do
    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$url" \
      -H "Content-Type: application/json" \
      -d "$payload" 2>/dev/null || echo "000")

    if [[ "$http_code" =~ ^2 ]]; then
      log_info "${label}: triggered successfully (attempt ${attempt})"
      return 0
    fi

    log_info "${label}: attempt ${attempt}/${max_retries} failed (HTTP ${http_code}), retrying in ${wait_secs}s..."
    sleep "$wait_secs"
    wait_secs=$(( wait_secs * 2 ))
    attempt=$(( attempt + 1 ))
  done

  log_info "${label}: FAILED after ${max_retries} attempts"
  return 1
}

# ─── Acquire lock ─────────────────────────────────────────────────────────────
if ! acquire_lock; then
  log_info "Another Omar instance running. Skipping."
  exit 0
fi

ALERTS=""
add_alert() {
  if [[ -n "$ALERTS" ]]; then
    ALERTS="${ALERTS}
${1}"
  else
    ALERTS="$1"
  fi
}

# ─── Track merged PRs → move Done tickets to Merged ──────────────────────────
if declare -f plane_get_assigned_tickets &>/dev/null && declare -f plane_update_state &>/dev/null; then
  DONE_TICKETS=$(plane_get_assigned_tickets "omar" 10 2>/dev/null || echo "")
  if [[ -n "$DONE_TICKETS" ]]; then
    log_info "Omar checking ${DONE_TICKETS} for merged PRs..."
    for DONE_TICKET in $DONE_TICKETS; do
      [[ -z "$DONE_TICKET" ]] && continue
      # Check if this ticket has a merged PR into master
      MERGED_PR_NUM=$(cd "$PROJECT_DIR" && gh pr list \
        --repo "${GITHUB_REPO:-}" \
        --state merged \
        --base master \
        --search "${DONE_TICKET}" \
        --json number,title \
        --jq ".[0].number" 2>/dev/null || echo "")
      if [[ -n "$MERGED_PR_NUM" ]]; then
        log_info "PR #${MERGED_PR_NUM} merged for ${DONE_TICKET} — marking Merged"
        plane_update_state "$DONE_TICKET" "Merged" 2>/dev/null || true
        plane_set_assignee "$DONE_TICKET" "" 2>/dev/null || true
        TICKET_KEY="$DONE_TICKET"
        slack_notify "$(mm_ticket_link "${DONE_TICKET}") — PR #${MERGED_PR_NUM} mergée dans master. Ticket marqué **Merged**." "pipeline" "good"
        log_activity "omar" "$DONE_TICKET" "MERGED" "PR #${MERGED_PR_NUM} merged into master"
      else
        log_info "${DONE_TICKET} not yet merged — waiting for Hedi to merge"
      fi
    done
  fi
fi

# ─── 1. Blocked tickets (Plane state-based) ─────────────────────────────────
log_info "Check 1: Blocked tickets..."
if [[ "${TRACKER_BACKEND:-jira}" == "plane" ]]; then
  _bl_script=$(mktemp /tmp/${PROJECT_PREFIX}-omar-bl-XXXXXX.py)
  cat > "$_bl_script" << 'BLPYEOF'
import os, requests
OMAR_ID = "435563ee-fef1-4cab-9048-653e0e7bb74a"
project_key = os.environ.get('JIRA_PROJECT', 'BISB')
base = os.environ.get('PLANE_BASE_URL','').rstrip('/')
ws   = os.environ.get('PLANE_WORKSPACE_SLUG','')
pid  = os.environ.get('PLANE_PROJECT_ID','')
key  = os.environ.get('PLANE_API_KEY','')
h    = {'X-API-Key': key, 'Content-Type': 'application/json'}
sr = requests.get(f'{base}/api/v1/workspaces/{ws}/projects/{pid}/states/', headers=h, timeout=10)
states = sr.json().get('results', [])
state_name = {s['id']: s.get('name','') for s in states}
done_ids = {s['id'] for s in states if s.get('group') == 'completed'}
r = requests.get(f'{base}/api/v1/workspaces/{ws}/projects/{pid}/issues/?per_page=200', headers=h, timeout=15)
issues = r.json().get('results', [])
results = []
for issue in issues:
    if issue.get('state') in done_ids: continue
    if state_name.get(issue.get('state',''), '') != 'Blocked': continue
    assignees = issue.get('assignees', [])
    seq = issue.get('sequence_id','?')
    title = issue.get('name','')[:50]
    # Ensure Omar is sole assignee (unblock ownership)
    if not (assignees == [OMAR_ID]):
        requests.patch(f'{base}/api/v1/workspaces/{ws}/projects/{pid}/issues/{issue["id"]}/',
                       headers=h, json={'assignees': [OMAR_ID]}, timeout=10)
    results.append(f'{project_key}-{seq}')
    print(f'{project_key}-{seq}|{title}')
BLPYEOF
  BLOCKED_DETAILS=$(python3 "$_bl_script" 2>/dev/null || true)
  rm -f "$_bl_script"
  BLOCKED_TICKETS=$(echo "$BLOCKED_DETAILS" | cut -d'|' -f1 | grep -v '^$' || true)
else
  BLOCKED_TICKETS=$(jira_search_keys "project = ${JIRA_PROJECT} AND labels = 'blocked' AND statusCategory != 'Done'" "20" || true)
  BLOCKED_DETAILS="$BLOCKED_TICKETS"
fi

if [[ -n "$BLOCKED_TICKETS" ]]; then
  BLOCKED_COUNT=$(echo "$BLOCKED_TICKETS" | grep -c '[A-Z]' || true)
  BLOCKED_LIST=$(echo "$BLOCKED_TICKETS" | tr '\n' ' ' | xargs)
  add_alert "${BLOCKED_COUNT} ticket(s) bloqué(s) → assigné(s) à Omar: ${BLOCKED_LIST}"
  log_info "Found ${BLOCKED_COUNT} blocked tickets — Omar set as sole assignee"
else
  log_info "No blocked tickets"
fi

# ─── 1b. Repeated failures — auto-unblock stuck tickets ───────────────────
log_info "Check 1b: Repeated failures (auto-unblock)..."
for retry_file in "${RETRY_DIR}"/${PROJECT_KEY}-*; do
  [[ -f "$retry_file" ]] || continue
  retry_basename=$(basename "$retry_file")
  # Extract ticket and agent from filename (e.g., CDO-16-youssef)
  retry_ticket=$(echo "$retry_basename" | grep -oE "${PROJECT_KEY}-[0-9]+")
  retry_agent=$(echo "$retry_basename" | sed "s/${retry_ticket}-//")
  [[ -z "$retry_ticket" || -z "$retry_agent" ]] && continue

  retry_count=$(cat "$retry_file" 2>/dev/null || echo "0")
  if (( retry_count >= 2 )); then
    log_info "Ticket ${retry_ticket} stuck with ${retry_agent} (${retry_count} retries) — auto-unblocking"

    # Track cumulative attempts across all escalation cycles
    TOTAL_ATTEMPTS_DIR="/tmp/${PROJECT_PREFIX}-total-attempts"
    mkdir -p "$TOTAL_ATTEMPTS_DIR"
    TOTAL_FILE="${TOTAL_ATTEMPTS_DIR}/${retry_ticket}"
    TOTAL_ATTEMPTS=$(cat "$TOTAL_FILE" 2>/dev/null || echo "0")
    TOTAL_ATTEMPTS=$(( TOTAL_ATTEMPTS + retry_count ))
    echo "$TOTAL_ATTEMPTS" > "$TOTAL_FILE"

    # Read the latest error from feedback for context
    LATEST_ERROR=$(cat "${FEEDBACK_DIR}/${retry_ticket}.txt" 2>/dev/null | head -5 | tr '\n' ' ' || echo "Unknown error")

    if (( TOTAL_ATTEMPTS >= 6 )); then
      # Too many total attempts — escalate to human, stop looping
      log_info "Ticket ${retry_ticket} has ${TOTAL_ATTEMPTS} total attempts ��� escalating to Needs Human"
      plane_set_state "${retry_ticket}" "Needs Human" 2>/dev/null || true
      plane_set_assignee "${retry_ticket}" "hedi" 2>/dev/null || true

      jira_add_rich_comment "$retry_ticket" "omar" "ESCALATION" "## Escaladé à Hedi
${retry_ticket} a échoué **${TOTAL_ATTEMPTS} fois au total** (${retry_count} dernières par ${retry_agent}).
Les agents ne peuvent pas résoudre ce problème seuls.

Dernier contexte d'erreur : ${LATEST_ERROR}

État → Needs Human. @hedi doit intervenir." || true

      slack_notify "**Escalade humaine** — *$(mm_ticket_link "${retry_ticket}")* après **${TOTAL_ATTEMPTS} tentatives totales**.
Les agents ne peuvent pas résoudre. @hedi doit intervenir." "alerts" "danger" 2>/dev/null || true

      rm -f "$retry_file"
      add_alert "${retry_ticket} escaladé à Hedi (${TOTAL_ATTEMPTS} tentatives totales)"
      log_activity "omar" "$retry_ticket" "ESCALATE_HUMAN" "Needs Human after ${TOTAL_ATTEMPTS} total attempts"
    else
      # Normal auto-block — Omar triages
      plane_set_state "${retry_ticket}" "Blocked" 2>/dev/null || true
      plane_set_assignee "${retry_ticket}" "omar" 2>/dev/null || true

      jira_add_rich_comment "$retry_ticket" "omar" "WARNING" "## Auto-Bloqué
${retry_ticket} bloqué après ${retry_count} tentatives par ${retry_agent} (${TOTAL_ATTEMPTS} total).
Réassigné à Omar pour triage.

Dernier contexte d'erreur : ${LATEST_ERROR}

État → Blocked. Omar va investiguer." || true

      slack_notify "**Ticket auto-bloqué** — *$(mm_ticket_link "${retry_ticket}")* après **${retry_count} tentatives** par ${retry_agent} (${TOTAL_ATTEMPTS} total).
Réassigné à Omar pour triage." "alerts" "danger" 2>/dev/null || true

      rm -f "$retry_file"
      add_alert "${retry_ticket} auto-bloqué (${retry_count} échecs par ${retry_agent}, ${TOTAL_ATTEMPTS} total) → Omar"
      log_activity "omar" "$retry_ticket" "AUTO_BLOCK_REASSIGN" "Set Blocked + assigned Omar after ${retry_count} failures by ${retry_agent} (${TOTAL_ATTEMPTS} total)"
    fi
  fi
done

# ─── 2. Stale locks ─────────────────────────────────────────────────────────
log_info "Check 2: Stale agent locks..."
for lockfile in /tmp/${PROJECT_PREFIX}-agent-*.lock; do
  [[ -f "$lockfile" ]] || continue
  # Skip our own lock
  [[ "$lockfile" == *"omar.lock" ]] && continue
  lock_age=$(( $(date +%s) - $(stat -c %Y "$lockfile" 2>/dev/null || stat -f %m "$lockfile" 2>/dev/null || echo 0) ))
  if (( lock_age > LOCK_MAX_AGE )); then
    # Extract agent name from lock file (e.g. "nadia" from "cdo-agent-nadia-CDO-17.lock")
    lock_basename=$(basename "$lockfile" .lock)
    agent_name=$(echo "$lock_basename" | sed "s/${PROJECT_PREFIX}-agent-//" | sed "s/-${PROJECT_KEY}-.*//")
    lock_hours=$(( lock_age / 3600 ))
    add_alert "Cleared stale lock for ${agent_name} (stuck ${lock_hours}h)"
    rm -f "$lockfile"
    log_info "Removed stale lock: ${lockfile} (age=${lock_age}s)"
  fi
done

# ─── 2b. Sonnet rate limit status ──────────────────────────────────────────
log_info "Check 2b: Sonnet rate limit..."
if is_sonnet_rate_limited; then
  add_alert "Sonnet rate-limited (Haiku fallback active)"
fi

# ─── 3. Agent health (recent activity) ──────────────────────────────────────
# Only flag agents idle for >24h to avoid spamming — agents like Salma,
# Layla only activate on specific triggers and are expected to be idle most cycles.
log_info "Check 4: Agent health..."
ONE_DAY_AGO=$(( $(date +%s) - 86400 ))
for agent in salma youssef nadia layla rami; do
  LATEST_LOG=$(ls -t "${LOG_DIR}/"*-${agent}-*.log 2>/dev/null | head -1 || true)
  if [[ -n "$LATEST_LOG" ]]; then
    log_mtime=$(stat -c %Y "$LATEST_LOG" 2>/dev/null || stat -f %m "$LATEST_LOG" 2>/dev/null || echo 0)
    if (( log_mtime < ONE_DAY_AGO )); then
      log_info "Agent ${agent}: no recent activity (last log > 24h ago)"
      add_alert "Agent ${agent} idle > 24h"
    fi
  fi
done

# ─── 5. Stale PRs ───────────────────────────────────────────────────────────
log_info "Check 5: Stale PRs..."
cd "$PROJECT_DIR"
STALE_PRS=$(gh pr list --state open --json number,title,createdAt \
  --jq "[.[] | select((.createdAt | fromdateiso8601) < (now - 86400))] | .[].title" 2>/dev/null) || true
if [[ -n "$STALE_PRS" ]]; then
  STALE_COUNT=$(echo "$STALE_PRS" | wc -l | tr -d ' ')
  add_alert "${STALE_COUNT} PR(s) open > 24h"
  log_info "Found ${STALE_COUNT} stale PRs"
else
  log_info "No stale PRs"
fi

# ─── 6. n8n process check ───────────────────────────────────────────────────
log_info "Check 6: n8n process..."
if ! pgrep -f "n8n" > /dev/null 2>&1; then
  add_alert "n8n process is not running"
  log_info "n8n is not running"
else
  log_info "n8n is running"
fi

# ─── 7. Orphaned tickets (active but no assignee) ─────────────────────────
# In Plane mode: find tickets in active states with NO assignee, auto-assign.
log_info "Check 7: Orphaned (unassigned active) tickets..."
if [[ "${TRACKER_BACKEND:-jira}" == "plane" ]]; then
  _op_script=$(mktemp /tmp/${PROJECT_PREFIX}-omar-op-XXXXXX.py)
  cat > "$_op_script" << 'OPPYEOF'
import os, requests
project_key = os.environ.get('JIRA_PROJECT', 'BISB')
base = os.environ.get('PLANE_BASE_URL','').rstrip('/')
ws   = os.environ.get('PLANE_WORKSPACE_SLUG','')
pid  = os.environ.get('PLANE_PROJECT_ID','')
key  = os.environ.get('PLANE_API_KEY','')
h    = {'X-API-Key': key, 'Content-Type': 'application/json'}
sr = requests.get(f'{base}/api/v1/workspaces/{ws}/projects/{pid}/states/', headers=h, timeout=10)
states = sr.json().get('results', [])
state_name = {s['id']: s.get('name','') for s in states}
done_ids = {s['id'] for s in states if s.get('group') == 'completed'}
r = requests.get(f'{base}/api/v1/workspaces/{ws}/projects/{pid}/issues/?per_page=200', headers=h, timeout=15)
issues = r.json().get('results', [])
# State → default assignee mapping
ASSIGN = {
    'In Review': 'nadia',
    'Ready':     'youssef',
    'In Progress': 'youssef',
    'Todo':      'salma',
    'Backlog':   'salma',
}
AGENT_IDS = {
    'salma':   'e00f100f-6389-4bb0-8348-391ff8919c8d',
    'youssef': '2fdb6929-392f-4b0c-bb18-3e45c5121ec4',
    'nadia':   '64f56e16-7ed3-4812-b09b-912f6a615e12',
}
for issue in issues:
    if issue.get('state') in done_ids: continue
    sn = state_name.get(issue.get('state',''), '')
    if sn in ('Blocked', 'Needs Human'): continue
    if issue.get('assignees'): continue  # already assigned
    target_agent = ASSIGN.get(sn)
    if not target_agent: continue
    target_id = AGENT_IDS[target_agent]
    seq = issue.get('sequence_id','?')
    r2 = requests.patch(f'{base}/api/v1/workspaces/{ws}/projects/{pid}/issues/{issue["id"]}/',
                        headers=h, json={'assignees': [target_id]}, timeout=10)
    status = 'OK' if r2.status_code in (200,201) else f'ERR{r2.status_code}'
    print(f'{project_key}-{seq}|{target_agent}|{sn}|{status}')
OPPYEOF
  ORPHAN_RESULTS=$(python3 "$_op_script" 2>/dev/null || true)
  rm -f "$_op_script"
  if [[ -n "$ORPHAN_RESULTS" ]]; then
    ORPHAN_COUNT=$(echo "$ORPHAN_RESULTS" | grep -c '|' || true)
    while IFS='|' read -r ot oa os ostatus; do
      log_info "Auto-assigned orphan ${ot} → ${oa} (state: ${os}, ${ostatus})"
    done <<< "$ORPHAN_RESULTS"
    ORPHAN_LIST=$(echo "$ORPHAN_RESULTS" | cut -d'|' -f1 | tr '\n' ' ' | xargs)
    add_alert "${ORPHAN_COUNT} ticket(s) sans assignee auto-assigné(s): ${ORPHAN_LIST}"
  else
    log_info "No orphaned tickets"
  fi
else
  ORPHANS=$(jira_search_keys "project = ${JIRA_PROJECT} AND labels = 'sprint-active' AND statusCategory != 'Done' AND NOT (labels = 'agent:salma' OR labels = 'agent:youssef' OR labels = 'agent:nadia')" "10" || true)
  if [[ -n "$ORPHANS" ]]; then
    log_info "Found orphaned tickets (Jira): ${ORPHANS}"
    add_alert "Orphaned tickets: ${ORPHANS}"
  else
    log_info "No orphaned tickets"
  fi
fi

# ─── 8. Sprint completion detection ──────────────────────────────────────────
# When ALL sprint-active tickets are Done → trigger Review → Refinement → Retro chain
log_info "Check 8: Sprint completion..."
SPRINT_COMPLETION_FLAG="/tmp/${PROJECT_PREFIX}-sprint-complete-$(date +%Y-%m-%d)"

if [[ ! -f "$SPRINT_COMPLETION_FLAG" ]]; then
  if [[ "${TRACKER_BACKEND:-jira}" == "plane" ]]; then
    SPRINT_TOTAL=$(python3 - << 'SPYEOF' 2>/dev/null || echo "0/0"
import os, requests
base = os.environ.get('PLANE_BASE_URL','').rstrip('/')
ws   = os.environ.get('PLANE_WORKSPACE_SLUG','')
pid  = os.environ.get('PLANE_PROJECT_ID','')
key  = os.environ.get('PLANE_API_KEY','')
h    = {'X-API-Key': key}
sr = requests.get(f'{base}/api/v1/workspaces/{ws}/projects/{pid}/states/', headers=h, timeout=10)
states = sr.json().get('results', [])
done_ids = {s['id'] for s in states if s.get('group') == 'completed'}
r = requests.get(f'{base}/api/v1/workspaces/{ws}/projects/{pid}/issues/?per_page=200', headers=h, timeout=15)
issues = r.json().get('results', [])
total = len(issues)
done = sum(1 for i in issues if i.get('state') in done_ids)
print(f'{done}/{total}')
SPYEOF
)
  else
    SPRINT_TOTAL=$(jira_search "project = ${JIRA_PROJECT} AND labels = 'sprint-active'" "50" | python3 -c "
import sys,json
d=json.load(sys.stdin)
issues=d.get('issues',[])
total=len(issues)
done=sum(1 for i in issues if i.get('fields',{}).get('status',{}).get('statusCategory',{}).get('key')=='done')
print(f'{done}/{total}')
" 2>/dev/null || echo "0/0")
  fi

  SPRINT_DONE=$(echo "$SPRINT_TOTAL" | cut -d/ -f1)
  SPRINT_ALL=$(echo "$SPRINT_TOTAL" | cut -d/ -f2)

  if (( SPRINT_ALL > 0 )) && (( SPRINT_DONE == SPRINT_ALL )); then
    log_info "Sprint complete! All ${SPRINT_ALL} tickets done. Triggering review chain."

    # ─── Velocity tracking: calculate sprint person-days ───────────────
    SPRINT_NUM_FILE="/tmp/${PROJECT_PREFIX}-sprint-number"
    CURRENT_SPRINT_NUM=$(cat "$SPRINT_NUM_FILE" 2>/dev/null || echo "1")

    # Sum delivered person-days from completed tickets
    DELIVERED_PD=$(sum_sprint_person_days)
    # Planned PD = delivered PD for now (until Sprint Planning sets planned separately)
    PLANNED_PD="$DELIVERED_PD"

    # Save sprint velocity data
    save_sprint_data "$CURRENT_SPRINT_NUM" "$PLANNED_PD" "$DELIVERED_PD" "$SPRINT_ALL" "$SPRINT_DONE"

    # Increment sprint number for next sprint
    echo $(( CURRENT_SPRINT_NUM + 1 )) > "$SPRINT_NUM_FILE"

    VELOCITY=$(get_velocity)
    log_info "Sprint ${CURRENT_SPRINT_NUM} velocity: ${VELOCITY} (${DELIVERED_PD} PD delivered)"

    # Get n8n base URL (local or via env)
    N8N_URL="${N8N_URL:-http://localhost:5678}"
    CEREMONY_PAYLOAD='{"trigger":"omar","reason":"all_tickets_done"}'

    # Only trigger Sprint Review — it chains to Retro (after approval),
    # and Retro chains to Backlog Refinement (after approval).
    # This ensures correct ceremony order: Review → Retro → Refinement.
    FLAG_REVIEW="${SPRINT_COMPLETION_FLAG}-review"

    # DISABLED: Ceremony webhook and flag - now handled by agent-cron.sh
    # (Original block triggered bisb-sprint-review webhook and set FLAG_REVIEW)
    log_info "Sprint ceremony detection: skipping webhook - handled by cron"

    touch "$SPRINT_COMPLETION_FLAG"
    log_info "Agents auto-paused (sprint complete)"
    add_alert "Sprint ${CURRENT_SPRINT_NUM} complete — ${SPRINT_ALL} tickets, ${DELIVERED_PD} person-days, velocity=${VELOCITY}. Ceremony chain triggered."
    slack_notify "**Sprint ${CURRENT_SPRINT_NUM} terminé !** ${SPRINT_ALL} tickets livrés.\n**Livré :** ${DELIVERED_PD} j-p | **Vélocité :** ${VELOCITY}\nCérémonie : Review → Rétro → Refinement\n\n$(mm_mention salma) $(mm_mention rami) — bilan à faire !" "alerts" "good"

    log_activity "omar" "OPS" "SPRINT_COMPLETE" "Sprint ${CURRENT_SPRINT_NUM}: ${SPRINT_ALL} tickets, ${DELIVERED_PD} PD, velocity=${VELOCITY}"
  else
    CURRENT_PD=$(sum_sprint_person_days)
    log_info "Sprint progress: ${SPRINT_DONE}/${SPRINT_ALL} done (${CURRENT_PD} person-days estimated)"
  fi
else
  log_info "Sprint completion already detected today — skipping"
fi

# ─── 9. Auto-trigger triage when tickets need review ─────────────────────────
log_info "Check 9: Blocked tickets needing triage..."
TRIAGE_REVIEWED_FILE="/tmp/${PROJECT_PREFIX}-triage-reviewed-tickets"
TRIAGE_COOLDOWN_FILE="/tmp/${PROJECT_PREFIX}-triage-cooldown"

# Cooldown: max 1 auto-triage per 2 hours
TRIAGE_COOLDOWN=false
if [[ -f "$TRIAGE_COOLDOWN_FILE" ]]; then
  COOLDOWN_AGE=$(( $(date +%s) - $(stat -c %Y "$TRIAGE_COOLDOWN_FILE" 2>/dev/null || stat -f %m "$TRIAGE_COOLDOWN_FILE" 2>/dev/null || echo 0) ))
  if (( COOLDOWN_AGE < 7200 )); then
    TRIAGE_COOLDOWN=true
  fi
fi

if [[ "$TRIAGE_COOLDOWN" == "false" ]]; then
  # Plane: 'Blocked' state replaces the old 'needs-standup-review' label
  if [[ "${TRACKER_BACKEND:-jira}" == "plane" ]]; then
    REVIEW_TICKETS=$(python3 - << 'TRPYEOF' 2>/dev/null || true
import os, requests
project_key = os.environ.get('JIRA_PROJECT', 'BISB')
base = os.environ.get('PLANE_BASE_URL','').rstrip('/')
ws   = os.environ.get('PLANE_WORKSPACE_SLUG','')
pid  = os.environ.get('PLANE_PROJECT_ID','')
key  = os.environ.get('PLANE_API_KEY','')
h    = {'X-API-Key': key}
sr = requests.get(f'{base}/api/v1/workspaces/{ws}/projects/{pid}/states/', headers=h, timeout=10)
states = sr.json().get('results', [])
state_name = {s['id']: s.get('name','') for s in states}
done_ids = {s['id'] for s in states if s.get('group') == 'completed'}
r = requests.get(f'{base}/api/v1/workspaces/{ws}/projects/{pid}/issues/?per_page=200', headers=h, timeout=15)
issues = r.json().get('results', [])
for issue in issues:
    if issue.get('state') in done_ids: continue
    if state_name.get(issue.get('state',''), '') != 'Blocked': continue
    print(f'{project_key}-{issue.get("sequence_id","?")}')
TRPYEOF
)
  else
    REVIEW_TICKETS=$(jira_search_keys "project = ${JIRA_PROJECT} AND labels = 'needs-standup-review' AND statusCategory != 'Done'" "20" || true)
  fi
  if [[ -n "$REVIEW_TICKETS" ]]; then
    # Check if these are NEW tickets not yet covered by a previous triage
    ALREADY_REVIEWED=$(cat "$TRIAGE_REVIEWED_FILE" 2>/dev/null || true)
    NEW_TICKETS=""
    for ticket in $REVIEW_TICKETS; do
      if ! echo "$ALREADY_REVIEWED" | grep -q "$ticket"; then
        NEW_TICKETS="${NEW_TICKETS}${ticket} "
      fi
    done
    NEW_TICKETS=$(echo "$NEW_TICKETS" | xargs)  # trim

    if [[ -n "$NEW_TICKETS" ]]; then
      NEW_COUNT=$(echo "$NEW_TICKETS" | wc -w | tr -d ' ')
      log_info "Found ${NEW_COUNT} blocked ticket(s) needing triage: ${NEW_TICKETS}"

      N8N_URL="${N8N_URL:-http://localhost:5678}"
      if trigger_webhook "${N8N_URL}/webhook/${PROJECT_PREFIX}-daily-standup" "{\"trigger\":\"omar\",\"reason\":\"triage\",\"tickets\":\"${NEW_TICKETS}\"}" "Blocker Triage (auto)"; then
        touch "$TRIAGE_COOLDOWN_FILE"
        echo "$REVIEW_TICKETS" >> "$TRIAGE_REVIEWED_FILE"
        add_alert "Auto-triggered triage for ${NEW_COUNT} blocked ticket(s): ${NEW_TICKETS}"
        log_activity "omar" "OPS" "TRIAGE_TRIGGER" "Auto-triggered triage for ${NEW_COUNT} blocked ticket(s)"
      else
        add_alert "Failed to auto-trigger triage for blocked tickets: ${NEW_TICKETS}"
      fi
    else
      log_info "All blocked tickets already covered by previous triage"
    fi
  else
    log_info "No blocked tickets needing triage"
  fi
else
  log_info "Triage cooldown active (< 2h since last auto-trigger) — skipping"
fi

# ─── 10. Report ──────────────────────────────────────────────────────────────
if [[ -n "$ALERTS" ]]; then
  # Hourly flag to avoid spamming the same alerts every 15 min
  FLAG_FILE="/tmp/${PROJECT_PREFIX}-omar-alert-$(date +%Y-%m-%d-%H)"
  if [[ ! -f "$FLAG_FILE" ]]; then
    slack_notify "**Rapport santé pipeline** — $(date +"%H:%M")\n\n${ALERTS}" "pipeline" "warning"
    touch "$FLAG_FILE"
    log_info "Slack alert sent"
  else
    log_info "Alert already sent this hour — skipping Slack"
  fi
else
  log_info "All checks passed — no issues found"
fi

# ─── 11. Generate Dashboard (daily) ─────────────────────────────────────────
DASHBOARD_FLAG="/tmp/${PROJECT_PREFIX}-dashboard-$(date +%Y-%m-%d)"
if [[ ! -f "$DASHBOARD_FLAG" ]]; then
  log_info "Generating daily dashboard..."
  DASHBOARD_DIR="/var/www/${PROJECT_PREFIX}-dashboard"
  mkdir -p "$DASHBOARD_DIR"

  # Gather all metrics
  SPRINT_PD=$(sum_sprint_person_days)
  TEAM_VELOCITY=$(get_velocity)
  BUDGET_INFO=$(get_budget_status 2>/dev/null || echo "No data")

  # Count sprint stats from Jira
  SPRINT_STATS=$(jira_search "project = ${JIRA_PROJECT} AND labels = 'sprint-active'" "50" | python3 -c "
import sys,json
d=json.load(sys.stdin)
issues=d.get('issues',[])
total=len(issues)
done=sum(1 for i in issues if i.get('fields',{}).get('status',{}).get('statusCategory',{}).get('key')=='done')
inprog=sum(1 for i in issues if i.get('fields',{}).get('status',{}).get('statusCategory',{}).get('key')=='indeterminate')
todo=total-done-inprog
pct=round(done*100/total) if total>0 else 0
print(json.dumps({'done':done,'inprog':inprog,'todo':todo,'total':total,'pct':pct}))
" 2>/dev/null || echo '{"done":0,"inprog":0,"todo":0,"total":0,"pct":0}')

  DONE_N=$(echo "$SPRINT_STATS" | python3 -c "import sys,json; print(json.load(sys.stdin)['done'])" 2>/dev/null || echo 0)
  INPROG_N=$(echo "$SPRINT_STATS" | python3 -c "import sys,json; print(json.load(sys.stdin)['inprog'])" 2>/dev/null || echo 0)
  TODO_N=$(echo "$SPRINT_STATS" | python3 -c "import sys,json; print(json.load(sys.stdin)['todo'])" 2>/dev/null || echo 0)
  TOTAL_N=$(echo "$SPRINT_STATS" | python3 -c "import sys,json; print(json.load(sys.stdin)['total'])" 2>/dev/null || echo 0)
  PCT_N=$(echo "$SPRINT_STATS" | python3 -c "import sys,json; print(json.load(sys.stdin)['pct'])" 2>/dev/null || echo 0)

  # Velocity history
  VELOCITY_DATA="[]"
  if [[ -f "${DATA_DIR}/metrics/velocity.jsonl" ]]; then
    VELOCITY_DATA=$(python3 -c "
import json
entries = []
with open('${DATA_DIR}/metrics/velocity.jsonl') as f:
    for line in f:
        try:
            entries.append(json.loads(line))
        except:
            pass
print(json.dumps(entries[-10:]))  # last 10 sprints
" 2>/dev/null || echo "[]")
  fi

  # Agent activity
  AGENT_STATUS=""
  for agt in salma youssef nadia rami; do
    ACT_FILE="${DATA_DIR}/agents/${agt}/last-activity.json"
    if [[ -f "$ACT_FILE" ]]; then
      AGT_INFO=$(python3 -c "
import json
from datetime import datetime, timezone
d = json.load(open('$ACT_FILE'))
ts = d.get('timestamp','')
ticket = d.get('ticket','N/A')
action = d.get('action','idle')
try:
    dt = datetime.fromisoformat(ts.replace('Z','+00:00'))
    ago = datetime.now(timezone.utc) - dt
    hours = int(ago.total_seconds() / 3600)
    time_str = f'{hours}h ago' if hours > 0 else 'just now'
except:
    time_str = 'unknown'
print(f'{action} on {ticket} ({time_str})')
" 2>/dev/null || echo "idle")
    else
      AGT_INFO="no activity"
    fi
    AGENT_STATUS="${AGENT_STATUS}<tr><td>${agt^}</td><td>${AGT_INFO}</td></tr>"
  done

  # Stuck tickets
  STUCK_ROWS=""
  for f in /tmp/${PROJECT_PREFIX}-retries/${PROJECT_KEY}-*; do
    [[ -f "$f" ]] || continue
    cnt=$(cat "$f" 2>/dev/null || echo 0)
    if [[ "$cnt" -ge 2 ]]; then
      tname=$(basename "$f" | grep -oP "${PROJECT_KEY}-\\d+" || basename "$f")
      STUCK_ROWS="${STUCK_ROWS}<tr><td>${tname}</td><td>${cnt} retries</td></tr>"
    fi
  done
  [[ -z "$STUCK_ROWS" ]] && STUCK_ROWS="<tr><td colspan='2'>None</td></tr>"

  # Generate HTML
  cat > "${DASHBOARD_DIR}/index.html" << 'DASHBOARD_EOF'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>${PROJECT_KEY} Agent Dashboard</title>
<style>
  * { margin: 0; padding: 0; box-sizing: border-box; }
  body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif; background: #0f172a; color: #e2e8f0; padding: 20px; }
  h1 { color: #38bdf8; margin-bottom: 20px; font-size: 1.5rem; }
  .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(280px, 1fr)); gap: 16px; margin-bottom: 20px; }
  .card { background: #1e293b; border-radius: 12px; padding: 20px; border: 1px solid #334155; }
  .card h2 { color: #94a3b8; font-size: 0.85rem; text-transform: uppercase; letter-spacing: 0.05em; margin-bottom: 12px; }
  .metric { font-size: 2rem; font-weight: 700; color: #f1f5f9; }
  .metric-label { font-size: 0.8rem; color: #64748b; }
  .progress-bar { height: 8px; background: #334155; border-radius: 4px; margin-top: 8px; overflow: hidden; }
  .progress-fill { height: 100%; border-radius: 4px; transition: width 0.3s; }
  .green { background: #22c55e; }
  .yellow { background: #eab308; }
  .red { background: #ef4444; }
  .blue { background: #3b82f6; }
  table { width: 100%; border-collapse: collapse; }
  td { padding: 8px 12px; border-bottom: 1px solid #334155; font-size: 0.9rem; }
  tr:last-child td { border-bottom: none; }
  .timestamp { color: #64748b; font-size: 0.75rem; text-align: right; margin-top: 20px; }
</style>
</head>
<body>
<h1>${PROJECT_KEY} Agent Dashboard</h1>
DASHBOARD_EOF

  # Inject dynamic data
  cat >> "${DASHBOARD_DIR}/index.html" << EOF
<div class="grid">
  <div class="card">
    <h2>Sprint Progress</h2>
    <div class="metric">${DONE_N}/${TOTAL_N}</div>
    <div class="metric-label">tickets completed (${PCT_N}%)</div>
    <div class="progress-bar"><div class="progress-fill green" style="width: ${PCT_N}%"></div></div>
  </div>
  <div class="card">
    <h2>Person-Days</h2>
    <div class="metric">${SPRINT_PD}</div>
    <div class="metric-label">estimated for sprint</div>
  </div>
  <div class="card">
    <h2>Velocity</h2>
    <div class="metric">${TEAM_VELOCITY}</div>
    <div class="metric-label">avg of last 3 sprints</div>
  </div>
  <div class="card">
    <h2>Budget</h2>
    <div class="metric-label" style="font-size: 1rem">${BUDGET_INFO}</div>
  </div>
</div>

<div class="grid">
  <div class="card">
    <h2>Agent Activity</h2>
    <table>${AGENT_STATUS}</table>
  </div>
  <div class="card">
    <h2>Stuck Tickets</h2>
    <table>${STUCK_ROWS}</table>
  </div>
  <div class="card">
    <h2>Sprint Breakdown</h2>
    <table>
      <tr><td>Done</td><td>${DONE_N}</td></tr>
      <tr><td>In Progress</td><td>${INPROG_N}</td></tr>
      <tr><td>To Do</td><td>${TODO_N}</td></tr>
    </table>
  </div>
</div>

<div class="timestamp">Last updated: $(date -u '+%Y-%m-%d %H:%M UTC')</div>
</body>
</html>
EOF

  touch "$DASHBOARD_FLAG"
  log_info "Dashboard generated at ${DASHBOARD_DIR}/index.html"
fi

log_activity "omar" "OPS" "HEALTH" "Checks complete"
release_lock
log_success "=== Omar (Ops) health checks complete ==="
