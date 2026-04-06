#!/bin/bash
set -euo pipefail

# ─── Clean agent runner ─────────────────────────────────────────────────────
# Usage: run-agent.sh TICKET_KEY AGENT_NAME
# Runs one agent for one ticket with proper locking and timeout.
#
# Integrates: circuit breakers, dependency health, error classification,
# exponential backoff, per-agent budgets, structured logging, poison pill,
# event sourcing, idempotency, graceful degradation.
MAX_RETRIES=3

TICKET_KEY="${1:?Usage: run-agent.sh TICKET_KEY AGENT_NAME}"
AGENT="${2:?Usage: run-agent.sh TICKET_KEY AGENT_NAME}"
AGENT_NAME="${AGENT}"
export TICKET_KEY  # for log_json context

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/agent-common.sh"

# Generate unique run ID for tracing
export RUN_ID="$(date +%s)-$$-${AGENT}-${TICKET_KEY}"

# ─── Pre-flight: circuit breaker check ──────────────────────────────────────
if cb_is_open "$AGENT"; then
  log_info "Circuit breaker OPEN for ${AGENT} — skipping ${TICKET_KEY}"
  log_json "WARN" "circuit_breaker_skip" "\"agent\":\"${AGENT}\",\"ticket\":\"${TICKET_KEY}\""
  exit 0
fi

# ─── Pre-flight: dependency health check ────────────────────────────────────
if dep_check_or_skip "plane" "$AGENT"; then
  log_json "WARN" "dep_down_skip" "\"dep\":\"plane\",\"agent\":\"${AGENT}\""
  exit 0
fi
if dep_check_or_skip "claude" "$AGENT"; then
  log_json "WARN" "dep_down_skip" "\"dep\":\"claude\",\"agent\":\"${AGENT}\""
  exit 0
fi

# ─── Pre-flight: backoff check ──────────────────────────────────────────────
if ! can_retry_now "$TICKET_KEY" "$AGENT"; then
  log_info "Backoff active for ${TICKET_KEY}/${AGENT} — skipping"
  log_json "INFO" "backoff_skip" "\"ticket\":\"${TICKET_KEY}\",\"agent\":\"${AGENT}\""
  exit 0
fi

# ─── Pre-flight: per-agent budget check ─────────────────────────────────────
if is_agent_over_budget "$AGENT" 2>/dev/null; then
  log_info "Agent ${AGENT} over daily budget share — skipping ${TICKET_KEY}"
  log_json "WARN" "budget_throttle" "\"agent\":\"${AGENT}\",\"ticket\":\"${TICKET_KEY}\""
  exit 0
fi

# ─── Pre-flight: degradation level check ──────────────────────────────────
if ! dispatch_allowed "$AGENT" 2>/dev/null; then
  log_info "Agent ${AGENT} blocked by degradation level $(degrade_get 2>/dev/null) — skipping ${TICKET_KEY}"
  log_json "WARN" "degrade_skip" "\"agent\":\"${AGENT}\",\"ticket\":\"${TICKET_KEY}\",\"level\":$(degrade_get 2>/dev/null || echo 0)"
  event_log "$TICKET_KEY" "$AGENT" "degrade_skip" "{\"level\":$(degrade_get 2>/dev/null || echo 0)}" 2>/dev/null || true
  exit 0
fi

# ─── Per-ticket locks for parallel agents ─────────────────────────────────
if [[ "$AGENT" == "nadia" ]]; then
  LOCK_FILE="/tmp/${PROJECT_PREFIX}-agent-nadia-${TICKET_KEY}.lock"
fi
if [[ "$AGENT" == "youssef" ]]; then
  LOCK_FILE="/tmp/${PROJECT_PREFIX}-agent-youssef-${TICKET_KEY}.lock"
fi
if [[ "$AGENT" == "rami" ]]; then
  LOCK_FILE="/tmp/${PROJECT_PREFIX}-agent-rami-${TICKET_KEY}.lock"
fi

# ─── Acquire lock ───────────────────────────────────────────────────────────
if ! acquire_lock; then
  log_info "Agent ${AGENT} already running (lock held), skipping"
  exit 0
fi
# Kill heartbeat before releasing lock — prevents race where heartbeat recreates lock after release
trap 'kill "${_HEARTBEAT_PID:-}" 2>/dev/null; release_lock' EXIT

# ─── Ensure clean base branch before agent starts ──────────────────────────
cd "$PROJECT_DIR"
git checkout "${BASE_BRANCH}" -q 2>/dev/null || true

# ─── Per-ticket brief: load cross-run memory ────────────────────────────────
BRIEF_DIR="/tmp/${PROJECT_PREFIX}-notes"
mkdir -p "$BRIEF_DIR"
TICKET_BRIEF_FILE="${BRIEF_DIR}/${TICKET_KEY}.md"
if [[ -f "$TICKET_BRIEF_FILE" ]]; then
  export TICKET_BRIEF_CONTEXT
  TICKET_BRIEF_CONTEXT="$(tail -40 "$TICKET_BRIEF_FILE" 2>/dev/null)"
  log_info "Brief loaded for ${TICKET_KEY} ($(wc -l < "$TICKET_BRIEF_FILE" 2>/dev/null || echo 0) lines)"
else
  export TICKET_BRIEF_CONTEXT=""
fi

# ─── Run agent with timeout ────────────────────────────────────────────────
START_TIME=$(date +%s)
log_info "Starting ${AGENT} for ${TICKET_KEY} (run_id=${RUN_ID})"
log_json "INFO" "agent_start" "\"ticket\":\"${TICKET_KEY}\",\"agent\":\"${AGENT}\""
event_log "$TICKET_KEY" "$AGENT" "agent_start" "{\"run_id\":\"${RUN_ID}\"}" 2>/dev/null || true

EXIT_CODE=0
STDERR_FILE=$(mktemp /tmp/${PROJECT_PREFIX}-stderr-XXXXXX.txt)
timeout 1800 "${SCRIPT_DIR}/agent-${AGENT}.sh" "$TICKET_KEY" 2>"$STDERR_FILE" || EXIT_CODE=$?

DURATION=$(( $(date +%s) - START_TIME ))
STDERR_TEXT=$(tail -20 "$STDERR_FILE" 2>/dev/null || true)
rm -f "$STDERR_FILE"

# ─── Classify error type ───────────────────────────────────────────────────
ERROR_TYPE="none"
if [[ "$EXIT_CODE" -ne 0 ]]; then
  ERROR_TYPE=$(classify_error "$EXIT_CODE" "$STDERR_TEXT")
fi

# ─── Log metrics ──────────────────────────────────────────────────────────
log_metric "$AGENT" "$TICKET_KEY" "$EXIT_CODE" "$DURATION" "sonnet" "$ERROR_TYPE"

# ─── Append outcome to brief ──────────────────────────────────────────────
echo "$(date -u '+%H:%M UTC')│${AGENT}│EXIT_${EXIT_CODE}│duration=${DURATION}s│error=${ERROR_TYPE}" >> "$TICKET_BRIEF_FILE" 2>/dev/null || true

# ─── Track agent cost ─────────────────────────────────────────────────────
record_agent_cost "$AGENT" "sonnet" "$DURATION"
# Track API key spend if it was used (ANTHROPIC_API_KEY set = paid mode)
if [[ -n "${ANTHROPIC_API_KEY:-}" ]] && [[ "$EXIT_CODE" -eq 0 ]]; then
  record_api_key_spend "sonnet" "$DURATION"
  event_log "$TICKET_KEY" "$AGENT" "api_key_charged" "{\"duration\":${DURATION}}" 2>/dev/null || true
fi

if [[ "$EXIT_CODE" -eq 0 ]]; then
  # ─── SUCCESS ──────────────────────────────────────────────────────────
  log_success "${TICKET_KEY} completed by ${AGENT} in ${DURATION}s"
  log_json "INFO" "agent_success" "\"ticket\":\"${TICKET_KEY}\",\"duration\":${DURATION}"
  event_log "$TICKET_KEY" "$AGENT" "agent_success" "{\"duration\":${DURATION}}" 2>/dev/null || true
  cb_reset "$AGENT"  # Reset circuit breaker on success

elif [[ "$EXIT_CODE" -eq 124 ]]; then
  # ─── TIMEOUT ──────────────────────────────────────────────────────────
  log_error "${TICKET_KEY} TIMEOUT after ${DURATION}s (${AGENT})"
  log_json "ERROR" "agent_timeout" "\"ticket\":\"${TICKET_KEY}\",\"duration\":${DURATION}"
  event_log "$TICKET_KEY" "$AGENT" "agent_timeout" "{\"duration\":${DURATION}}" 2>/dev/null || true

  cb_record_failure "$AGENT"
  increment_retry "$TICKET_KEY" "$AGENT"
  record_failure_with_backoff "$TICKET_KEY" "$AGENT" "TIMEOUT"

  retry_count=$(get_retry_count "$TICKET_KEY" "$AGENT")
  log_info "Retry count after timeout: ${retry_count}/${MAX_RETRIES} for ${TICKET_KEY}"

  if (( retry_count >= MAX_RETRIES )); then
    log_info "Max retries after timeout — handing off ${TICKET_KEY} to Omar"
    source "${SCRIPT_DIR}/tracker-common.sh" 2>/dev/null || true
    plane_set_assignee "$TICKET_KEY" "omar" 2>/dev/null && \
      log_info "Assigned ${TICKET_KEY} to Omar" || \
      log_error "Could not assign ${TICKET_KEY} to Omar"
    jira_add_label "$TICKET_KEY" "blocked" 2>/dev/null || true
    blacklist_ticket "$TICKET_KEY" "Max retries (${MAX_RETRIES}) by ${AGENT} — timeout"
    record_blacklist_event "$TICKET_KEY"  # Poison pill check
    event_log "$TICKET_KEY" "$AGENT" "escalate_omar" "{\"reason\":\"timeout_max_retries\",\"retries\":${MAX_RETRIES}}" 2>/dev/null || true
    slack_notify "$AGENT" "$(mm_ticket_link "${TICKET_KEY}") — timeout ${MAX_RETRIES} fois (1800s). Ticket transféré à @omar-ai pour triage. Blacklisté 1h. ⏱️🔴" "pipeline" "warning" 2>/dev/null || true
    log_activity "$AGENT" "$TICKET_KEY" "TIMEOUT_HANDOFF_OMAR" "Timed out ${MAX_RETRIES} times — handed to Omar + blacklisted"
  fi

else
  # ─── FAILURE ──────────────────────────────────────────────────────────
  log_error "${TICKET_KEY} FAILED by ${AGENT} in ${DURATION}s (exit ${EXIT_CODE}, type=${ERROR_TYPE})"
  log_json "ERROR" "agent_failure" "\"ticket\":\"${TICKET_KEY}\",\"exit_code\":${EXIT_CODE},\"error_type\":\"${ERROR_TYPE}\",\"duration\":${DURATION}"
  event_log "$TICKET_KEY" "$AGENT" "agent_failure" "{\"exit_code\":${EXIT_CODE},\"error_type\":\"${ERROR_TYPE}\",\"duration\":${DURATION}}" 2>/dev/null || true

  cb_record_failure "$AGENT"
  record_failure_with_backoff "$TICKET_KEY" "$AGENT" "$ERROR_TYPE"

  # Set dependency flags on specific error types
  if [[ "$ERROR_TYPE" == "RATE_LIMIT" ]]; then
    set_sonnet_rate_limited
    dep_set_down "claude"
  fi

  # Permanent errors: escalate immediately
  if [[ "$ERROR_TYPE" == "PERMANENT" ]]; then
    log_info "PERMANENT error — escalating ${TICKET_KEY} immediately"
    source "${SCRIPT_DIR}/tracker-common.sh" 2>/dev/null || true
    jira_add_rich_comment "$TICKET_KEY" "$AGENT" "ERROR" \
      "Erreur permanente (exit ${EXIT_CODE}): $(echo "$STDERR_TEXT" | head -3). Escaladé à Omar." 2>/dev/null || true
    plane_set_assignee "$TICKET_KEY" "omar" 2>/dev/null || true
    blacklist_ticket "$TICKET_KEY" "Permanent error by ${AGENT}: ${ERROR_TYPE}"
    record_blacklist_event "$TICKET_KEY"
    event_log "$TICKET_KEY" "$AGENT" "escalate_omar" "{\"reason\":\"permanent_error\",\"exit_code\":${EXIT_CODE}}" 2>/dev/null || true
  fi
fi

exit "$EXIT_CODE"
