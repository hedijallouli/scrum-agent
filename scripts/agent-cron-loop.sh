#!/bin/bash
# =============================================================================
# agent-cron-loop.sh — Forced dispatch loop (used by Omar via DM)
#
# Runs agent-cron.sh --force every 5 minutes until:
#   - Stop flag exists: /tmp/${PROJECT_PREFIX}-omar-loop.stop
#   - Or max cycles reached (optional $1 arg, default=unlimited)
#   - Or killed externally
#
# Usage: agent-cron-loop.sh [max_cycles]
# PID stored in: /tmp/${PROJECT_PREFIX}-omar-loop.pid
# Stop flag:     /tmp/${PROJECT_PREFIX}-omar-loop.stop
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAX_CYCLES="${1:-48}"  # Default 48 cycles = 12 hours, then auto-expire
STOP_FLAG="/tmp/${PROJECT_PREFIX}-omar-loop.stop"
PID_FILE="/tmp/${PROJECT_PREFIX}-omar-loop.pid"
LOOP_LOG="${LOG_DIR}/omar-force-loop-$(date +%Y-%m-%d).log"
INTERVAL=900  # 15 minutes (matches cron interval — avoids double-dispatch)

mkdir -p ${LOG_DIR}

# Cleanup previous state
rm -f "$STOP_FLAG"
echo $$ > "$PID_FILE"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOOP_LOG"; }

log "=== Omar force-loop started (PID=$$, max_cycles=${MAX_CYCLES:-unlimited}, interval=${INTERVAL}s) ==="

cycle=0
while true; do
  # Check stop flag
  if [[ -f "$STOP_FLAG" ]]; then
    log "Stop flag detected — loop terminated after ${cycle} cycle(s)"
    rm -f "$STOP_FLAG" "$PID_FILE"
    exit 0
  fi

  # Check max cycles
  if (( MAX_CYCLES > 0 && cycle >= MAX_CYCLES )); then
    log "Max cycles (${MAX_CYCLES}) reached — loop complete"
    rm -f "$PID_FILE"
    exit 0
  fi

  cycle=$(( cycle + 1 ))
  log "--- Cycle ${cycle}${MAX_CYCLES:+ of ${MAX_CYCLES}} ---"

  # Run one forced dispatch cycle (blocks until complete)
  "${SCRIPT_DIR}/agent-cron.sh" --force >> "$LOOP_LOG" 2>&1 || \
    log "Dispatch cycle exited non-zero (continuing loop)"

  log "Cycle ${cycle} done. Next in ${INTERVAL}s. Stop with: touch ${STOP_FLAG}"

  # Sleep in 10s chunks so stop flag and pause flag are checked frequently
  for (( i=0; i<INTERVAL; i+=10 )); do
    sleep 10
    [[ -f "$STOP_FLAG" ]] && break
    # Respect pause flag — don't burn CPU when agents are paused
    if [[ -f "/tmp/${PROJECT_PREFIX}-agents-paused" ]]; then
      log "Agents paused — sleeping 60s before next check"
      sleep 60
      continue
    fi
  done
done
