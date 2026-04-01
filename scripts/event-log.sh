#!/usr/bin/env bash
# =============================================================================
# event-log.sh — Lightweight Event Sourcing for the BISB agent pipeline
#
# Records every meaningful action as an immutable event in append-only JSONL.
# Enables "what happened to BISB-47 between 3pm and 5pm?" queries.
#
# Usage (source in agent-common.sh or call directly):
#   source event-log.sh
#   event_log "BISB-47" "youssef" "branch_created" '{"branch":"feat/BISB-47-ai"}'
#   event_log "BISB-47" "nadia"   "qa_verdict"     '{"verdict":"PASS","confidence":85}'
#
# Query:
#   ticket_history "BISB-47"
#   ticket_history "BISB-47" "2026-03-12T15:00" "2026-03-12T17:00"
#   run_timeline "1710250800-12345-youssef-BISB-47"
#   agent_events "youssef" 50
# =============================================================================

EVENT_LOG_DIR="/var/lib/${PROJECT_PREFIX}/events"
EVENT_LOG_FILE="${EVENT_LOG_DIR}/events.jsonl"
mkdir -p "$EVENT_LOG_DIR"

# ─── Core: append one immutable event ─────────────────────────────────────────
# Args: TICKET AGENT ACTION [PAYLOAD_JSON]
event_log() {
  local ticket="${1:-unknown}" agent="${2:-unknown}" action="${3:-unknown}"
  local payload="${4:-\{\}}"
  local ts
  ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  local epoch
  epoch=$(date +%s)
  local run_id="${RUN_ID:-none}"

  # Validate payload is valid JSON (fallback to empty object)
  if ! echo "$payload" | python3 -c "import sys,json; json.load(sys.stdin)" 2>/dev/null; then
    payload="{\"raw\":\"$(echo "$payload" | tr '"' "'" | head -c 200)\"}"
  fi

  # Append atomically (single echo → single write syscall for small lines)
  printf '{"ts":"%s","epoch":%d,"ticket":"%s","agent":"%s","action":"%s","run_id":"%s","data":%s}\n' \
    "$ts" "$epoch" "$ticket" "$agent" "$action" "$run_id" "$payload" \
    >> "$EVENT_LOG_FILE" 2>/dev/null || true
}

# ─── Query: full history of a ticket ──────────────────────────────────────────
# Args: TICKET [FROM_ISO] [TO_ISO]
ticket_history() {
  local ticket="$1"
  local from="${2:-}" to="${3:-}"

  if [[ -z "$from" && -z "$to" ]]; then
    # All events for this ticket
    grep "\"ticket\":\"${ticket}\"" "$EVENT_LOG_FILE" 2>/dev/null || true
  else
    # Time-bounded query
    python3 -c "
import sys, json
from datetime import datetime
ticket = sys.argv[1]
fr = sys.argv[2] if len(sys.argv) > 2 and sys.argv[2] else '1970-01-01T00:00:00Z'
to = sys.argv[3] if len(sys.argv) > 3 and sys.argv[3] else '2099-12-31T23:59:59Z'
# Normalize: add Z if missing
if not fr.endswith('Z'): fr += 'Z'
if not to.endswith('Z'): to += 'Z'
for line in sys.stdin:
    line = line.strip()
    if not line: continue
    try:
        e = json.loads(line)
        if e.get('ticket') != ticket: continue
        if fr <= e['ts'] <= to:
            print(line)
    except: pass
" "$ticket" "$from" "$to" < "$EVENT_LOG_FILE" 2>/dev/null || true
  fi
}

# ─── Query: all events for a specific run ─────────────────────────────────────
# Args: RUN_ID
run_timeline() {
  local rid="$1"
  grep "\"run_id\":\"${rid}\"" "$EVENT_LOG_FILE" 2>/dev/null || true
}

# ─── Query: recent events for an agent ────────────────────────────────────────
# Args: AGENT [LIMIT]
agent_events() {
  local agent="$1" limit="${2:-20}"
  grep "\"agent\":\"${agent}\"" "$EVENT_LOG_FILE" 2>/dev/null | tail -"$limit"
}

# ─── Query: recent events of a specific action type ──────────────────────────
# Args: ACTION [LIMIT]
action_events() {
  local action="$1" limit="${2:-20}"
  grep "\"action\":\"${action}\"" "$EVENT_LOG_FILE" 2>/dev/null | tail -"$limit"
}

# ─── Housekeeping: rotate old events (keep last 7 days) ──────────────────────
event_log_rotate() {
  local cutoff
  cutoff=$(date -u -d '7 days ago' '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u '+%Y-%m-%dT%H:%M:%SZ')
  local tmp
  tmp=$(mktemp)
  python3 -c "
import sys
cutoff = sys.argv[1]
for line in sys.stdin:
    line = line.strip()
    if not line: continue
    # Quick check: ts is always first field
    try:
        ts_start = line.index('\"ts\":\"') + 6
        ts_end = line.index('\"', ts_start)
        ts = line[ts_start:ts_end]
        if ts >= cutoff:
            print(line)
    except:
        print(line)  # keep unparseable lines
" "$cutoff" < "$EVENT_LOG_FILE" > "$tmp" 2>/dev/null
  mv "$tmp" "$EVENT_LOG_FILE" 2>/dev/null || true
}

# ─── Summary: count events by action type in last N hours ─────────────────────
event_summary() {
  local hours="${1:-24}"
  local cutoff
  cutoff=$(date -u -d "${hours} hours ago" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u '+%Y-%m-%dT%H:%M:%SZ')
  python3 -c "
import sys, json
from collections import Counter
cutoff = sys.argv[1]
counts = Counter()
for line in sys.stdin:
    line = line.strip()
    if not line: continue
    try:
        e = json.loads(line)
        if e['ts'] >= cutoff:
            counts[e.get('action','unknown')] += 1
    except: pass
for action, count in counts.most_common():
    print(f'{count:>4}  {action}')
" "$cutoff" < "$EVENT_LOG_FILE" 2>/dev/null || true
}
