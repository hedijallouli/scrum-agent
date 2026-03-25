#!/usr/bin/env bash
# =============================================================================
# degrade.sh — Graceful Degradation Hierarchy for BISB agent pipeline
#
# Problem: If one agent is broken, its entire phase stops.
#          If Plane is down, ALL agents stop — even those that don't need Plane.
#
# Solution: Multi-level degradation with per-agent fallback behaviors.
#
# Levels:
#   0 = NORMAL    — All systems operational
#   1 = DEGRADED  — Some agents limited, non-critical work paused
#   2 = MINIMAL   — Only critical agents run (Youssef, Nadia)
#   3 = EMERGENCY — All agents paused, only watchdog runs
#
# Usage:
#   source degrade.sh
#   degrade_set 1 "Plane API intermittent"
#   level=$(degrade_get)
#   if dispatch_allowed "layla" "$level"; then ... fi
# =============================================================================

DEGRADE_FILE="/tmp/bisb-degrade-level"
DEGRADE_HISTORY="/var/lib/bisb/data/degrade-history.jsonl"
mkdir -p "$(dirname "$DEGRADE_HISTORY")" 2>/dev/null || true

# ─── Set degradation level ────────────────────────────────────────────────────
# Args: LEVEL REASON
degrade_set() {
  local level="$1" reason="${2:-manual}"
  local prev
  prev=$(degrade_get)

  echo "${level}|$(date +%s)|${reason}" > "$DEGRADE_FILE"

  # Log transition
  if [[ "$level" != "$prev" ]]; then
    local ts
    ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    printf '{"ts":"%s","from":%s,"to":%s,"reason":"%s"}\n' \
      "$ts" "$prev" "$level" "$reason" \
      >> "$DEGRADE_HISTORY" 2>/dev/null || true

    # Alert on escalation
    if (( level > prev )); then
      local labels=("NORMAL" "DEGRADED" "MINIMAL" "EMERGENCY")
      log_info "DEGRADATION: ${labels[$prev]:-?} → ${labels[$level]:-?} — ${reason}"
    fi
  fi
}

# ─── Get current degradation level ───────────────────────────────────────────
# Returns: 0-3 (defaults to 0/NORMAL if no file)
degrade_get() {
  if [[ ! -f "$DEGRADE_FILE" ]]; then
    echo "0"
    return
  fi

  # Auto-expire: if file is >1h old, reset to NORMAL
  local age
  age=$(( $(date +%s) - $(stat -c %Y "$DEGRADE_FILE" 2>/dev/null || echo 0) ))
  if (( age > 3600 )); then
    rm -f "$DEGRADE_FILE"
    echo "0"
    return
  fi

  local level
  level=$(cut -d'|' -f1 < "$DEGRADE_FILE" 2>/dev/null || echo "0")
  echo "${level:-0}"
}

# ─── Check if an agent is allowed to dispatch at current level ────────────────
# Args: AGENT LEVEL
# Returns 0 if allowed, 1 if blocked
dispatch_allowed() {
  local agent="$1" level="${2:-$(degrade_get)}"

  case "$level" in
    0) # NORMAL — everyone runs
      return 0
      ;;
    1) # DEGRADED — skip non-critical agents
      case "$agent" in
        layla|karim) return 1 ;;  # Product/Analyst can wait
        *) return 0 ;;
      esac
      ;;
    2) # MINIMAL — only dev + QA
      case "$agent" in
        youssef|nadia) return 0 ;;
        omar) return 0 ;;  # Omar can always run (ops)
        *) return 1 ;;
      esac
      ;;
    3) # EMERGENCY — nobody runs
      return 1
      ;;
    *) # Unknown level, default to allow
      return 0
      ;;
  esac
}

# ─── Get fallback behavior for a blocked agent ───────────────────────────────
# Args: AGENT
# Outputs: "park" | "reassign:AGENT" | "skip"
agent_fallback() {
  local agent="$1"

  case "$agent" in
    youssef) echo "park" ;;          # Park ticket for next cycle
    nadia)   echo "park" ;;          # QA can wait
    salma)   echo "skip" ;;          # PM specs can wait indefinitely
    rami)    echo "reassign:omar" ;; # Omar can do basic arch review
    layla)   echo "skip" ;;          # Product ideation is non-critical
    omar)    echo "park" ;;          # Ops issues park until recovery
    *)       echo "skip" ;;
  esac
}

# ─── Auto-detect degradation from system state ───────────────────────────────
# Reads circuit breakers + dep flags to determine appropriate level.
# Called by dispatcher at cycle start.
auto_degrade_check() {
  local level=0
  local reasons=()

  # Check dependency health
  if dep_is_down "plane" 2>/dev/null; then
    level=2
    reasons+=("plane_down")
  fi
  if dep_is_down "claude" 2>/dev/null; then
    level=2
    reasons+=("claude_down")
  fi

  # Count open circuit breakers
  local open_cbs=0
  for agent in salma youssef nadia rami layla omar; do
    if cb_is_open "$agent" 2>/dev/null; then
      (( open_cbs++ )) || true
    fi
  done

  # 3+ circuit breakers open → DEGRADED
  if (( open_cbs >= 3 && level < 1 )); then
    level=1
    reasons+=("${open_cbs}_circuit_breakers_open")
  fi
  # 5+ circuit breakers open → MINIMAL
  if (( open_cbs >= 5 && level < 2 )); then
    level=2
    reasons+=("${open_cbs}_circuit_breakers_open")
  fi

  # Check memory
  local avail_mb
  avail_mb=$(free -m 2>/dev/null | awk '/^Mem:/ {print $NF}' || echo "999")
  if (( avail_mb < 100 )); then
    level=3
    reasons+=("memory_critical_${avail_mb}MB")
  elif (( avail_mb < 200 )); then
    (( level < 2 )) && level=2
    reasons+=("memory_low_${avail_mb}MB")
  fi

  # Apply if different from current
  local current
  current=$(degrade_get)
  if (( level != current )); then
    local reason_str
    reason_str=$(IFS=','; echo "${reasons[*]}")
    degrade_set "$level" "${reason_str:-auto_check}"
  fi

  echo "$level"
}

# ─── Human-readable status ────────────────────────────────────────────────────
degrade_status() {
  local level
  level=$(degrade_get)
  local labels=("🟢 NORMAL" "🟡 DEGRADED" "🟠 MINIMAL" "🔴 EMERGENCY")
  local reason=""
  if [[ -f "$DEGRADE_FILE" ]]; then
    reason=$(cut -d'|' -f3 < "$DEGRADE_FILE" 2>/dev/null || true)
  fi
  echo "${labels[$level]:-UNKNOWN} (level=${level}) ${reason:+— $reason}"
}
