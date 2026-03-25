#!/usr/bin/env bash
# =============================================================================
# agent-dm-poller.sh — Poll Mattermost DMs for messages to agent bots
#
# Runs every 2 minutes via cron. For each agent bot, checks for new DMs
# from Hedi and calls agent-dm-handler.sh to generate a response.
#
# Storage:
#   Last poll timestamp: /var/lib/bisb/data/agents/AGENT/last-dm-poll.txt
#
# Cron: */2 * * * * /opt/bisb-scripts/agent-dm-poller.sh >> /var/log/bisb/dm-poller.log 2>&1
# =============================================================================
set -euo pipefail

export PATH="$HOME/.local/bin:/usr/local/bin:$PATH"

# ─── Single-instance lock (prevent overlapping cron runs) ─────────────────
LOCK_FILE="/tmp/bisb-dm-poller.lock"
# Stale lock detection: if lock file exists and is older than 10 minutes,
# the previous poller likely crashed — remove it
if [[ -f "$LOCK_FILE" ]]; then
  _lock_age=$(( $(date +%s) - $(stat -c %Y "$LOCK_FILE" 2>/dev/null || echo 0) ))
  if (( _lock_age > 600 )); then
    echo "[$(date -u '+%Y-%m-%d %H:%M:%S')] [INFO] Removing stale DM poller lock (age=${_lock_age}s)" >> /var/log/bisb/dm-poller.log
    rm -f "$LOCK_FILE"
  fi
fi
exec 200>"$LOCK_FILE"
if ! flock -n 200; then
  echo "[$(date -u '+%Y-%m-%d %H:%M:%S')] [INFO] DM poller already running — skipping this run" >> /var/log/bisb/dm-poller.log
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENT_NAME="omar"  # load_env with omar context (system-level token access)
source "${SCRIPT_DIR}/agent-common.sh"
load_env

# Cron already redirects stderr → dm-poller.log (2>&1), so don't set LOG_FILE
# to avoid log_info writing twice (once to file, once via cron redirect)
LOG_FILE=""
mkdir -p /var/log/bisb /var/lib/bisb/data

log_info "=== DM Poller starting ==="

MM_URL="${MATTERMOST_URL:-}"
if [[ -z "$MM_URL" ]]; then
  log_error "MATTERMOST_URL not set — exiting"
  exit 1
fi

# ─── Hedi's Mattermost user ID ─────────────────────────────────────────────
# Used to identify DMs from Hedi to each agent bot
HEDI_USERNAME="${HEDI_MM_USERNAME:-hedijallouli}"

# Mapping: agent → Mattermost user ID (same as in tracker-common.sh)
declare -A MM_AGENT_USER_IDS=(
  [salma]="kdpqac4b67rjpxa4eo95w96qry"
  [youssef]="zjo43ghdsf88mdfhd6rroc54ey"
  [nadia]="1mfmqc7qpt8qpgyr1owa8dmhiy"
  [rami]="adkx6ufbify95g1dm88xjj8eta"
  [omar]="kpo1wnz59tgqt8rdt6htk736na"
  [layla]="4dcs8qt6ut8adkubjb4kbbiqbr"
)

# Mapping: agent → MM token env var
declare -A MM_AGENT_TOKENS=(
  [salma]="$MM_TOKEN_SALMA"
  [youssef]="${MM_TOKEN_YOUSSEF:-}"
  [nadia]="${MM_TOKEN_NADIA:-}"
  [rami]="${MM_TOKEN_RAMI:-}"
  [omar]="${MM_TOKEN_OMAR:-}"
  [layla]="${MM_TOKEN_LAYLA:-}"
)

# ─── Resolve Hedi's user ID once ───────────────────────────────────────────
HEDI_USER_ID=$(curl -s \
  -H "Authorization: Bearer ${MM_TOKEN_SALMA:-}" \
  "${MM_URL}/api/v4/users/username/${HEDI_USERNAME}" 2>/dev/null \
  | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('id',''))" 2>/dev/null || echo "")

if [[ -z "$HEDI_USER_ID" ]]; then
  log_error "Could not resolve Hedi's Mattermost user ID (username: ${HEDI_USERNAME})"
  log_info "Check HEDI_MM_USERNAME in env or Mattermost token permissions"
  exit 1
fi

log_info "Hedi user ID: ${HEDI_USER_ID}"

# ─── Poll each agent ────────────────────────────────────────────────────────
AGENTS=("salma" "youssef" "nadia" "rami" "layla" "omar")

for agent in "${AGENTS[@]}"; do
  MM_TOKEN="${MM_AGENT_TOKENS[$agent]:-}"
  AGENT_USER_ID="${MM_AGENT_USER_IDS[$agent]:-}"

  if [[ -z "$MM_TOKEN" || -z "$AGENT_USER_ID" ]]; then
    log_info "Skipping ${agent}: no token or user ID configured"
    continue
  fi

  AGENT_DATA_DIR="/var/lib/bisb/data/agents/${agent}"
  mkdir -p "$AGENT_DATA_DIR"
  POLL_TIMESTAMP_FILE="${AGENT_DATA_DIR}/last-dm-poll.txt"

  # Get last poll timestamp (Unix ms) — default: 5 minutes ago
  if [[ -f "$POLL_TIMESTAMP_FILE" ]]; then
    LAST_POLL_MS=$(cat "$POLL_TIMESTAMP_FILE" 2>/dev/null || echo "")
  fi
  if [[ -z "${LAST_POLL_MS:-}" ]]; then
    LAST_POLL_MS=$(( ($(date +%s) - 300) * 1000 ))  # 5 min ago
  fi

  log_info "Checking DMs for ${agent} (since ${LAST_POLL_MS}ms)"

  # Get or create DM channel between agent and Hedi
  CHANNEL_RESULT=$(curl -s -X POST \
    -H "Authorization: Bearer ${MM_TOKEN}" \
    -H "Content-Type: application/json" \
    "${MM_URL}/api/v4/channels/direct" \
    -d "[\"${AGENT_USER_ID}\", \"${HEDI_USER_ID}\"]" 2>/dev/null || echo "")

  CHANNEL_ID=$(echo "$CHANNEL_RESULT" \
    | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('id',''))" 2>/dev/null || echo "")

  if [[ -z "$CHANNEL_ID" ]]; then
    log_info "No DM channel for ${agent} ↔ Hedi — skipping"
    continue
  fi

  # Fetch posts since last poll
  POSTS_RESULT=$(curl -s \
    -H "Authorization: Bearer ${MM_TOKEN}" \
    "${MM_URL}/api/v4/channels/${CHANNEL_ID}/posts?since=${LAST_POLL_MS}&per_page=50" 2>/dev/null || echo "")

  # Extract new messages from Hedi (not from the agent itself)
  NEW_MESSAGES=$(python3 - "$POSTS_RESULT" "$HEDI_USER_ID" "$AGENT_USER_ID" << 'PYEOF'
import json, sys

posts_json = sys.argv[1]
hedi_id = sys.argv[2]
agent_id = sys.argv[3]

try:
    data = json.loads(posts_json)
except Exception:
    sys.exit(0)

posts = data.get('posts', {})
order = data.get('order', [])

messages = []
for post_id in order:
    post = posts.get(post_id, {})
    user_id = post.get('user_id', '')
    message = post.get('message', '').strip()
    create_at = post.get('create_at', 0)
    post_type = post.get('type', '')

    # Only messages from Hedi, not system messages, not empty
    if user_id == hedi_id and message and not post_type:
        messages.append(message)

# Print each message on its own line (pipe-separated to handle newlines)
for m in messages:
    # Escape pipes and newlines for safe passing
    safe = m.replace('|', '｜').replace('\n', ' ').replace('\r', '')
    print(safe)
PYEOF
2>/dev/null || echo "")

  # Update poll timestamp to now
  echo "$(( $(date +%s) * 1000 ))" > "$POLL_TIMESTAMP_FILE"

  if [[ -z "$NEW_MESSAGES" ]]; then
    log_info "No new DMs for ${agent}"
    continue
  fi

  # Process each new message
  while IFS= read -r msg; do
    [[ -z "$msg" ]] && continue
    log_info "New DM to ${agent}: ${msg:0:80}..."

    # Call dm-handler
    "${SCRIPT_DIR}/agent-dm-handler.sh" \
      "${agent}" \
      "${msg}" \
      "${HEDI_USERNAME}" \
      >> "/var/log/bisb/dm-handler-${agent}-$(date +%Y-%m-%d).log" 2>&1 || true

    log_info "DM handler completed for ${agent}"
  done <<< "$NEW_MESSAGES"

done

log_success "=== DM Poller complete ==="
