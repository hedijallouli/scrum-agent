#!/usr/bin/env bash
# =============================================================================
# watchdog.sh — Self-healing hourly watchdog for the BISB agent pipeline
#
# Checks:
#   1. Git repo health (clean base branch, no corruption)
#   2. Disk space (warn at 80%, critical at 90%)
#   3. Stale lock files (> 30 min)
#   4. Stale circuit breakers (expired but not cleaned)
#   5. Orphan processes (agent scripts still running after timeout)
#   6. Cron is running (agent-cron.sh ran in last 20 min)
#   7. Memory pressure (< 200 MB available)
#
# Self-heals:
#   - Removes stale locks
#   - Cleans expired circuit breakers / backoff / blacklist
#   - Kills orphan agent processes
#   - Alerts via Slack/Mattermost on critical issues
#
# Triggered: hourly via cron
# Log: /var/log/bisb/watchdog.log
# =============================================================================
set -euo pipefail

export PATH="$HOME/.local/bin:/usr/local/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENT_NAME="omar"
source "${SCRIPT_DIR}/agent-common.sh"
load_env

LOG_FILE="/var/log/bisb/watchdog.log"
mkdir -p /var/log/bisb

ALERTS=0
HEALED=0

alert() {
  local severity="$1" msg="$2"
  (( ALERTS++ )) || true
  log_info "[WATCHDOG][${severity}] ${msg}"
}

heal() {
  local msg="$1"
  (( HEALED++ )) || true
  log_info "[WATCHDOG][HEALED] ${msg}"
}

log_info "=== Watchdog starting ==="
NOW=$(date +%s)

# ─── 1. Git repo health ──────────────────────────────────────────────────────
log_info "Check 1: Git repo..."
cd "$PROJECT_DIR"

# Ensure we're on base branch
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "UNKNOWN")
if [[ "$CURRENT_BRANCH" != "${BASE_BRANCH}" ]]; then
  alert "WARN" "Git on branch '${CURRENT_BRANCH}' instead of '${BASE_BRANCH}'"
  git checkout "${BASE_BRANCH}" -q 2>/dev/null && heal "Switched back to ${BASE_BRANCH}" || true
fi

# Check for uncommitted changes
DIRTY=$(git status --porcelain 2>/dev/null | head -5 || true)
if [[ -n "$DIRTY" ]]; then
  alert "WARN" "Git working tree dirty: $(echo "$DIRTY" | wc -l) files"
fi

# Quick fsck
FSCK_EXIT=0
git fsck --no-full --quiet 2>/dev/null || FSCK_EXIT=$?
if [[ "$FSCK_EXIT" -ne 0 ]]; then
  alert "CRITICAL" "Git fsck failed (exit ${FSCK_EXIT})"
fi

# ─── 2. Disk space ──────────────────────────────────────────────────────────
log_info "Check 2: Disk space..."
DISK_PCT=$(df / --output=pcent 2>/dev/null | tail -1 | tr -d '% ' || echo "0")
if (( DISK_PCT >= 90 )); then
  alert "CRITICAL" "Disk usage at ${DISK_PCT}%"
  # Auto-clean old logs
  find /var/log/bisb/ -name "*.log" -mtime +7 -delete 2>/dev/null && heal "Cleaned old logs" || true
  clean_cache 2>/dev/null && heal "Cleaned response cache" || true
elif (( DISK_PCT >= 80 )); then
  alert "WARN" "Disk usage at ${DISK_PCT}%"
fi

# ─── 3. Stale lock files ────────────────────────────────────────────────────
log_info "Check 3: Stale locks..."
LOCK_MAX=1800  # 30 min

for lockfile in /tmp/bisb-agent-*.lock; do
  [[ -f "$lockfile" ]] || continue
  lock_age=$(( NOW - $(stat -c %Y "$lockfile" 2>/dev/null || echo 0) ))
  if (( lock_age > LOCK_MAX )); then
    lock_name=$(basename "$lockfile")
    alert "WARN" "Stale lock: ${lock_name} (age=${lock_age}s)"
    rm -f "$lockfile"
    heal "Removed stale lock: ${lock_name}"
  fi
done

# DM poller lock
DM_LOCK="/tmp/bisb-dm-poller.lock"
if [[ -f "$DM_LOCK" ]]; then
  dm_age=$(( NOW - $(stat -c %Y "$DM_LOCK" 2>/dev/null || echo 0) ))
  if (( dm_age > 600 )); then
    alert "WARN" "Stale DM poller lock (age=${dm_age}s)"
    rm -f "$DM_LOCK"
    heal "Removed stale DM poller lock"
  fi
fi

# ─── 4. Circuit breaker / backoff / blacklist cleanup ────────────────────────
log_info "Check 4: Cleanup expired state..."
clean_blacklist 2>/dev/null && heal "Cleaned blacklist" || true
clean_backoff 2>/dev/null && heal "Cleaned backoff" || true

# Clean expired circuit breakers
for cb_file in "${CB_DIR:-/tmp/bisb-circuit-breakers}"/*.state; do
  [[ -f "$cb_file" ]] || continue
  local_count=0 local_ts=0 local_until=0
  IFS='|' read -r local_count local_ts local_until < "$cb_file" 2>/dev/null || continue
  if (( local_until > 0 && NOW > local_until )); then
    echo "0|0|0" > "$cb_file"
    heal "Reset expired circuit breaker: $(basename "$cb_file" .state)"
  fi
done

# Clean poison pill file (entries older than 48h)
POISON_FILE="/tmp/bisb-poison-pills"
if [[ -f "$POISON_FILE" ]]; then
  tmp=$(mktemp)
  while IFS='|' read -r t ts; do
    [[ -z "$t" ]] && continue
    (( NOW - ts < 172800 )) && echo "${t}|${ts}"
  done < "$POISON_FILE" > "$tmp"
  mv "$tmp" "$POISON_FILE"
fi

# ─── 5. Orphan processes ────────────────────────────────────────────────────
log_info "Check 5: Orphan agent processes..."
for agent in salma youssef nadia rami layla omar; do
  PIDS=$(pgrep -f "agent-${agent}.sh" 2>/dev/null || true)
  if [[ -n "$PIDS" ]]; then
    for pid in $PIDS; do
      pid_age=$(( NOW - $(stat -c %Y "/proc/${pid}" 2>/dev/null || echo "$NOW") ))
      if (( pid_age > 2400 )); then  # 40 min (longer than 30 min timeout)
        alert "WARN" "Orphan process: agent-${agent}.sh (PID=${pid}, age=${pid_age}s)"
        kill "$pid" 2>/dev/null && heal "Killed orphan: agent-${agent}.sh PID=${pid}" || true
      fi
    done
  fi
done

# ─── 6. Cron health ─────────────────────────────────────────────────────────
log_info "Check 6: Cron health..."
CRON_LOG="/var/log/bisb/cron.log"
if [[ -f "$CRON_LOG" ]]; then
  cron_age=$(( NOW - $(stat -c %Y "$CRON_LOG" 2>/dev/null || echo 0) ))
  if (( cron_age > 1200 )); then  # 20 min (should run every 15)
    # Only alert if agents are not paused
    if [[ ! -f "/tmp/bisb-agents-paused" ]]; then
      alert "WARN" "Cron not running? Last log update ${cron_age}s ago"
    fi
  fi
fi

# ─── 7. Memory pressure ─────────────────────────────────────────────────────
log_info "Check 7: Memory..."
AVAIL_MB=$(free -m 2>/dev/null | awk '/^Mem:/ {print $NF}' || echo "999")
if (( AVAIL_MB < 200 )); then
  alert "CRITICAL" "Low memory: ${AVAIL_MB}MB available"
  # Kill any lingering n8n (shouldn't be running)
  pkill -f "n8n start" 2>/dev/null && heal "Killed lingering n8n (freed memory)" || true
elif (( AVAIL_MB < 500 )); then
  alert "WARN" "Memory pressure: ${AVAIL_MB}MB available"
fi

# ─── 8. SLO Monitoring ─────────────────────────────────────────────────────
log_info "Check 8: Pipeline SLO..."
SLO_ALERT_COUNT=0
SLO_ALERT_COUNT=$(slo_check_all 2>/dev/null || echo "0")
if (( SLO_ALERT_COUNT > 0 )); then
  alert "WARN" "Pipeline SLO: ${SLO_ALERT_COUNT} alert(s)"
fi

# ─── 9. Auto-degradation check ────────────────────────────────────────────────
log_info "Check 9: Degradation level..."
DEGRADE_LEVEL=$(auto_degrade_check 2>/dev/null || echo "0")
if (( DEGRADE_LEVEL > 0 )); then
  alert "WARN" "Degradation level: $(degrade_status 2>/dev/null || echo "level=${DEGRADE_LEVEL}")"
fi

# ─── 10. Event log rotation ──────────────────────────────────────────────────
log_info "Check 10: Event log rotation..."
event_log_rotate 2>/dev/null && heal "Rotated event log" || true

# ─── 11. Idempotency cleanup ─────────────────────────────────────────────────
log_info "Check 11: Idempotency cleanup..."
clean_idempotency 2>/dev/null && heal "Cleaned stale idempotency claims" || true

# ─── Results ─────────────────────────────────────────────────────────────────
if (( ALERTS > 0 )); then
  log_info "Watchdog: ${ALERTS} alert(s), ${HEALED} auto-healed"
  log_json "WARN" "watchdog_alerts" "\"alerts\":${ALERTS},\"healed\":${HEALED}"

  # Notify on critical issues only (avoid spam)
  CRITICAL_COUNT=$(grep -c "\[CRITICAL\]" "$LOG_FILE" 2>/dev/null || echo 0)
  if (( CRITICAL_COUNT > 0 )); then
    slack_notify "omar" "🩺 Watchdog: ${ALERTS} alerte(s), ${HEALED} auto-corrigées. ${CRITICAL_COUNT} CRITICAL." "pipeline" "warning" 2>/dev/null || true
  fi
else
  log_info "Watchdog: all checks passed"
  log_json "INFO" "watchdog_ok" "\"alerts\":0,\"healed\":${HEALED}"
fi

log_info "=== Watchdog complete ==="
