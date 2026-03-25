#!/usr/bin/env bash
# =============================================================================
# pipeline-slo.sh — SLO Monitoring & Synthetic Canary for BISB agent pipeline
#
# Detects early warning signs BEFORE they become outages:
#   1. Retry storm: >10 retries in 15 min across all agents
#   2. Circuit breaker flapping: >3 open/close cycles in 1h
#   3. Queue age: tickets stuck in same state >6 hours
#   4. Success rate: <50% success in last 20 runs
#   5. Synthetic canary: test Claude API reachability
#
# Triggered: by watchdog.sh (hourly) or standalone
# Alerts: Slack/Mattermost on SLO breach
#
# Usage:
#   source pipeline-slo.sh
#   slo_check_all   # runs all checks, returns combined alert count
# =============================================================================

SLO_HISTORY="/var/lib/bisb/data/slo-history.jsonl"
mkdir -p "$(dirname "$SLO_HISTORY")" 2>/dev/null || true

SLO_ALERTS=0

slo_alert() {
  local check="$1" severity="$2" msg="$3"
  (( SLO_ALERTS++ )) || true

  local ts
  ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  printf '{"ts":"%s","check":"%s","severity":"%s","msg":"%s"}\n' \
    "$ts" "$check" "$severity" "$msg" \
    >> "$SLO_HISTORY" 2>/dev/null || true

  log_info "[SLO][${severity}] ${check}: ${msg}" 2>/dev/null || \
    echo "[SLO][${severity}] ${check}: ${msg}" >&2
}

# ─── 1. Retry Storm Detection ────────────────────────────────────────────────
# Checks if retry rate is abnormally high (>10 retries in 15 min)
retry_storm_check() {
  local backoff_dir="${BACKOFF_DIR:-/tmp/bisb-backoff}"
  [[ -d "$backoff_dir" ]] || return 0

  local now
  now=$(date +%s)
  local window=900  # 15 minutes
  local threshold=10
  local recent_retries=0

  for f in "$backoff_dir"/*.state; do
    [[ -f "$f" ]] || continue
    local file_age
    file_age=$(( now - $(stat -c %Y "$f" 2>/dev/null || echo 0) ))
    if (( file_age < window )); then
      local count
      count=$(cut -d'|' -f1 < "$f" 2>/dev/null || echo 0)
      recent_retries=$(( recent_retries + count ))
    fi
  done

  if (( recent_retries > threshold )); then
    slo_alert "retry_storm" "HIGH" "${recent_retries} retries in last 15min (threshold: ${threshold})"
    return 1
  fi
  return 0
}

# ─── 2. Circuit Breaker Flapping Detection ────────────────────────────────────
# Checks structured log for frequent open/close cycles
breaker_flap_check() {
  local structured_log="${STRUCTURED_LOG:-/var/log/bisb/structured.log}"
  [[ -f "$structured_log" ]] || return 0

  local now
  now=$(date +%s)
  local window=3600  # 1 hour
  local threshold=3

  # Count circuit breaker state changes in last hour
  local cb_events=0
  cb_events=$(python3 -c "
import sys, json
now = int(sys.argv[1])
window = int(sys.argv[2])
count = 0
for line in sys.stdin:
    line = line.strip()
    if not line: continue
    try:
        e = json.loads(line)
        ts = e.get('epoch', 0)
        if now - ts < window and 'circuit_breaker' in e.get('event', ''):
            count += 1
    except: pass
print(count)
" "$now" "$window" < "$structured_log" 2>/dev/null || echo "0")

  if (( cb_events > threshold )); then
    slo_alert "breaker_flap" "WARN" "${cb_events} circuit breaker events in last 1h (threshold: ${threshold})"
    return 1
  fi
  return 0
}

# ─── 3. Queue Age Check ──────────────────────────────────────────────────────
# Checks if any ticket has been in same state for too long
queue_age_check() {
  local metrics_file="${METRICS_FILE:-/var/lib/bisb/data/metrics-agent-runs.jsonl}"
  [[ -f "$metrics_file" ]] || return 0

  local now
  now=$(date +%s)
  local max_age=21600  # 6 hours

  # Find tickets with repeated failures (same ticket appearing >5 times with errors)
  local stuck_tickets
  stuck_tickets=$(python3 -c "
import sys, json
from collections import Counter
now = int(sys.argv[1])
max_age = int(sys.argv[2])
ticket_fails = Counter()
for line in sys.stdin:
    line = line.strip()
    if not line: continue
    try:
        e = json.loads(line)
        ts = e.get('epoch', e.get('timestamp', 0))
        if isinstance(ts, str):
            continue
        if now - ts < max_age and e.get('exit_code', 0) != 0:
            ticket_fails[e.get('ticket', 'unknown')] += 1
    except: pass
stuck = [t for t, c in ticket_fails.items() if c >= 5]
if stuck:
    print(','.join(stuck[:5]))
" "$now" "$max_age" < "$metrics_file" 2>/dev/null || true)

  if [[ -n "$stuck_tickets" ]]; then
    slo_alert "queue_stuck" "WARN" "Stuck tickets (5+ failures in 6h): ${stuck_tickets}"
    return 1
  fi
  return 0
}

# ─── 4. Success Rate Check ───────────────────────────────────────────────────
# Checks overall pipeline success rate in recent runs
success_rate_check() {
  local metrics_file="${METRICS_FILE:-/var/lib/bisb/data/metrics-agent-runs.jsonl}"
  [[ -f "$metrics_file" ]] || return 0

  local stats
  stats=$(tail -20 "$metrics_file" 2>/dev/null | python3 -c "
import sys, json
total = 0
success = 0
for line in sys.stdin:
    line = line.strip()
    if not line: continue
    try:
        e = json.loads(line)
        total += 1
        if e.get('exit_code', 1) == 0:
            success += 1
    except: pass
if total > 0:
    rate = round(success / total * 100)
    print(f'{rate}|{success}|{total}')
else:
    print('100|0|0')
" 2>/dev/null || echo "100|0|0")

  local rate
  rate=$(echo "$stats" | cut -d'|' -f1)
  local total
  total=$(echo "$stats" | cut -d'|' -f3)

  if (( total >= 5 && rate < 50 )); then
    slo_alert "success_rate" "HIGH" "Success rate ${rate}% in last ${total} runs (threshold: 50%)"
    return 1
  fi
  return 0
}

# ─── 5. Synthetic Canary ─────────────────────────────────────────────────────
# Quick Claude API check — verifies the AI backend is reachable
run_canary() {
  local start
  start=$(date +%s%N 2>/dev/null || date +%s)

  local canary_exit=0
  local canary_out
  canary_out=$(timeout 30 claude -p "Reply with exactly: CANARY_OK" --model haiku 2>/dev/null) || canary_exit=$?

  local elapsed_ms
  if [[ "$start" =~ [0-9]{10,} ]]; then
    elapsed_ms=$(( ($(date +%s%N) - start) / 1000000 ))
  else
    elapsed_ms=$(( ($(date +%s) - start) * 1000 ))
  fi

  if [[ "$canary_exit" -ne 0 ]] || [[ ! "$canary_out" =~ CANARY_OK ]]; then
    slo_alert "canary" "CRITICAL" "Claude API unreachable (exit=${canary_exit}, ${elapsed_ms}ms)"
    dep_set_down "claude" 2>/dev/null || true
    return 1
  fi

  # Log canary latency for trending
  local ts
  ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  printf '{"ts":"%s","check":"canary","latency_ms":%d,"status":"ok"}\n' \
    "$ts" "$elapsed_ms" \
    >> "$SLO_HISTORY" 2>/dev/null || true

  # Slow canary (>15s) is a warning
  if (( elapsed_ms > 15000 )); then
    slo_alert "canary_slow" "WARN" "Claude API slow: ${elapsed_ms}ms"
  fi

  return 0
}

# ─── Run all SLO checks ──────────────────────────────────────────────────────
slo_check_all() {
  SLO_ALERTS=0

  retry_storm_check || true
  breaker_flap_check || true
  queue_age_check || true
  success_rate_check || true
  # Canary costs tokens — only run if other checks pass
  if (( SLO_ALERTS == 0 )); then
    run_canary || true
  fi

  if (( SLO_ALERTS > 0 )); then
    log_info "[SLO] ${SLO_ALERTS} alert(s) detected" 2>/dev/null || true
    # Trigger auto-degradation based on alert severity
    if (( SLO_ALERTS >= 3 )); then
      degrade_set 2 "slo_multiple_alerts_${SLO_ALERTS}" 2>/dev/null || true
    elif (( SLO_ALERTS >= 1 )); then
      local current
      current=$(degrade_get 2>/dev/null || echo "0")
      if (( current < 1 )); then
        degrade_set 1 "slo_alert" 2>/dev/null || true
      fi
    fi
  fi

  echo "$SLO_ALERTS"
}

# ─── SLO report (human-readable) ─────────────────────────────────────────────
slo_report() {
  local hours="${1:-24}"
  local cutoff
  cutoff=$(date -u -d "${hours} hours ago" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u '+%Y-%m-%dT%H:%M:%SZ')

  echo "=== Pipeline SLO Report (last ${hours}h) ==="
  echo ""

  if [[ ! -f "$SLO_HISTORY" ]]; then
    echo "No SLO data yet."
    return
  fi

  python3 -c "
import sys, json
from collections import Counter
cutoff = sys.argv[1]
checks = Counter()
severities = Counter()
for line in sys.stdin:
    line = line.strip()
    if not line: continue
    try:
        e = json.loads(line)
        if e['ts'] < cutoff: continue
        if 'check' in e:
            checks[e['check']] += 1
        if 'severity' in e:
            severities[e['severity']] += 1
    except: pass
print('Alerts by check:')
for check, count in checks.most_common():
    print(f'  {count:>3}x  {check}')
print()
print('Alerts by severity:')
for sev, count in severities.most_common():
    print(f'  {count:>3}x  {sev}')
" "$cutoff" < "$SLO_HISTORY" 2>/dev/null || echo "Error reading SLO history"
}
