#!/usr/bin/env bash
# =============================================================================
# idempotency-common.sh — Exactly-once execution for the BISB agent pipeline
#
# Problem: If cron fires twice, or an agent crashes mid-work and retries,
#          we get duplicate PRs, duplicate comments, duplicate state changes.
#
# Solution: Run journal with step tracking. Each agent run:
#   1. Claims a run (atomic mkdir) — blocks duplicate dispatch
#   2. Journals each side-effect BEFORE executing it
#   3. On crash recovery: replays journal to skip completed steps
#
# Usage:
#   source idempotency-common.sh
#   claim_run "BISB-47" "youssef" || { echo "already running"; exit 0; }
#   if ! has_step "create_branch"; then
#     git checkout -b feat/BISB-47 && journal_step "create_branch"
#   fi
#   if ! has_step "create_pr"; then
#     gh pr create ... && journal_step "create_pr" '{"pr_url":"..."}'
#   fi
#   complete_run  # marks run as done, cleans up claim
# =============================================================================

IDEMPOTENCY_DIR="/var/lib/bisb/runs"
mkdir -p "$IDEMPOTENCY_DIR"

# Current run context (set by claim_run)
_IDEM_RUN_DIR=""
_IDEM_JOURNAL=""

# ─── Claim a run: atomic lock for ticket+agent ───────────────────────────────
# Returns 0 if claim acquired, 1 if already running.
# Stale claims (>45 min) are auto-cleaned.
claim_run() {
  local ticket="$1" agent="$2"
  local claim_dir="${IDEMPOTENCY_DIR}/${ticket}/${agent}"
  local lock_file="${claim_dir}/.lock"
  local now
  now=$(date +%s)

  # Clean stale claim (agent crashed >45 min ago)
  if [[ -f "$lock_file" ]]; then
    local lock_age
    lock_age=$(( now - $(stat -c %Y "$lock_file" 2>/dev/null || echo "$now") ))
    if (( lock_age > 2700 )); then
      rm -rf "$claim_dir"
      log_info "Cleaned stale idempotency claim: ${ticket}/${agent} (age=${lock_age}s)"
    else
      # Active claim exists — another instance is running
      return 1
    fi
  fi

  # Atomic claim via mkdir (atomic on all POSIX filesystems)
  if ! mkdir -p "$claim_dir" 2>/dev/null; then
    return 1
  fi

  # Write lock with PID for debugging
  echo "${now}|$$|${RUN_ID:-unknown}" > "$lock_file"

  _IDEM_RUN_DIR="$claim_dir"
  _IDEM_JOURNAL="${claim_dir}/journal.log"

  # Create/reset journal for this run
  echo "# Run started: $(date -u '+%Y-%m-%dT%H:%M:%SZ') pid=$$ run_id=${RUN_ID:-unknown}" > "$_IDEM_JOURNAL"

  return 0
}

# ─── Journal a completed step ─────────────────────────────────────────────────
# Args: STEP_NAME [PAYLOAD_JSON]
journal_step() {
  local step="$1" payload="${2:-\{\}}"
  [[ -z "$_IDEM_JOURNAL" ]] && return 1

  local ts
  ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

  printf '%s|%s|%s\n' "$ts" "$step" "$payload" >> "$_IDEM_JOURNAL" 2>/dev/null || true
}

# ─── Check if a step was already completed ────────────────────────────────────
# Args: STEP_NAME
# Returns 0 if step already done, 1 if not
has_step() {
  local step="$1"
  [[ -z "$_IDEM_JOURNAL" ]] && return 1
  [[ ! -f "$_IDEM_JOURNAL" ]] && return 1

  grep -q "|${step}|" "$_IDEM_JOURNAL" 2>/dev/null
}

# ─── Get the payload of a completed step ──────────────────────────────────────
# Args: STEP_NAME
# Outputs the payload JSON if step exists
get_step_data() {
  local step="$1"
  [[ -z "$_IDEM_JOURNAL" ]] && return 1
  [[ ! -f "$_IDEM_JOURNAL" ]] && return 1

  grep "|${step}|" "$_IDEM_JOURNAL" 2>/dev/null | tail -1 | cut -d'|' -f3
}

# ─── Complete the run: mark as done + cleanup ─────────────────────────────────
complete_run() {
  [[ -z "$_IDEM_RUN_DIR" ]] && return

  journal_step "run_complete"

  # Move journal to history (keep last 5 runs per ticket/agent)
  local history_dir="${_IDEM_RUN_DIR}/history"
  mkdir -p "$history_dir"
  local archive="${history_dir}/$(date +%s).log"
  cp "$_IDEM_JOURNAL" "$archive" 2>/dev/null || true

  # Keep only last 5 history files
  ls -t "$history_dir"/*.log 2>/dev/null | tail -n +6 | xargs rm -f 2>/dev/null || true

  # Release the claim
  rm -f "${_IDEM_RUN_DIR}/.lock" 2>/dev/null || true
  rm -f "$_IDEM_JOURNAL" 2>/dev/null || true

  _IDEM_RUN_DIR=""
  _IDEM_JOURNAL=""
}

# ─── Abort the run (on error) — keep journal for debugging ────────────────────
abort_run() {
  local reason="${1:-unknown}"
  [[ -z "$_IDEM_RUN_DIR" ]] && return

  journal_step "run_aborted" "{\"reason\":\"${reason}\"}"

  # Release claim but keep journal for post-mortem
  rm -f "${_IDEM_RUN_DIR}/.lock" 2>/dev/null || true

  _IDEM_RUN_DIR=""
  _IDEM_JOURNAL=""
}

# ─── List all steps completed in a previous run (for recovery) ────────────────
# Args: TICKET AGENT
list_previous_steps() {
  local ticket="$1" agent="$2"
  local journal="${IDEMPOTENCY_DIR}/${ticket}/${agent}/journal.log"
  [[ ! -f "$journal" ]] && return

  grep -v '^#' "$journal" 2>/dev/null | cut -d'|' -f2
}

# ─── Clean old idempotency data (>48h) ───────────────────────────────────────
clean_idempotency() {
  local now
  now=$(date +%s)
  local cutoff=$(( now - 172800 ))  # 48 hours

  find "$IDEMPOTENCY_DIR" -name ".lock" -type f 2>/dev/null | while read -r lock; do
    local lock_ts
    lock_ts=$(stat -c %Y "$lock" 2>/dev/null || echo "$now")
    if (( lock_ts < cutoff )); then
      local run_dir
      run_dir=$(dirname "$lock")
      rm -rf "$run_dir"
    fi
  done
}
