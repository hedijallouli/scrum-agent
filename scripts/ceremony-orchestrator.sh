#!/usr/bin/env bash
# =============================================================================
# ceremony-orchestrator.sh — Chain ceremonies in sequence
#
# Ported from SI's n8n Ceremony Orchestrator (workflow #9).
# Instead of n8n's Wait nodes + webhook callbacks, we use simple bash
# sequential execution with state tracking.
#
# Chains:
#   1. Sprint Review  → wait for completion →
#   2. Sprint Retro   → wait for completion →
#   3. Post summary to Slack/Mattermost
#
# State tracked in: /tmp/bisb-ceremony-state.json
#
# Usage:
#   ceremony-orchestrator.sh              # Run Review then Retro
#   ceremony-orchestrator.sh review-only  # Just Review
#   ceremony-orchestrator.sh retro-only   # Just Retro
#
# Triggered: Friday 15:00 UTC via cron, or manually
# Lock: prevents duplicate ceremony runs within 2 hours
# =============================================================================
set -euo pipefail

export PATH="$HOME/.local/bin:/usr/local/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENT_NAME="omar"
source "${SCRIPT_DIR}/agent-common.sh"
load_env
source "${SCRIPT_DIR}/ceremony-common.sh"

LOG_FILE="/var/log/bisb/ceremony-orchestrator-$(date '+%Y-%m-%dT%H:%M:%S').log"
mkdir -p /var/log/bisb
log_info "=== Ceremony Orchestrator Starting ==="

MODE="${1:-full}"  # full, review-only, retro-only

# ─── Lock: prevent duplicate ceremony runs ────────────────────────────────────
ORCH_LOCK="/tmp/bisb-ceremony-orchestrator.lock"
ORCH_LOCK_MAX_AGE=7200  # 2 hours

if [[ -f "$ORCH_LOCK" ]]; then
  lock_age=$(( $(date +%s) - $(stat -c %Y "$ORCH_LOCK" 2>/dev/null || echo 0) ))
  if (( lock_age < ORCH_LOCK_MAX_AGE )); then
    log_info "Ceremony orchestrator already running (lock age=${lock_age}s) — skipping"
    exit 0
  else
    log_info "Removing stale orchestrator lock (age=${lock_age}s)"
    rm -f "$ORCH_LOCK"
  fi
fi
touch "$ORCH_LOCK"
trap 'rm -f "$ORCH_LOCK"; ceremony_resume_agents' EXIT

# ─── State file ───────────────────────────────────────────────────────────────
STATE_FILE="/tmp/bisb-ceremony-state.json"

update_state() {
  local phase="$1" status="$2"
  python3 -c "
import json, sys
phase = sys.argv[1]
status = sys.argv[2]
try:
    with open('${STATE_FILE}') as f:
        state = json.load(f)
except:
    state = {}
state['phase'] = phase
state['status'] = status
state['updated_at'] = '$(date -u +%Y-%m-%dT%H:%M:%SZ)'
with open('${STATE_FILE}', 'w') as f:
    json.dump(state, f, indent=2)
" "$phase" "$status" 2>/dev/null || true
}

# ─── Pause agents during all ceremonies ───────────────────────────────────────
ceremony_pause_agents

# ─── Notify team: ceremony block starting ─────────────────────────────────────
NOTIFY_MSG=":calendar: **Bloc Cérémonie** — Sprint Review"
if [[ "$MODE" == "full" ]]; then
  NOTIFY_MSG="${NOTIFY_MSG} puis Retrospective"
fi
NOTIFY_MSG="${NOTIFY_MSG}. Les agents sont en pause pendant les cérémonies."

ceremony_post "omar" "$NOTIFY_MSG" "standup" "" >/dev/null 2>&1 || true

# ═══════════════════════════════════════════════════════════════════════════════
# Phase 1: Sprint Review
# ═══════════════════════════════════════════════════════════════════════════════
if [[ "$MODE" == "full" || "$MODE" == "review-only" ]]; then
  log_info "=== Phase 1: Sprint Review ==="
  update_state "review" "running"

  REVIEW_EXIT=0
  "${SCRIPT_DIR}/ceremony-review.sh" >> "$LOG_FILE" 2>&1 || REVIEW_EXIT=$?

  if [[ "$REVIEW_EXIT" -eq 0 ]]; then
    update_state "review" "complete"
    log_success "Sprint Review completed successfully"
  else
    update_state "review" "failed"
    log_error "Sprint Review failed (exit ${REVIEW_EXIT})"
    ceremony_post "omar" ":warning: Sprint Review a échoué (exit ${REVIEW_EXIT}). Passage à la Retrospective quand même." "standup" "" >/dev/null 2>&1 || true
  fi

  # Breathing room between ceremonies
  if [[ "$MODE" == "full" ]]; then
    log_info "Waiting 60s between Review and Retro..."
    sleep 60
  fi
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Phase 2: Sprint Retrospective
# ═══════════════════════════════════════════════════════════════════════════════
if [[ "$MODE" == "full" || "$MODE" == "retro-only" ]]; then
  log_info "=== Phase 2: Sprint Retrospective ==="
  update_state "retro" "running"

  # Notify transition
  if [[ "$MODE" == "full" ]]; then
    ceremony_post "omar" ":arrows_counterclockwise: Review terminée ! On enchaîne avec la **Retrospective**." "standup" "" >/dev/null 2>&1 || true
  fi

  RETRO_EXIT=0
  "${SCRIPT_DIR}/ceremony-retro.sh" >> "$LOG_FILE" 2>&1 || RETRO_EXIT=$?

  if [[ "$RETRO_EXIT" -eq 0 ]]; then
    update_state "retro" "complete"
    log_success "Sprint Retrospective completed successfully"
  else
    update_state "retro" "failed"
    log_error "Sprint Retrospective failed (exit ${RETRO_EXIT})"
  fi
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Phase 3: Summary + Cleanup
# ═══════════════════════════════════════════════════════════════════════════════
update_state "complete" "done"

# Build final summary
REVIEW_STATUS="N/A"
RETRO_STATUS="N/A"
[[ "$MODE" == "full" || "$MODE" == "review-only" ]] && REVIEW_STATUS=$([[ "${REVIEW_EXIT:-0}" -eq 0 ]] && echo ":white_check_mark:" || echo ":x:")
[[ "$MODE" == "full" || "$MODE" == "retro-only" ]] && RETRO_STATUS=$([[ "${RETRO_EXIT:-0}" -eq 0 ]] && echo ":white_check_mark:" || echo ":x:")

SUMMARY_MSG=":checkered_flag: **Bloc Cérémonie terminé !**

| Cérémonie | Status |
|-----------|--------|
| Sprint Review | ${REVIEW_STATUS} |
| Retrospective | ${RETRO_STATUS} |

Les agents reprennent leur activité normale."

ceremony_post "omar" "$SUMMARY_MSG" "standup" "" >/dev/null 2>&1 || true

log_activity "omar" "CEREMONY_ORCHESTRATOR" "COMPLETE" "Mode=${MODE}, review=${REVIEW_EXIT:-N/A}, retro=${RETRO_EXIT:-N/A}"
log_success "=== Ceremony Orchestrator complete ==="
