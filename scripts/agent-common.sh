#!/usr/bin/env bash
# =============================================================================
# agent-common.sh — Shared utilities for scrum-agent pipeline
# =============================================================================
set -euo pipefail

# Ensure tools are in PATH (claude, gh, npm may be in user-local dirs)
export PATH="$HOME/.local/bin:/usr/local/bin:$PATH"

# Load environment — detect project from parent directory or env override
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Auto-detect: if scripts live under /opt/<project>/scrum-agent/scripts/,
# derive project key from the grandparent directory name
if [[ -z "${PROJECT_PREFIX:-}" ]]; then
  _parent="$(cd "${SCRIPT_DIR}/../.." 2>/dev/null && pwd)"
  _dir_name="$(basename "$_parent")"
  # Check if a project-specific env exists
  if [[ -f "/etc/${_dir_name}/.env.agents" ]]; then
    PROJECT_PREFIX="$_dir_name"
  else
    PROJECT_PREFIX="bisb"
  fi
fi
ENV_FILE="${ENV_FILE:-/etc/${PROJECT_PREFIX}/.env.agents}"

# ─── Source reliability modules ────────────────────────────────────────────────
[[ -f "${SCRIPT_DIR}/event-log.sh" ]] && source "${SCRIPT_DIR}/event-log.sh"
[[ -f "${SCRIPT_DIR}/idempotency-common.sh" ]] && source "${SCRIPT_DIR}/idempotency-common.sh"
[[ -f "${SCRIPT_DIR}/degrade.sh" ]] && source "${SCRIPT_DIR}/degrade.sh"
[[ -f "${SCRIPT_DIR}/pipeline-slo.sh" ]] && source "${SCRIPT_DIR}/pipeline-slo.sh"

load_env() {
  if [[ -f "$ENV_FILE" ]]; then
    set -a
    source "$ENV_FILE"
    set +a
  else
    log_error "Missing $ENV_FILE"
    exit 1
  fi
}

# ─── Logging ──────────────────────────────────────────────────────────────────
LOG_DIR="${LOG_DIR:-/var/log/${PROJECT_PREFIX}}"
mkdir -p "$LOG_DIR"

log_info() {
  local msg="[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] $*"
  echo "$msg" >&2
  echo "$msg" >> "${LOG_FILE:-/dev/null}"
}

log_error() {
  local msg="[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $*"
  echo "$msg" >&2
  echo "$msg" >> "${LOG_FILE:-/dev/null}"
}

log_success() {
  local msg="[$(date '+%Y-%m-%d %H:%M:%S')] [SUCCESS] $*"
  echo "$msg" >&2
  echo "$msg" >> "${LOG_FILE:-/dev/null}"
}

init_log() {
  local ticket="$1" agent="$2"
  LOG_FILE="${LOG_DIR}/${ticket}-${agent}-$(date '+%Y-%m-%dT%H:%M:%S').log"
  log_info "Starting agent=${agent} ticket=${ticket}"
}

# ─── Lock Management (per-agent) ─────────────────────────────────────────────
# Each agent sets AGENT_NAME before sourcing this file for per-agent locks.
# This allows Salma, Youssef, Nadia, and Rami to run in parallel.
LOCK_FILE="/tmp/${PROJECT_PREFIX}-agent-${AGENT_NAME:-global}.lock"
LOCK_MAX_AGE=3600  # 60 minutes (Claude calls can take 40+ min)

acquire_lock() {
  if [[ -f "$LOCK_FILE" ]]; then
    local age=$(( $(date +%s) - $(stat -c %Y "$LOCK_FILE" 2>/dev/null || stat -f %m "$LOCK_FILE" 2>/dev/null || echo 0) ))
    if (( age > LOCK_MAX_AGE )); then
      log_info "Removing stale lock (age=${age}s)"
      rm -f "$LOCK_FILE"
    else
      log_info "Another ${AGENT_NAME:-agent} is running (lock age=${age}s). Skipping."
      return 1
    fi
  fi
  echo "$$" > "$LOCK_FILE"
  # Heartbeat: touch lock file every 5 min to prevent stale lock removal
  ( while kill -0 $$ 2>/dev/null; do sleep 300; touch "$LOCK_FILE" 2>/dev/null; done ) &
  _HEARTBEAT_PID=$!
  trap 'kill $_HEARTBEAT_PID 2>/dev/null; rm -f "$LOCK_FILE"' EXIT
  return 0
}

release_lock() {
  rm -f "$LOCK_FILE"
}

# ─── Jira Label Helpers ─────────────────────────────────────────────────────
jira_remove_label() {
  local key="$1" label="$2"
  "${SCRIPT_DIR}/jira-curl.sh" -s -X PUT \
    -H "Authorization: Basic $(jira_auth)" \
    -H "Content-Type: application/json" \
    "${JIRA_BASE_URL}/rest/api/3/issue/${key}" \
    -d "{
      \"update\": {
        \"labels\": [{\"remove\": \"${label}\"}]
      }
    }" > /dev/null 2>&1
}

# ─── Jira API ─────────────────────────────────────────────────────────────────


jira_auth() {
  # -w0 prevents line wrapping on Linux (macOS base64 doesn't wrap by default)
  echo -n "${JIRA_EMAIL}:${JIRA_API_TOKEN}" | base64 -w0 2>/dev/null || echo -n "${JIRA_EMAIL}:${JIRA_API_TOKEN}" | base64
}

jira_get_ticket() {
  local key="$1"
  "${SCRIPT_DIR}/jira-curl.sh" -s -X GET \
    -H "Authorization: Basic $(jira_auth)" \
    -H "Content-Type: application/json" \
    "${JIRA_BASE_URL}/rest/api/3/issue/${key}?fields=summary,description,labels,status,priority,issuetype,comment,subtasks"
}

jira_get_ticket_field() {
  local key="$1" field="$2"
  jira_get_ticket "$key" | python3 -c "
import sys, json
data = json.load(sys.stdin)
fields = data.get('fields', {})
val = fields.get('$field', '')
if isinstance(val, dict):
    print(val.get('name', val.get('content', json.dumps(val))))
elif isinstance(val, list):
    print(json.dumps(val))
else:
    print(val or '')
" 2>/dev/null
}

jira_get_description_text() {
  local key="$1"
  jira_get_ticket "$key" | python3 -c "
import sys, json
def extract_text(node):
    if isinstance(node, str): return node
    if isinstance(node, dict):
        if node.get('type') == 'text': return node.get('text', '')
        content = node.get('content', [])
        return ''.join(extract_text(c) for c in content)
    if isinstance(node, list):
        return ''.join(extract_text(c) for c in node)
    return ''
data = json.load(sys.stdin)
desc = data.get('fields', {}).get('description', {})
print(extract_text(desc))
" 2>/dev/null
}

jira_get_comments() {
  local key="$1"
  jira_get_ticket "$key" | python3 -c "
import sys, json
def extract_text(node):
    if isinstance(node, str): return node
    if isinstance(node, dict):
        if node.get('type') == 'text': return node.get('text', '')
        return ''.join(extract_text(c) for c in node.get('content', []))
    if isinstance(node, list): return ''.join(extract_text(c) for c in node)
    return ''
data = json.load(sys.stdin)
comments = data.get('fields', {}).get('comment', {}).get('comments', [])
for c in comments[-5:]:  # last 5 comments
    author = c.get('author', {}).get('displayName', 'Unknown')
    body = extract_text(c.get('body', {}))
    print(f'--- {author} ---')
    print(body)
    print()
" 2>/dev/null
}

jira_add_comment() {
  local key="$1" message="$2"
  "${SCRIPT_DIR}/jira-curl.sh" -s -X POST \
    -H "Authorization: Basic $(jira_auth)" \
    -H "Content-Type: application/json" \
    "${JIRA_BASE_URL}/rest/api/3/issue/${key}/comment" \
    -d "{
      \"body\": {
        \"type\": \"doc\",
        \"version\": 1,
        \"content\": [{
          \"type\": \"paragraph\",
          \"content\": [{\"type\": \"text\", \"text\": $(echo "$message" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read().strip()))')}]
        }]
      }
    }" > /dev/null 2>&1
}

# ─── Rich ADF Comment ──────────────────────────────────────────────────────
# Posts a richly formatted Jira comment with agent identity, colored panel,
# clickable links, bullet lists, and status indicators.
#
# Usage: jira_add_rich_comment <ticket_key> <agent> <verdict> <message>
#   verdict: PASS|FAIL|PASS_WITH_WARNINGS|BLOCKED|ESCALATED|MERGED|INFO|PENDING|WARNING|NONE
#   message: Structured text (## Heading, - bullets, PR: url, plain text)

declare -A AGENT_FAMILY_INITIAL=(
  [salma]="B.A."
  [youssef]="T."
  [nadia]="C."
  [omar]="J."
  [layla]="M."
  [rami]="H."
)
declare -A AGENT_PANEL_TYPE=(
  [salma]="info"
  [youssef]="success"
  [nadia]="error"
  [omar]="note"
  [layla]="note"
  [rami]="info"
)
# Jira custom emoji (site emoji) — uploaded via admin.atlassian.com/emoji
# Format: shortName|mediaId  (pipe-separated)
declare -A AGENT_JIRA_EMOJI=(
  [salma]=":salma:|5813797c-0309-472e-8826-69cdcadfde5f"
  [youssef]=":youssef:|a52b12cd-b69c-464a-94d7-af5faa5fa72e"
  [nadia]=":nadia:|74eacba0-6ceb-4bfe-b8dc-4ceea0fcd3c2"
  # [karim] retired
  [omar]=":omar:|1e8ddd0d-db70-4437-aa98-3343df73588e"
  [layla]=":layla:|2cf1ca02-731c-45df-8cde-09e85dcdf914"
  [rami]=":rami:|223b1bd4-9938-4b57-882a-3463f77650af"
)

jira_add_rich_comment() {
  local key="$1" agent="$2" verdict="$3" message="$4"

  # Strip ticket suffix from agent name (e.g., nadia-BISB-17 → nadia)
  local agent_base="${agent%%-${PROJECT_KEY}*}"

  # Resolve agent identity
  local full_name="${AGENT_SLACK_USERNAME[$agent_base]:-$agent}"
  local first_name="${full_name%% *}"
  local initial="${AGENT_FAMILY_INITIAL[$agent_base]:-}"
  local display_name="${first_name} ${initial}"
  local job_title="${AGENT_JOB_TITLE[$agent_base]:-}"
  local panel_type="${AGENT_PANEL_TYPE[$agent_base]:-note}"

  # Use Jira custom emoji (with media ID) if available, fallback to standard emoji
  local jira_emoji="${AGENT_JIRA_EMOJI[$agent_base]:-}"
  local emoji_shortname emoji_id
  if [[ -n "$jira_emoji" ]]; then
    emoji_shortname="${jira_emoji%%|*}"
    emoji_id="${jira_emoji##*|}"
  else
    emoji_shortname="${AGENT_SLACK_EMOJI[$agent_base]:-:robot_face:}"
    emoji_id=""
  fi

  # Build ADF via Python script
  local adf_json
  adf_json=$(echo "$message" | python3 "${SCRIPT_DIR}/build-adf-comment.py" \
    "$display_name" "$job_title" "$panel_type" "$verdict" "$emoji_shortname" "$emoji_id" 2>/dev/null)

  if [[ -n "$adf_json" ]]; then
    "${SCRIPT_DIR}/jira-curl.sh" -s -X POST \
      -H "Authorization: Basic $(jira_auth)" \
      -H "Content-Type: application/json" \
      "${JIRA_BASE_URL}/rest/api/3/issue/${key}/comment" \
      -d "$adf_json" > /dev/null 2>&1
    log_info "Rich comment posted to ${key} by ${agent_base} (${verdict})"
  else
    log_error "ADF generation failed for ${key}, falling back to plain text"
    jira_add_comment "$key" "${first_name}: ${message}"
  fi
}

jira_update_labels() {
  local key="$1" remove_label="$2" add_label="$3"
  "${SCRIPT_DIR}/jira-curl.sh" -s -X PUT \
    -H "Authorization: Basic $(jira_auth)" \
    -H "Content-Type: application/json" \
    "${JIRA_BASE_URL}/rest/api/3/issue/${key}" \
    -d "{
      \"update\": {
        \"labels\": [
          {\"remove\": \"${remove_label}\"},
          {\"add\": \"${add_label}\"}
        ]
      }
    }" > /dev/null 2>&1
}

jira_add_label() {
  local key="$1" label="$2"
  "${SCRIPT_DIR}/jira-curl.sh" -s -X PUT \
    -H "Authorization: Basic $(jira_auth)" \
    -H "Content-Type: application/json" \
    "${JIRA_BASE_URL}/rest/api/3/issue/${key}" \
    -d "{
      \"update\": {
        \"labels\": [{\"add\": \"${label}\"}]
      }
    }" > /dev/null 2>&1
}

jira_transition() {
  local key="$1" transition_name="$2"
  # First get available transitions
  local transitions
  transitions=$("${SCRIPT_DIR}/jira-curl.sh" -s -X GET \
    -H "Authorization: Basic $(jira_auth)" \
    -H "Content-Type: application/json" \
    "${JIRA_BASE_URL}/rest/api/3/issue/${key}/transitions")

  local transition_id
  transition_id=$(echo "$transitions" | python3 -c "
import sys, json
# Map English aliases to French transition names (Jira is in French)
ALIASES = {
    'done': ['terminé', 'done', 'terminee'],
    'cours': ['en cours', 'in progress', 'cours'],
    'review': ['in review', 'revue', 'review'],
    'todo': ['a faire', 'à faire', 'to do', 'todo'],
}
data = json.load(sys.stdin)
search = '$transition_name'.lower().strip()
# Build list of terms to match against
match_terms = [search]
for key, aliases in ALIASES.items():
    if search in aliases or search == key:
        match_terms = aliases + [key]
        break
for t in data.get('transitions', []):
    name_lower = t['name'].lower()
    for term in match_terms:
        if term in name_lower:
            print(t['id'])
            sys.exit(0)
" 2>/dev/null)

  if [[ -n "$transition_id" ]]; then
    "${SCRIPT_DIR}/jira-curl.sh" -s -X POST \
      -H "Authorization: Basic $(jira_auth)" \
      -H "Content-Type: application/json" \
      "${JIRA_BASE_URL}/rest/api/3/issue/${key}/transitions" \
      -d "{\"transition\": {\"id\": \"${transition_id}\"}}" > /dev/null 2>&1
    log_info "Transitioned ${key} via transition ${transition_id} (${transition_name})"
  else
    log_error "Transition '${transition_name}' not found for ${key}"
  fi
}

jira_assign_to_me() {
  local key="$1"
  # Get current user's account ID
  local account_id
  account_id=$("${SCRIPT_DIR}/jira-curl.sh" -s -X GET \
    -H "Authorization: Basic $(jira_auth)" \
    -H "Content-Type: application/json" \
    "${JIRA_BASE_URL}/rest/api/3/myself" | python3 -c "import sys,json; print(json.load(sys.stdin).get('accountId',''))" 2>/dev/null)

  if [[ -n "$account_id" ]]; then
    "${SCRIPT_DIR}/jira-curl.sh" -s -X PUT \
      -H "Authorization: Basic $(jira_auth)" \
      -H "Content-Type: application/json" \
      "${JIRA_BASE_URL}/rest/api/3/issue/${key}/assignee" \
      -d "{\"accountId\": \"${account_id}\"}" > /dev/null 2>&1
    log_info "Assigned ${key} to ${JIRA_EMAIL}"
  else
    log_error "Could not get account ID for assignee"
  fi
}

jira_link() {
  local key="$1"
  echo "${JIRA_BASE_URL}/browse/${key}"
}

jira_create_task() {
  local summary="$1" description="$2" priority="${3:-Medium}" labels="${4:-}"
  local labels_json="[]"
  if [[ -n "$labels" ]]; then
    labels_json=$(echo "$labels" | python3 -c "
import sys, json
labels = sys.stdin.read().strip().split(',')
print(json.dumps([{'name': l.strip()} for l in labels if l.strip()]))
")
  fi

  "${SCRIPT_DIR}/jira-curl.sh" -s -X POST \
    -H "Authorization: Basic $(jira_auth)" \
    -H "Content-Type: application/json" \
    "${JIRA_BASE_URL}/rest/api/3/issue" \
    -d "{
      \"fields\": {
        \"project\": {\"key\": \"${JIRA_PROJECT}\"},
        \"summary\": $(echo "$summary" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read().strip()))'),
        \"description\": {
          \"type\": \"doc\", \"version\": 1,
          \"content\": [{\"type\": \"paragraph\", \"content\": [{\"type\": \"text\", \"text\": $(echo "$description" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read().strip()))')}]}]
        },
        \"issuetype\": {\"name\": \"Task\"},
        \"priority\": {\"name\": \"${priority}\"},
        \"labels\": ${labels_json}
      }
    }" 2>/dev/null
}

jira_search() {
  local jql="$1" max_results="${2:-10}"
  local jql_encoded
  jql_encoded=$(printf '%s' "$jql" | sed 's/\\!/!/g' | python3 -c "import urllib.parse, sys; print(urllib.parse.quote(sys.stdin.read()))")
  "${SCRIPT_DIR}/jira-curl.sh" -s -X GET \
    -H "Authorization: Basic $(jira_auth)" \
    -H "Content-Type: application/json" \
    "${JIRA_BASE_URL}/rest/api/3/search/jql?jql=${jql_encoded}&maxResults=${max_results}&fields=key,summary,labels,status,priority" 2>/dev/null
}

jira_search_keys() {
  local jql="$1" max_results="${2:-10}"
  jira_search "$jql" "$max_results" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for issue in data.get('issues', []):
    print(issue['key'])
" 2>/dev/null
}

jira_search_keys_with_summaries() {
  local jql="$1" max_results="${2:-10}"
  jira_search "$jql" "$max_results" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for issue in data.get('issues', []):
    key = issue['key']
    summary = issue.get('fields', {}).get('summary', 'No summary')
    print(f'{key}|{summary}')
" 2>/dev/null
}

# ─── Agent Character System (Sims-like Personality) ─────────────────────────
# Language setting: fr=French (default), en=English, de=German
# Override with: bash set-lang.sh [fr|en|de]  or AGENT_LANG=en in .env.agents
AGENT_LANG="${AGENT_LANG:-${BISB_LANG:-fr}}"

# Agent character traits (used by Claude when generating personalized messages)
declare -A AGENT_TRAITS=(
  [salma]="Organisée, Empathique, Vision long terme, Leader naturelle"
  [youssef]="Perfectionniste, Curieux, Noctambule, Humble, Amoureux du clean code"
  [nadia]="Méticuleuse, Directe, Juste, Gardienne de la qualité, Patience à toute épreuve"
  [rami]="Expérimenté, Mentor bienveillant, Pragmatique, Vision systémique, Calme en toutes circonstances"
  [omar]="Vigilant, Discret, Méthodique, Pas de panique, Nuit et jour sur le pipeline"
  [layla]="Visionnaire, Centrée utilisateur, Stratégique, Optimiste, Culturellement ancrée"
)

declare -A AGENT_CATCHPHRASE=(
  [salma]="N'oubliez pas, on build quelque chose de spécial."
  [youssef]="Clean code first. Les tests ne mentent pas."
  [nadia]="Les bugs ne passent pas sous mon nez."
  [rami]="Code for tomorrow, not just for today."
  [omar]="Je ne dors jamais."
  [layla]="On build d'abord pour le plaisir, le reste suivra."
)

# ─── Slack ────────────────────────────────────────────────────────────────────

# Agent identity mapping for Slack
declare -A AGENT_SLACK_USERNAME=(
  [salma]="Salma Ben Amor"
  [youssef]="Youssef Trabelsi"
  [nadia]="Nadia Chaari"
  [omar]="Omar Jebali"
  [layla]="Layla Mansouri"
  [rami]="Rami Hammami"
)
declare -A AGENT_SLACK_EMOJI=(
  [salma]=":clipboard:"
  [youssef]=":hammer:"
  [nadia]=":mag:"
  [omar]=":telescope:"
  [layla]=":chart_with_upwards_trend:"
  [rami]=":building_construction:"
)
declare -A AGENT_JOB_TITLE=(
  [salma]="Product Owner"
  [youssef]="Software Engineer"
  [nadia]="QA Engineer"
  [omar]="Scrum Master / Ops"
  [layla]="Product Strategist"
  [rami]="Technical Architect"
)
AVATAR_BASE="${AVATAR_BASE:-http://49.13.225.201/avatars}"
declare -A AGENT_SLACK_AVATAR=(
  [salma]="${AVATAR_BASE}/salma-v3.png"
  [youssef]="${AVATAR_BASE}/youssef-v3.png"
  [nadia]="${AVATAR_BASE}/nadia-v3.png"
  [omar]="${AVATAR_BASE}/omar-v3.png"
  [layla]="${AVATAR_BASE}/layla-v3.png"
  [rami]="${AVATAR_BASE}/rami-v3.png"
)

# Route agent to correct Slack channel ID (for chat.postMessage API)
_get_slack_channel_id() {
  local channel="${1:-pipeline}"
  case "$channel" in
    pipeline) echo "${SLACK_CHANNEL_PIPELINE:-}" ;;
    standup)  echo "${SLACK_CHANNEL_STANDUP:-}" ;;
    sprint)   echo "${SLACK_CHANNEL_SPRINT:-}" ;;
    alerts)   echo "${SLACK_CHANNEL_ALERTS:-}" ;;
    *)        echo "" ;;
  esac
}

# Fallback: Route to webhook URL if bot token not available
_get_slack_webhook() {
  local channel="${1:-pipeline}"
  case "$channel" in
    pipeline) echo "${SLACK_WEBHOOK_PIPELINE:-${SLACK_WEBHOOK_URL:-}}" ;;
    standup)  echo "${SLACK_WEBHOOK_STANDUP:-${SLACK_WEBHOOK_URL:-}}" ;;
    sprint)   echo "${SLACK_WEBHOOK_SPRINT:-${SLACK_WEBHOOK_URL:-}}" ;;
    alerts)   echo "${SLACK_WEBHOOK_ALERTS:-${SLACK_WEBHOOK_URL:-}}" ;;
    *)        echo "${SLACK_WEBHOOK_URL:-}" ;;
  esac
}

# Strip markdown from Claude output for Slack (** bold **, ## headers, etc.)
strip_markdown() {
  sed 's/\*\*//g' | sed 's/^## //' | sed 's/^### //' | sed 's/^ISSUES://' | sed 's/^WARNINGS://' | sed '/^$/d'
}

# Main slack notification function
# Usage: slack_notify "message" [channel] [color]
# Channel defaults to "pipeline". Agent identity auto-detected from AGENT_NAME.
# Color: "good" (green), "warning" (yellow), "danger" (red), or hex "#FF0000".
# When color is set, message is sent as a colored attachment with job title as footer.
# Uses chat.postMessage API (custom username/emoji) if SLACK_BOT_TOKEN is set,
# otherwise falls back to incoming webhooks (no custom identity).
slack_notify() {
  local message="$1"
  local channel="${2:-pipeline}"
  local color="${3:-}"

  # Resolve agent identity (strip ticket suffix for nadia-PROJ-XX)
  local agent_base="${AGENT_NAME%%-${PROJECT_KEY}*}"
  local username="${AGENT_SLACK_USERNAME[$agent_base]:-BisB Bot}"
  local emoji="${AGENT_SLACK_EMOJI[$agent_base]:-:robot_face:}"
  local avatar="${AGENT_SLACK_AVATAR[$agent_base]:-}"
  local title="${AGENT_JOB_TITLE[$agent_base]:-}"

  local json_msg
  json_msg=$(echo -e "$message" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read().strip()))')

  # Build icon parameter: prefer avatar URL, fall back to emoji
  local icon_param
  if [[ -n "$avatar" ]]; then
    icon_param="\"icon_url\": \"${avatar}\""
  else
    icon_param="\"icon_emoji\": \"${emoji}\""
  fi

  # Build footer with job title for colored attachments
  local footer_param=""
  if [[ -n "$title" ]]; then
    footer_param=", \"footer\": \"${title}\""
  fi

  # Prefer chat.postMessage with Bot Token (supports custom username/avatar)
  if [[ -n "${SLACK_BOT_TOKEN:-}" ]]; then
    local channel_id
    channel_id=$(_get_slack_channel_id "$channel")
    if [[ -n "$channel_id" ]]; then
      local api_payload
      if [[ -n "$color" ]]; then
        api_payload="{\"channel\": \"${channel_id}\", \"username\": \"${username}\", ${icon_param}, \"attachments\": [{\"color\": \"${color}\", \"text\": ${json_msg}, \"mrkdwn_in\": [\"text\"]${footer_param}}]}"
      else
        api_payload="{\"channel\": \"${channel_id}\", \"username\": \"${username}\", ${icon_param}, \"text\": ${json_msg}}"
      fi
      curl -s -X POST "https://slack.com/api/chat.postMessage" \
        -H "Authorization: Bearer ${SLACK_BOT_TOKEN}" \
        -H "Content-Type: application/json; charset=utf-8" \
        -d "$api_payload" \
        > /dev/null 2>&1
      return 0
    fi
  fi

  # Fallback to webhook (no custom identity — shows app name)
  local webhook
  webhook=$(_get_slack_webhook "$channel")
  if [[ -z "$webhook" ]]; then
    log_info "[Slack skip] $message"
    return 0
  fi

  local webhook_payload
  if [[ -n "$color" ]]; then
    webhook_payload="{\"attachments\": [{\"color\": \"${color}\", \"text\": ${json_msg}, \"mrkdwn_in\": [\"text\"]${footer_param}}]}"
  else
    webhook_payload="{\"text\": ${json_msg}}"
  fi
  curl -s -X POST "$webhook" \
    -H "Content-Type: application/json" \
    -d "$webhook_payload" \
    > /dev/null 2>&1
}

# ─── Git Helpers ──────────────────────────────────────────────────────────────
# Base branch: agents create PRs targeting master
BASE_BRANCH="${BASE_BRANCH:-master}"

ensure_clean_main() {
  cd "$PROJECT_DIR"
  # Stash any uncommitted changes
  if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then
    log_info "Stashing uncommitted changes"
    git stash push -m "agent-stash-$(date +%s)" 2>/dev/null || true
  fi
  # Abort any in-progress rebase/merge from a previous crashed run
  git rebase --abort 2>/dev/null || true
  git merge --abort 2>/dev/null || true
  git checkout "$BASE_BRANCH" 2>/dev/null || {
    # If checkout fails (detached HEAD, conflict state), force reset
    log_info "Checkout failed — force-resetting to ${BASE_BRANCH}"
    git checkout -f "$BASE_BRANCH" 2>/dev/null || true
  }
  git fetch origin "$BASE_BRANCH" 2>/dev/null || true
  git pull origin "$BASE_BRANCH" 2>/dev/null || {
    # If pull fails (diverged), force-checkout to match remote
    log_info "Pull failed — force-checkout to origin/${BASE_BRANCH}"
    git checkout -B "$BASE_BRANCH" "origin/${BASE_BRANCH}" 2>/dev/null || true
  }
  log_info "On clean ${BASE_BRANCH} branch"
}

create_or_checkout_branch() {
  local ticket="$1"
  cd "$PROJECT_DIR"
  local summary
  summary=$(jira_get_ticket_field "$ticket" "summary")
  # Create slug from summary
  local slug
  slug=$(echo "$summary" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | head -c 40 | sed 's/-$//')
  local branch="feature/${ticket}-${slug}"

  # Check if branch already exists (feedback loop from Nadia)
  # Note: redirect all non-branch-name output to stderr so callers
  # using $(create_or_checkout_branch ...) only capture the branch name
  if git rev-parse --verify "$branch" >/dev/null 2>&1; then
    log_info "Branch $branch already exists, checking out" >&2

    # Check if branch is stale (missing commits from test)
    # Count how many commits test has that the branch doesn't
    local behind_count
    behind_count=$(git rev-list --count "${branch}..origin/${BASE_BRANCH}" 2>/dev/null || echo "0")

    if [[ "$behind_count" -gt 0 ]]; then
      log_info "Branch is ${behind_count} commits behind ${BASE_BRANCH}" >&2

      # Check if branch has its own commits (work in progress)
      local ahead_count
      ahead_count=$(git rev-list --count "origin/${BASE_BRANCH}..${branch}" 2>/dev/null || echo "0")

      if [[ "$ahead_count" -eq 0 ]]; then
        # Branch has no unique work — delete and recreate from fresh test
        log_info "Branch has no unique commits — deleting stale branch and recreating" >&2
        git branch -D "$branch" >/dev/null 2>&1 || true
        git push origin --delete "$branch" >/dev/null 2>&1 || true
        git checkout -b "$branch" >/dev/null 2>&1
      else
        # Branch has work — rebase onto latest test to pick up merged PRs
        log_info "Branch has ${ahead_count} unique commits — rebasing onto ${BASE_BRANCH}" >&2
        git checkout "$branch" >/dev/null 2>&1
        git fetch origin "$branch" >/dev/null 2>&1 || true
        if ! git rebase "origin/${BASE_BRANCH}" >/dev/null 2>&1; then
          git rebase --abort 2>/dev/null || true
          log_info "Rebase onto ${BASE_BRANCH} failed — deleting branch and starting fresh" >&2
          git checkout "${BASE_BRANCH}" >/dev/null 2>&1
          git branch -D "$branch" >/dev/null 2>&1 || true
          git push origin --delete "$branch" >/dev/null 2>&1 || true
          git checkout -b "$branch" >/dev/null 2>&1
        fi
      fi
    else
      # Branch is up to date with test — just check out
      git checkout "$branch" >/dev/null 2>&1
      git fetch origin "$branch" >/dev/null 2>&1 || true
      if ! git pull origin "$branch" >/dev/null 2>&1; then
        log_info "Pull failed (likely diverged) — rebasing onto remote" >&2
        if ! git rebase "origin/$branch" >/dev/null 2>&1; then
          git rebase --abort 2>/dev/null || true
          log_info "Rebase failed — deleting and recreating from remote" >&2
          git checkout "${BASE_BRANCH}" >/dev/null 2>&1
          git branch -D "$branch" >/dev/null 2>&1 || true
          git checkout -b "$branch" "origin/$branch" >/dev/null 2>&1
        fi
      fi
    fi
  else
    log_info "Creating new branch: $branch" >&2
    git checkout -b "$branch" >/dev/null 2>&1
  fi
  echo "$branch"
}

run_quality_checks() {
  cd "$PROJECT_DIR"
  local result=0

  log_info "Running typecheck..."
  if npm run typecheck 2>&1; then
    log_info "Typecheck: PASS"
  else
    log_error "Typecheck: FAIL"
    result=1
  fi

  log_info "Running lint..."
  if npm run lint 2>&1; then
    log_info "Lint: PASS"
  else
    log_error "Lint: FAIL"
    result=1
  fi

  log_info "Running build..."
  if npm run build 2>&1; then
    log_info "Build: PASS"
  else
    log_error "Build: FAIL"
    result=1
  fi

  return $result
}

get_diff_stats() {
  cd "$PROJECT_DIR"
  local lines_changed
  lines_changed=$(git diff "$BASE_BRANCH" --stat 2>/dev/null | tail -1 | grep -oE '[0-9]+ insertion|[0-9]+ deletion' | awk '{s+=$1}END{print s+0}')
  echo "${lines_changed:-0}"
}

# ─── PR Helpers ───────────────────────────────────────────────────────────────
# Note: Avoid piping gh directly into head -1 — with pipefail, SIGPIPE from
# head closing stdin kills the pipeline. Capture output first, then extract.
find_pr_for_ticket() {
  local ticket="$1"
  cd "$PROJECT_DIR"
  local result
  # Search by branch name first (preferred — exact match)
  result=$(gh pr list --state open --json number,title,headRefName,url \
    --jq ".[] | select(.headRefName | contains(\"${ticket}\")) | .url" 2>/dev/null) || true
  if [[ -z "$result" ]]; then
    # Fallback: search by PR title (handles Jira→Plane number migration)
    result=$(gh pr list --state open --json number,title,headRefName,url \
      --jq ".[] | select(.title | contains(\"${ticket}\")) | .url" 2>/dev/null) || true
  fi
  echo "$result" | head -1
}

find_pr_branch() {
  local ticket="$1"
  cd "$PROJECT_DIR"
  local result
  # Search by branch name first (preferred — exact match)
  result=$(gh pr list --state open --json headRefName \
    --jq ".[] | select(.headRefName | contains(\"${ticket}\")) | .headRefName" 2>/dev/null) || true
  if [[ -z "$result" ]]; then
    # Fallback: search by PR title (handles Jira→Plane number migration)
    result=$(gh pr list --state open --json title,headRefName \
      --jq ".[] | select(.title | contains(\"${ticket}\")) | .headRefName" 2>/dev/null) || true
  fi
  echo "$result" | head -1
}

find_open_pr_between_branches() {
  local head_branch="$1" base_branch="$2"
  cd "$PROJECT_DIR"
  local result
  result=$(gh pr list --state open --head "$head_branch" --base "$base_branch" \
    --json url --jq ".[0].url" 2>/dev/null) || true
  echo "$result"
}

# ─── Retry Counter ────────────────────────────────────────────────────────────
RETRY_DIR="/tmp/${PROJECT_PREFIX}-retries"
mkdir -p "$RETRY_DIR"

get_retry_count() {
  local ticket="$1" agent="$2"
  local file="${RETRY_DIR}/${ticket}-${agent}"
  if [[ -f "$file" ]]; then
    cat "$file"
  else
    echo "0"
  fi
}

increment_retry() {
  local ticket="$1" agent="$2"
  local file="${RETRY_DIR}/${ticket}-${agent}"
  local count
  count=$(get_retry_count "$ticket" "$agent")
  echo $(( count + 1 )) > "$file"
}

reset_retry() {
  local ticket="$1" agent="$2"
  rm -f "${RETRY_DIR}/${ticket}-${agent}"
}

# ─── Dispatch Blacklist ──────────────────────────────────────────────────────
# Prevents re-dispatching tickets that have exceeded max retries.
# Entries expire after BLACKLIST_COOLDOWN seconds (default 1 hour).
BLACKLIST_FILE="/tmp/${PROJECT_PREFIX}-dispatch-blacklist"
BLACKLIST_COOLDOWN=3600  # 1 hour

blacklist_ticket() {
  local ticket="$1" reason="${2:-unknown}"
  echo "${ticket}|$(date +%s)|${reason}" >> "$BLACKLIST_FILE"
  log_info "Blacklisted ${ticket}: ${reason} (cooldown: ${BLACKLIST_COOLDOWN}s)"
}

is_blacklisted() {
  local ticket="$1"
  [[ ! -f "$BLACKLIST_FILE" ]] && return 1
  local now
  now=$(date +%s)
  while IFS='|' read -r t ts reason; do
    [[ "$t" != "$ticket" ]] && continue
    if (( now - ts < BLACKLIST_COOLDOWN )); then
      return 0
    fi
  done < "$BLACKLIST_FILE"
  return 1
}

clean_blacklist() {
  [[ ! -f "$BLACKLIST_FILE" ]] && return
  local now tmp
  now=$(date +%s)
  tmp=$(mktemp /tmp/${PROJECT_PREFIX}-bl-clean-XXXXXX)
  while IFS='|' read -r t ts reason; do
    [[ -z "$t" ]] && continue
    if (( now - ts < BLACKLIST_COOLDOWN )); then
      echo "${t}|${ts}|${reason}"
    fi
  done < "$BLACKLIST_FILE" > "$tmp"
  mv "$tmp" "$BLACKLIST_FILE"
}

remove_from_blacklist() {
  local ticket="$1"
  [[ ! -f "$BLACKLIST_FILE" ]] && return
  local tmp
  tmp=$(mktemp /tmp/${PROJECT_PREFIX}-bl-rm-XXXXXX)
  grep -v "^${ticket}|" "$BLACKLIST_FILE" > "$tmp" 2>/dev/null || true
  mv "$tmp" "$BLACKLIST_FILE"
  log_info "Removed ${ticket} from blacklist"
}

# ═══════════════════════════════════════════════════════════════════════════════
# PER-AGENT CIRCUIT BREAKERS (Perplexity #1)
# ═══════════════════════════════════════════════════════════════════════════════
# When an agent has too many consecutive failures in a short window,
# open the circuit breaker to prevent thrashing.
# File: /tmp/${PROJECT_PREFIX}-cb-AGENT.state → failure_count|last_failure_ts|open_until_ts

CB_DIR="/tmp/${PROJECT_PREFIX}-circuit-breakers"
CB_MAX_FAILURES=5        # failures in window → open breaker
CB_WINDOW=600            # 10 min window
CB_OPEN_DURATION=900     # 15 min breaker open

mkdir -p "$CB_DIR" 2>/dev/null || true

cb_record_failure() {
  local agent="$1"
  local cb_file="${CB_DIR}/${agent}.state"
  local now
  now=$(date +%s)

  local count=0 last_ts=0 open_until=0
  if [[ -f "$cb_file" ]]; then
    IFS='|' read -r count last_ts open_until < "$cb_file" 2>/dev/null || true
  fi

  # If last failure was outside the window, reset counter
  if (( now - last_ts > CB_WINDOW )); then
    count=0
  fi

  count=$(( count + 1 ))

  # Check if we should open the breaker
  if (( count >= CB_MAX_FAILURES )); then
    open_until=$(( now + CB_OPEN_DURATION ))
    log_info "Circuit breaker OPEN for ${agent}: ${count} failures in ${CB_WINDOW}s — locked until $(date -d @${open_until} '+%H:%M:%S' 2>/dev/null || echo ${open_until})"
  fi

  echo "${count}|${now}|${open_until}" > "$cb_file"
}

cb_is_open() {
  local agent="$1"
  local cb_file="${CB_DIR}/${agent}.state"
  [[ -f "$cb_file" ]] || return 1

  local count last_ts open_until
  IFS='|' read -r count last_ts open_until < "$cb_file" 2>/dev/null || return 1

  local now
  now=$(date +%s)

  if (( open_until > 0 && now < open_until )); then
    return 0  # breaker is open
  fi

  # Breaker expired — reset
  if (( open_until > 0 && now >= open_until )); then
    echo "0|0|0" > "$cb_file"
  fi

  return 1
}

cb_reset() {
  local agent="$1"
  echo "0|0|0" > "${CB_DIR}/${agent}.state"
  log_info "Circuit breaker reset for ${agent}"
}

# ─── Dependency Health Flags (Perplexity #1b) ────────────────────────────────
# When a shared dependency is down, agents skip work instead of thrashing.
# Files: /tmp/${PROJECT_PREFIX}-dep-{plane,github,claude}.down → timestamp when set

DEP_FLAG_DIR="/tmp/${PROJECT_PREFIX}-dep-flags"
DEP_DOWN_DURATION=300  # 5 min flag expiry

mkdir -p "$DEP_FLAG_DIR" 2>/dev/null || true

dep_set_down() {
  local dep="$1"
  echo "$(date +%s)" > "${DEP_FLAG_DIR}/${dep}.down"
  log_info "Dependency ${dep} marked DOWN for ${DEP_DOWN_DURATION}s"
}

dep_is_down() {
  local dep="$1"
  local flag="${DEP_FLAG_DIR}/${dep}.down"
  [[ -f "$flag" ]] || return 1

  local ts now age
  ts=$(cat "$flag" 2>/dev/null || echo 0)
  now=$(date +%s)
  age=$(( now - ts ))

  if (( age < DEP_DOWN_DURATION )); then
    return 0  # still down
  fi

  # Expired — clean up
  rm -f "$flag"
  return 1
}

dep_check_or_skip() {
  local dep="$1" agent="${2:-unknown}"
  if dep_is_down "$dep"; then
    log_info "Dependency ${dep} is down — ${agent} skipping work"
    return 0  # caller should skip
  fi
  return 1  # proceed normally
}

# ─── Poison Pill Detection (Perplexity #1c) ──────────────────────────────────
# If a ticket is blacklisted more than N times in 24h, mark as Needs Human
POISON_PILL_FILE="/tmp/${PROJECT_PREFIX}-poison-pills"
POISON_PILL_THRESHOLD=3  # blacklisted 3+ times in 24h

check_poison_pill() {
  local ticket="$1"
  [[ ! -f "$POISON_PILL_FILE" ]] && return 1

  local now count
  now=$(date +%s)
  count=0
  while IFS='|' read -r t ts; do
    [[ "$t" != "$ticket" ]] && continue
    (( now - ts < 86400 )) && (( count++ ))
  done < "$POISON_PILL_FILE"

  if (( count >= POISON_PILL_THRESHOLD )); then
    log_info "POISON PILL: ${ticket} blacklisted ${count} times in 24h"
    return 0
  fi
  return 1
}

record_blacklist_event() {
  local ticket="$1"
  echo "${ticket}|$(date +%s)" >> "$POISON_PILL_FILE"

  # Check for poison pill
  if check_poison_pill "$ticket"; then
    log_info "Ticket ${ticket} is a poison pill — marking Needs Human"
    jira_set_state "$ticket" "needs-human" 2>/dev/null || true
    plane_set_assignee "$ticket" "hedi" 2>/dev/null || true
    jira_add_rich_comment "$ticket" "omar" "WARNING" \
      "🚨 Poison pill détecté: ce ticket a été blacklisté ${POISON_PILL_THRESHOLD}+ fois en 24h. Escaladé à Hedi." \
      2>/dev/null || true
    slack_notify "omar" "🚨 Poison pill: $(mm_ticket_link "${ticket}") — blacklisté ${POISON_PILL_THRESHOLD}+ fois en 24h. Escaladé à @hedi." "pipeline" "warning" 2>/dev/null || true
  fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# STRUCTURED LOGGING + METRICS (Perplexity #2)
# ═══════════════════════════════════════════════════════════════════════════════
# JSON log lines for machine parsing + unified metrics JSONL

STRUCTURED_LOG="${LOG_DIR}/structured.log"
METRICS_FILE="/var/lib/${PROJECT_PREFIX}/data/metrics-agent-runs.jsonl"
mkdir -p "$(dirname "$METRICS_FILE")" 2>/dev/null || true

# Generate a unique run ID per dispatch/agent invocation
export RUN_ID="${RUN_ID:-$(date +%s)-$$-$RANDOM}"

log_json() {
  local level="$1"; shift
  local msg="$1"; shift
  local extra="${1:-}"

  printf '{"ts":"%s","level":"%s","agent":"%s","ticket":"%s","run_id":"%s","msg":"%s"%s}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "$level" \
    "${AGENT_NAME:-unknown}" \
    "${TICKET_KEY:-none}" \
    "${RUN_ID}" \
    "$msg" \
    "${extra:+,$extra}" \
    >> "$STRUCTURED_LOG" 2>/dev/null || true
}

# Log a complete agent run to metrics JSONL
log_metric() {
  local agent="$1" ticket="$2" exit_code="$3" duration="$4"
  local model="${5:-unknown}" error_type="${6:-none}"
  local success="false"
  [[ "$exit_code" -eq 0 ]] && success="true"

  local retry_count=0
  retry_count=$(get_retry_count "$ticket" "$agent" 2>/dev/null || echo 0)

  printf '{"ts":"%s","agent":"%s","ticket":"%s","run_id":"%s","success":%s,"exit_code":%d,"duration_ms":%d,"model":"%s","error_type":"%s","retry_count":%d}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "$agent" "$ticket" "$RUN_ID" \
    "$success" "$exit_code" \
    "$(( duration * 1000 ))" \
    "$model" "$error_type" "$retry_count" \
    >> "$METRICS_FILE" 2>/dev/null || true
}

# ═══════════════════════════════════════════════════════════════════════════════
# ERROR CLASSIFICATION + EXPONENTIAL BACKOFF (Perplexity #3)
# ═══════════════════════════════════════════════════════════════════════════════
# Classify failures and apply appropriate retry strategy.
# Stores next_earliest_retry_ts in retry files.

BACKOFF_DIR="/tmp/${PROJECT_PREFIX}-backoff"
mkdir -p "$BACKOFF_DIR" 2>/dev/null || true

# Error types: RATE_LIMIT, TRANSIENT, TIMEOUT, BAD_OUTPUT, PERMANENT
classify_error() {
  local exit_code="$1" stderr_text="${2:-}"

  # Timeout
  if [[ "$exit_code" -eq 124 ]]; then
    echo "TIMEOUT"
    return
  fi

  # Rate limit (429 / quota exceeded)
  if echo "$stderr_text" | grep -qiE "rate.limit|429|overloaded|too many requests|quota exceeded" 2>/dev/null; then
    echo "RATE_LIMIT"
    return
  fi

  # Transient (5xx, network errors)
  if echo "$stderr_text" | grep -qiE "5[0-9][0-9]|connection.refused|connection.reset|network|ECONNRESET|ETIMEDOUT|service.unavailable" 2>/dev/null; then
    echo "TRANSIENT"
    return
  fi

  # Permanent (auth, 404, invalid state)
  if echo "$stderr_text" | grep -qiE "401|403|404|invalid|not.found|unauthorized|forbidden|authentication" 2>/dev/null; then
    echo "PERMANENT"
    return
  fi

  # Bad output (validation failures)
  if echo "$stderr_text" | grep -qiE "validation|invalid.output|parse.error|malformed" 2>/dev/null; then
    echo "BAD_OUTPUT"
    return
  fi

  # Default: transient (assume retriable)
  echo "TRANSIENT"
}

# Calculate backoff delay with jitter
# Schedule: 60s, 240s, 600s, 1800s (1m, 4m, 10m, 30m) ± 30% jitter
get_backoff_delay() {
  local retry_count="$1" error_type="${2:-TRANSIENT}"

  local base_delays=(60 240 600 1800)
  local idx=$retry_count
  (( idx >= ${#base_delays[@]} )) && idx=$(( ${#base_delays[@]} - 1 ))
  local base=${base_delays[$idx]}

  # Rate limits get longer backoff
  if [[ "$error_type" == "RATE_LIMIT" ]]; then
    base=$(( base * 2 ))
  fi

  # Permanent errors: no retry
  if [[ "$error_type" == "PERMANENT" ]]; then
    echo "0"
    return
  fi

  # Add ±30% jitter
  local jitter_range=$(( base * 30 / 100 ))
  local jitter=$(( (RANDOM % (jitter_range * 2 + 1)) - jitter_range ))
  local delay=$(( base + jitter ))
  (( delay < 30 )) && delay=30

  echo "$delay"
}

# Record failure with backoff — sets next_earliest_retry_ts
record_failure_with_backoff() {
  local ticket="$1" agent="$2" error_type="$3"
  local backoff_file="${BACKOFF_DIR}/${ticket}-${agent}"
  local now
  now=$(date +%s)

  local retry_count
  retry_count=$(get_retry_count "$ticket" "$agent" 2>/dev/null || echo 0)

  # Permanent errors: escalate immediately, no retry
  if [[ "$error_type" == "PERMANENT" ]]; then
    log_info "PERMANENT error for ${ticket}/${agent} — no retry, escalating"
    echo "${now}|0|${error_type}" > "$backoff_file"
    return
  fi

  local delay
  delay=$(get_backoff_delay "$retry_count" "$error_type")
  local next_ts=$(( now + delay ))

  echo "${next_ts}|${delay}|${error_type}" > "$backoff_file"
  log_info "Backoff for ${ticket}/${agent}: ${delay}s (type=${error_type}, retry=${retry_count})"
  log_json "INFO" "backoff_set" "\"ticket\":\"${ticket}\",\"delay\":${delay},\"error_type\":\"${error_type}\",\"retry\":${retry_count}"
}

# Check if a ticket-agent pair is in backoff
can_retry_now() {
  local ticket="$1" agent="$2"
  local backoff_file="${BACKOFF_DIR}/${ticket}-${agent}"
  [[ -f "$backoff_file" ]] || return 0  # no backoff → can retry

  local next_ts delay error_type
  IFS='|' read -r next_ts delay error_type < "$backoff_file" 2>/dev/null || return 0

  local now
  now=$(date +%s)

  # Permanent: never auto-retry
  if [[ "$error_type" == "PERMANENT" ]]; then
    return 1
  fi

  if (( now >= next_ts )); then
    return 0  # backoff expired → can retry
  fi

  local remaining=$(( next_ts - now ))
  log_info "Backoff active for ${ticket}/${agent}: ${remaining}s remaining (type=${error_type})"
  return 1
}

# Clean expired backoff files
clean_backoff() {
  local now
  now=$(date +%s)
  for f in "${BACKOFF_DIR}"/*; do
    [[ -f "$f" ]] || continue
    local next_ts
    IFS='|' read -r next_ts _ _ < "$f" 2>/dev/null || continue
    (( now > next_ts + 3600 )) && rm -f "$f"  # clean files older than 1h past expiry
  done
}

# ═══════════════════════════════════════════════════════════════════════════════
# PER-AGENT COST BUDGETS + RESPONSE CACHING (Perplexity #4)
# ═══════════════════════════════════════════════════════════════════════════════

# ─── Per-Agent Budget Tracking ────────────────────────────────────────────────
AGENT_BUDGET_FILE="/var/lib/${PROJECT_PREFIX}/data/costs/agent-budgets-$(date -u +%Y-%m-%d).json"
mkdir -p "$(dirname "$AGENT_BUDGET_FILE")" 2>/dev/null || true

# Default daily budget shares (percentage of total daily budget)
declare -A AGENT_BUDGET_SHARE=(
  [salma]=15
  [youssef]=40
  [nadia]=20
  [rami]=10
  [layla]=10
  [omar]=5
)

record_agent_cost() {
  local agent="$1" model="$2" duration="${3:-0}"
  python3 -c "
import json, sys, os
agent = sys.argv[1]
model = sys.argv[2]
duration = int(sys.argv[3])
path = '${AGENT_BUDGET_FILE}'

try:
    with open(path) as f:
        data = json.load(f)
except:
    data = {}

if agent not in data:
    data[agent] = {'calls': 0, 'total_duration': 0, 'models': {}}

data[agent]['calls'] += 1
data[agent]['total_duration'] += duration

if model not in data[agent]['models']:
    data[agent]['models'][model] = 0
data[agent]['models'][model] += 1

with open(path, 'w') as f:
    json.dump(data, f, indent=2)
" "$agent" "$model" "$duration" 2>/dev/null || true
}

is_agent_over_budget() {
  local agent="$1"
  local share="${AGENT_BUDGET_SHARE[$agent]:-10}"
  local daily_limit="${COST_BUDGET_DAILY:-100}"

  python3 -c "
import json, sys, os
agent = sys.argv[1]
share = int(sys.argv[2])
daily_limit = int(sys.argv[3])
path = '${AGENT_BUDGET_FILE}'

try:
    with open(path) as f:
        data = json.load(f)
except:
    sys.exit(1)  # no data → not over budget

total_calls = sum(d.get('calls', 0) for d in data.values())
agent_calls = data.get(agent, {}).get('calls', 0)

# Absolute limit: agent can't exceed its share of the daily cap
agent_abs_limit = int(daily_limit * share / 100)
if agent_abs_limit > 0 and agent_calls >= agent_abs_limit:
    print(f'{agent}: {agent_calls}/{agent_abs_limit} calls (absolute cap)')
    sys.exit(0)  # over budget

# Percentage throttle only kicks in after enough calls from 3+ agents
# (avoids false positives when only 1-2 agents are active)
if total_calls < 30:
    sys.exit(1)  # not enough data to throttle

agent_pct = agent_calls * 100 / total_calls
if agent_pct > share * 1.5:  # 50% over share → throttle
    print(f'{agent}: {agent_pct:.0f}% of calls (budget: {share}%)')
    sys.exit(0)  # over budget
sys.exit(1)
" "$agent" "$share" "$daily_limit" 2>/dev/null
  return $?
}

# ─── Response Caching ────────────────────────────────────────────────────────
CACHE_DIR="/var/lib/${PROJECT_PREFIX}/cache"
CACHE_MAX_AGE=3600  # 1 hour default

mkdir -p "$CACHE_DIR" 2>/dev/null || true

cache_key() {
  local agent="$1" ticket="$2" input_hash="$3"
  echo "${agent}/${ticket}-${input_hash}"
}

cache_get() {
  local key="$1"
  local cache_file="${CACHE_DIR}/${key}.json"
  [[ -f "$cache_file" ]] || return 1

  local age now file_ts
  now=$(date +%s)
  file_ts=$(stat -c %Y "$cache_file" 2>/dev/null || echo 0)
  age=$(( now - file_ts ))

  if (( age > CACHE_MAX_AGE )); then
    rm -f "$cache_file"
    return 1
  fi

  cat "$cache_file"
  return 0
}

cache_set() {
  local key="$1" content="$2"
  local cache_file="${CACHE_DIR}/${key}.json"
  mkdir -p "$(dirname "$cache_file")" 2>/dev/null || true
  echo "$content" > "$cache_file"
}

# Generate a hash for cache keying
input_hash() {
  echo "$*" | sha256sum | head -c 16
}

# Clean old cache entries
clean_cache() {
  find "$CACHE_DIR" -type f -mmin +120 -delete 2>/dev/null || true
}

# ─── Structured Feedback ─────────────────────────────────────────────────────
FEEDBACK_DIR="/tmp/${PROJECT_PREFIX}-feedback"
mkdir -p "$FEEDBACK_DIR"

write_feedback() {
  local ticket="$1" agent="$2" verdict="$3" issues="$4"
  local file="${FEEDBACK_DIR}/${ticket}.txt"
  cat > "$file" <<FEOF
AGENT: ${agent}
VERDICT: ${verdict}
TIMESTAMP: $(date '+%Y-%m-%d %H:%M:%S')
ISSUES:
${issues}
FEOF
}

read_feedback() {
  local ticket="$1"
  local file="${FEEDBACK_DIR}/${ticket}.txt"
  if [[ -f "$file" ]]; then
    cat "$file"
  else
    echo ""
  fi
}

clear_feedback() {
  local ticket="$1"
  rm -f "${FEEDBACK_DIR}/${ticket}.txt"
}

# ─── Activity Log (daily narrative report) ──────────────────────────────────
REPORT_DIR="${SCRIPT_DIR}/../reports"
mkdir -p "$REPORT_DIR"

log_activity() {
  local agent="$1" ticket="$2" verdict="$3" description="$4"
  local report_file="${REPORT_DIR}/$(date +%Y-%m-%d).log"
  echo "$(date +%H:%M)|${agent}|${ticket}|${verdict}|${description}" >> "$report_file"
  # Also persist in per-ticket brief for cross-run memory
  local brief_file="${BRIEF_DIR:-/tmp/${PROJECT_PREFIX}-notes}/${ticket}.md"
  echo "$(date -u '+%H:%M UTC')│${agent}│${verdict}│${description}" >> "$brief_file" 2>/dev/null || true
}

# ─── Per-ticket Brief Memory ─────────────────────────────────────────────────
# Persistent notes across runs stored in /tmp/${PROJECT_PREFIX}-notes/BISB-XX.md.
# Agents read this at start (via TICKET_BRIEF_CONTEXT env var set by run-agent.sh)
# and key events are auto-appended via log_activity.
BRIEF_DIR="/tmp/${PROJECT_PREFIX}-notes"
mkdir -p "$BRIEF_DIR"

# Returns the contents of the brief file for a ticket (empty if none)
read_ticket_brief() {
  local ticket="$1"
  local brief_file="${BRIEF_DIR}/${ticket}.md"
  [[ -f "$brief_file" ]] && tail -40 "$brief_file" || true
}

# Appends a note to the brief file for a ticket
append_ticket_brief() {
  local ticket="$1" content="$2"
  local brief_file="${BRIEF_DIR}/${ticket}.md"
  {
    echo ""
    echo "---"
    echo "**$(date -u '+%Y-%m-%d %H:%M UTC')** | ${AGENT_NAME:-?}"
    echo "$content"
  } >> "$brief_file" 2>/dev/null || true
}

# ─── Model Selection ───────────────────────────────────────────────────────
# Select AI model based on ticket labels and priority.
# Priority: 1) model:X label override, 2) priority, 3) label heuristics, 4) default
select_model_for_ticket() {
  local labels="$1" priority="$2"
  # 1. Explicit label override (e.g. model:opus, model:haiku)
  if echo "$labels" | grep -qi "model:opus"; then echo "opus"; return; fi
  if echo "$labels" | grep -qi "model:haiku"; then echo "haiku"; return; fi
  # 2. Priority-based
  if [[ "$priority" == "Highest" ]]; then echo "sonnet"; return; fi
  # 3. Label heuristics
  if echo "$labels" | grep -qiE "infrastructure|devops|migration|security|legal"; then
    echo "sonnet"; return
  fi
  if echo "$labels" | grep -qiE "documentation|typo|config|cleanup"; then
    echo "haiku"; return
  fi
  # 4. Default
  echo "sonnet"
}

# ─── Sensitive File Detection ─────────────────────────────────────────────
# Returns 0 (true) if any file in the list matches agent-sensitive patterns.
# Usage: has_sensitive_files "file1\nfile2\nfile3"
has_sensitive_files() {
  local files="$1"
  if echo "$files" | grep -qE '^(ai/|n8n/scripts/agent-)'; then
    return 0  # true — sensitive files detected
  fi
  return 1  # false
}

# Upgrade model to opus if PR touches sensitive agent files.
# Usage: upgrade_model_for_sensitive_files CURRENT_MODEL "file1\nfile2"
upgrade_model_for_sensitive_files() {
  local model="$1" files="$2"
  if has_sensitive_files "$files"; then
    log_info "Sensitive agent files detected — upgrading model to opus"
    echo "opus"
  else
    echo "$model"
  fi
}

# ─── Feedback-Aware Model Selection ──────────────────────────────────────
# Escalates model based on retry count and feedback severity.
# Max escalation = Sonnet. Opus only via explicit model:opus label or sensitive files.
# Usage: select_model_with_feedback LABELS PRIORITY TICKET_KEY AGENT_NAME [BASE_MODEL]
select_model_with_feedback() {
  local labels="$1" priority="$2" ticket="$3" agent="$4" base_model="${5:-}"

  # 1. Start with base model (label/priority heuristics or provided default)
  local model="${base_model:-$(select_model_for_ticket "$labels" "$priority")}"

  # 2. Explicit label always wins — no escalation needed
  if echo "$labels" | grep -qi "model:opus\|model:haiku"; then
    echo "$model"
    return
  fi

  # 3. Check retry count
  local retries
  retries=$(get_retry_count "$ticket" "$agent")

  # 4. Check feedback severity
  local feedback
  feedback=$(read_feedback "$ticket")
  local has_critical=false
  local issue_count=0
  if [[ -n "$feedback" ]]; then
    issue_count=$(echo "$feedback" | grep -c "^- " 2>/dev/null || true)
    [[ -z "$issue_count" ]] && issue_count=0
    if echo "$feedback" | grep -qi "critical\|security\|vulnerability\|hardcoded.*secret\|data loss\|auth.*bypass"; then
      has_critical=true
    fi
  fi

  # 5. Escalation rules (max = sonnet, never auto-opus)
  local escalated=false
  if [[ "$has_critical" == "true" && "$model" == "haiku" ]]; then
    model="sonnet"; escalated=true
    log_info "Model escalated to sonnet (critical/security feedback)"
  elif (( retries > 0 )) && [[ "$model" == "haiku" ]]; then
    model="sonnet"; escalated=true
    log_info "Model escalated to sonnet (retry ${retries})"
  elif (( issue_count >= 5 )) && [[ "$model" == "haiku" ]]; then
    model="sonnet"; escalated=true
    log_info "Model escalated to sonnet (${issue_count} issues in feedback)"
  fi

  if [[ "$escalated" == "false" ]]; then
    log_info "Model: ${model} (no escalation needed)"
  fi

  echo "$model"
}

# ─── Sonnet Rate Limit Detection & Dual-Auth Fallback ─────────────────────────
# Three-tier fallback when Sonnet OAuth limit is hit:
#   Tier 1: OAuth Sonnet (free, subscription)
#   Tier 2: API Key Sonnet (paid, $4.79 credit, for critical work only)
#   Tier 3: OAuth Haiku (free, for non-critical work)
#
# The OAuth token has daily Sonnet caps. The API key draws from prepaid credit
# ($4.79 at ~$0.06/call ≈ 80 calls). This separation gives us a paid escape
# hatch for critical Youssef/Nadia work when the subscription cap is hit.
RATE_LIMIT_FLAG="/tmp/${PROJECT_PREFIX}-sonnet-rate-limited"
RATE_LIMIT_COOLDOWN=900  # 15 minutes

# API key budget: track spend to prevent blowing through the $4.79
API_KEY_BUDGET_FILE="/var/lib/${PROJECT_PREFIX}/data/api-key-spend.json"
API_KEY_BUDGET_MAX="${API_KEY_BUDGET_MAX:-4.50}"  # safety margin: stop at $4.50 of $4.79

is_sonnet_rate_limited() {
  [[ -f "$RATE_LIMIT_FLAG" ]] || return 1
  local age
  age=$(( $(date +%s) - $(stat -c %Y "$RATE_LIMIT_FLAG" 2>/dev/null || echo 0) ))
  if (( age > RATE_LIMIT_COOLDOWN )); then
    rm -f "$RATE_LIMIT_FLAG"
    log_info "Sonnet rate limit cooldown expired — cleared flag"
    return 1
  fi
  return 0
}

set_sonnet_rate_limited() {
  echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" > "$RATE_LIMIT_FLAG"
  log_info "Sonnet rate-limited — fallback active for ${RATE_LIMIT_COOLDOWN}s"
}

# Returns 0 (true) if Haiku fallback is allowed, 1 (false) if must use Sonnet.
can_fallback_to_haiku() {
  local agent="$1" task_type="${2:-general}"

  # Critical work: MUST use Sonnet/Opus, cannot fall back to Haiku
  case "${agent}:${task_type}" in
    youssef:dev)        return 1 ;;  # Implementation requires Sonnet
    nadia:sensitive)    return 1 ;;  # Sensitive file reviews need quality
    salma:split)        return 1 ;;  # Ticket splits are complex
    *)                  ;;
  esac

  # Non-critical agents: OK to fall back
  case "$agent" in
    layla|omar)   return 0 ;;
  esac

  case "$task_type" in
    ceremony|retro|summary|simple-spec|dm-response) return 0 ;;
    *) return 1 ;;  # Default: don't fall back (safety)
  esac
}

# Check if we have ANTHROPIC_API_KEY set and budget remaining.
has_api_key_budget() {
  # Must have an API key in environment
  [[ -n "${ANTHROPIC_API_KEY:-}" ]] || return 1

  # Check budget file
  if [[ -f "$API_KEY_BUDGET_FILE" ]]; then
    local spent
    spent=$(python3 -c "
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    print(d.get('total_estimated_usd', 0))
except: print(0)
" "$API_KEY_BUDGET_FILE" 2>/dev/null || echo "0")
    local budget_ok
    budget_ok=$(python3 -c "print('yes' if float('$spent') < float('$API_KEY_BUDGET_MAX') else 'no')" 2>/dev/null || echo "yes")
    if [[ "$budget_ok" != "yes" ]]; then
      log_info "API key budget exhausted: \$${spent} / \$${API_KEY_BUDGET_MAX}"
      return 1
    fi
  fi
  return 0
}

# Record estimated cost for an API key call.
# Sonnet: ~$3/MTok in + $15/MTok out. Estimate per call: $0.06
record_api_key_spend() {
  local model="${1:-sonnet}" duration="${2:-0}"
  local cost_estimate="0.06"  # conservative per-call estimate
  case "$model" in
    haiku) cost_estimate="0.005" ;;
    opus)  cost_estimate="0.30" ;;
    *)     cost_estimate="0.06" ;;
  esac

  mkdir -p "$(dirname "$API_KEY_BUDGET_FILE")" 2>/dev/null || true
  python3 -c "
import json, sys, os
from datetime import datetime
f = sys.argv[1]
cost = float(sys.argv[2])
try:
    d = json.load(open(f))
except:
    d = {'total_estimated_usd': 0, 'calls': 0, 'history': []}
d['total_estimated_usd'] = round(d.get('total_estimated_usd', 0) + cost, 4)
d['calls'] = d.get('calls', 0) + 1
d['history'].append({'ts': datetime.utcnow().isoformat() + 'Z', 'model': sys.argv[3], 'cost': cost})
# Keep only last 200 entries
d['history'] = d['history'][-200:]
d['last_updated'] = datetime.utcnow().isoformat() + 'Z'
json.dump(d, open(f, 'w'), indent=2)
" "$API_KEY_BUDGET_FILE" "$cost_estimate" "$model" 2>/dev/null || true
}

# ─── Direct Anthropic API Call (bypasses Claude CLI / OAuth) ──────────────────
# Uses ANTHROPIC_API_KEY for paid Sonnet access when OAuth subscription cap is hit.
# This is a simple prompt→response call (no tools, no multi-turn).
# For complex tool-using work, agents should use the claude CLI.
claude_api_direct() {
  local prompt="$1"
  local model="${2:-claude-sonnet-4-20250514}"
  local max_tokens="${3:-4096}"
  local system_prompt="${4:-}"

  [[ -n "${ANTHROPIC_API_KEY:-}" ]] || { log_error "claude_api_direct: no ANTHROPIC_API_KEY"; return 1; }

  local sys_block=""
  if [[ -n "$system_prompt" ]]; then
    sys_block="\"system\": $(python3 -c "import json; print(json.dumps('''$system_prompt'''))" 2>/dev/null || echo '""'),"
  fi

  local response
  response=$(curl -s --max-time 120 \
    https://api.anthropic.com/v1/messages \
    -H "Content-Type: application/json" \
    -H "x-api-key: ${ANTHROPIC_API_KEY}" \
    -H "anthropic-version: 2023-06-01" \
    -d "$(python3 -c "
import json, sys
prompt = sys.stdin.read()
payload = {
    'model': sys.argv[1],
    'max_tokens': int(sys.argv[2]),
    'messages': [{'role': 'user', 'content': prompt}]
}
sys_prompt = sys.argv[3] if len(sys.argv) > 3 and sys.argv[3] else ''
if sys_prompt:
    payload['system'] = sys_prompt
print(json.dumps(payload))
" "$model" "$max_tokens" "$system_prompt" <<< "$prompt" 2>/dev/null)" \
  2>/dev/null)

  local exit_code=$?

  # Check for errors
  if [[ $exit_code -ne 0 ]] || [[ -z "$response" ]]; then
    log_error "claude_api_direct: curl failed (exit=$exit_code)"
    return 1
  fi

  # Check for API errors
  local error_type
  error_type=$(echo "$response" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('error',{}).get('type',''))" 2>/dev/null || true)
  if [[ -n "$error_type" ]]; then
    log_error "claude_api_direct: API error: $error_type"
    if [[ "$error_type" == "rate_limit_error" ]]; then
      dep_set_down "claude" 2>/dev/null || true
    fi
    return 1
  fi

  # Extract text content
  local text
  text=$(echo "$response" | python3 -c "
import sys, json
d = json.load(sys.stdin)
for block in d.get('content', []):
    if block.get('type') == 'text':
        print(block['text'])
" 2>/dev/null)

  if [[ -z "$text" ]]; then
    log_error "claude_api_direct: empty response"
    return 1
  fi

  # Track spend
  record_api_key_spend "$model" 0

  echo "$text"
}

# 3-tier model selection with rate limit awareness.
# Returns: model name, "API_SONNET" (use claude_api_direct), or "WAIT".
#
# Tier 1: OAuth Sonnet → if not rate-limited, use it (free)
# Tier 2: API Sonnet   → if rate-limited + critical task + API key available ($$$)
# Tier 3: OAuth Haiku  → if rate-limited + non-critical task (free)
# WAIT:                → if rate-limited + critical + no API key
select_model_rate_aware() {
  local model="$1" agent="$2" task_type="${3:-general}"

  if [[ "$model" == "sonnet" ]] && is_sonnet_rate_limited; then
    if can_fallback_to_haiku "$agent" "$task_type"; then
      # Non-critical: Haiku is fine
      log_info "Sonnet rate-limited → Haiku fallback for ${agent}/${task_type}"
      echo "haiku"
    elif has_api_key_budget; then
      # Critical work + API key available: use paid Sonnet API
      log_info "Sonnet rate-limited → API key Sonnet for ${agent}/${task_type} (paid fallback)"
      event_log "${TICKET_KEY:-unknown}" "$agent" "api_key_fallback" "{\"task\":\"${task_type}\"}" 2>/dev/null || true
      echo "API_SONNET"
    else
      # Critical work + no API key: must wait
      log_info "Sonnet rate-limited → ${agent}/${task_type} must WAIT (no API key fallback)"
      echo "WAIT"
    fi
  else
    echo "$model"
  fi
}

# ─── Activate API Key Mode ────────────────────────────────────────────────────
# Call AFTER select_model_rate_aware when MODEL=API_SONNET.
# Sets ANTHROPIC_API_KEY so claude CLI uses the API key, resets MODEL to sonnet.
# Returns the effective model name.
#
# Usage in agent scripts:
#   MODEL=$(select_model_rate_aware "$MODEL" "youssef" "dev")
#   [[ "$MODEL" == "WAIT" ]] && exit 0
#   MODEL=$(activate_api_key_if_needed "$MODEL")
#   claude -p "..." --model "$MODEL" ...
activate_api_key_if_needed() {
  local model="$1"
  if [[ "$model" == "API_SONNET" ]]; then
    # Load the API key from env file (may not be exported yet)
    if [[ -z "${ANTHROPIC_API_KEY:-}" ]] && [[ -f "$ENV_FILE" ]]; then
      ANTHROPIC_API_KEY=$(grep '^ANTHROPIC_API_KEY=' "$ENV_FILE" 2>/dev/null | cut -d'=' -f2 | tr -d '"' | tr -d "'")
    fi
    if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
      export ANTHROPIC_API_KEY
      log_info "API key mode activated — claude CLI will use paid API key for Sonnet"
      echo "sonnet"
    else
      log_error "API_SONNET requested but no ANTHROPIC_API_KEY found — falling back to WAIT"
      echo "WAIT"
    fi
  else
    echo "$model"
  fi
}

# Wrapper around claude CLI that detects rate limits in stderr.
# Also detects the "You've hit your limit" message from subscription caps.
# Usage: claude_with_rate_check [claude args...]
claude_with_rate_check() {
  local stderr_tmp
  stderr_tmp=$(mktemp /tmp/${PROJECT_PREFIX}-claude-stderr-XXXXXX.txt)
  local rc=0
  claude "$@" 2>"$stderr_tmp" || rc=$?

  if grep -qi "rate.limit\|429\|overloaded\|too many requests\|quota exceeded\|hit your limit\|resets" "$stderr_tmp" 2>/dev/null; then
    set_sonnet_rate_limited
  fi

  cat "$stderr_tmp" >&2
  rm -f "$stderr_tmp"
  return $rc
}

# ─── Early-Stop on Repeat Failures ──────────────────────────────────────────
# Detects if the same failure signature repeats across retries.
# Returns 0 (true) if same failure, 1 (false) if different.
check_repeat_failure() {
  local ticket="$1" agent="$2" new_issues="$3"
  local prev_file="${FEEDBACK_DIR}/${ticket}-prev.txt"
  local curr_sig
  curr_sig=$(echo "$new_issues" | grep "^- " | sort | md5 2>/dev/null || echo "none")

  if [[ -f "$prev_file" ]]; then
    local prev_sig
    prev_sig=$(cat "$prev_file")
    if [[ "$curr_sig" == "$prev_sig" ]]; then
      log_info "Same failure signature detected for ${ticket}/${agent} — recommend blocking"
      return 0  # true = same failure
    fi
  fi

  echo "$curr_sig" > "$prev_file"
  return 1  # false = different failure
}

# ─── Jira Subtask Creation ────────────────────────────────────────────────
# Create a subtask under a parent ticket, assigned to the current user (Hedi).
# Usage: jira_create_subtask PARENT_KEY "Summary" "Description"
jira_create_subtask() {
  local parent_key="$1" summary="$2" description="$3"
  local account_id
  account_id=$("${SCRIPT_DIR}/jira-curl.sh" -X GET \
    "${JIRA_BASE_URL}/rest/api/3/myself" \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('accountId',''))" 2>/dev/null)

  # Escape strings for JSON
  local json_summary json_desc
  json_summary=$(python3 -c "import json; print(json.dumps('''${summary}'''))")
  json_desc=$(python3 -c "import json; print(json.dumps('''${description}'''))")

  "${SCRIPT_DIR}/jira-curl.sh" -s -X POST \
    -H "Authorization: Basic $(jira_auth)" \
    -H "Content-Type: application/json" \
    "${JIRA_BASE_URL}/rest/api/3/issue" \
    -d "{
      \"fields\": {
        \"project\": {\"key\": \"${JIRA_PROJECT}\"},
        \"parent\": {\"key\": \"${parent_key}\"},
        \"summary\": ${json_summary},
        \"description\": {\"type\":\"doc\",\"version\":1,\"content\":[{\"type\":\"paragraph\",\"content\":[{\"type\":\"text\",\"text\":${json_desc}}]}]},
        \"issuetype\": {\"name\": \"Subtask\"},
        \"assignee\": {\"accountId\": \"${account_id}\"}
      }
    }" | python3 -c "import sys,json; print(json.load(sys.stdin).get('key',''))" 2>/dev/null
}

# ─── Idempotent Human Subtask ──────────────────────────────────────────────
# Creates a subtask only if one with the same prefix doesn't already exist.
# Prevents duplicate subtasks on re-runs.
# Usage: create_human_subtask PARENT_KEY AGENT_NAME "Summary" "Description"
create_human_subtask() {
  local parent_key="$1" agent="$2" summary="$3" description="$4"
  local prefix="[HUMAN][${agent}]"

  # Check if subtask already exists (search by summary prefix under parent)
  local existing
  existing=$("${SCRIPT_DIR}/jira-curl.sh" -s -X POST \
    -H "Authorization: Basic $(jira_auth)" \
    -H "Content-Type: application/json" \
    "${JIRA_BASE_URL}/rest/api/3/search/jql" \
    -d "{\"jql\":\"parent = ${parent_key} AND summary ~ \\\"${prefix}\\\" AND statusCategory != Done\",\"fields\":[\"key\"],\"maxResults\":1}" \
    | python3 -c "import sys,json; issues=json.load(sys.stdin).get('issues',[]); print(issues[0]['key'] if issues else '')" 2>/dev/null)

  if [[ -n "$existing" ]]; then
    log_info "Human subtask already exists: ${existing} — updating comment instead"
    jira_add_comment "$existing" "${agent}: Updated — ${description}"
    echo "$existing"
    return
  fi

  # Create new subtask
  local subtask_key
  subtask_key=$(jira_create_subtask "$parent_key" "${prefix} ${summary}" "$description")
  if [[ -n "$subtask_key" ]]; then
    log_info "Created human subtask: ${subtask_key}"
  fi
  echo "$subtask_key"
}

# ─── Jira Label Helpers ─────────────────────────────────────────────────────
# Remove a specific label from a ticket
jira_remove_label() {
  local key="$1" label="$2"
  "${SCRIPT_DIR}/jira-curl.sh" -s -X PUT \
    -H "Authorization: Basic $(jira_auth)" \
    -H "Content-Type: application/json" \
    "${JIRA_BASE_URL}/rest/api/3/issue/${key}" \
    -d "{\"update\":{\"labels\":[{\"remove\":\"${label}\"}]}}" > /dev/null 2>&1
}

# ─── Jira Ticket Creation (for Salma splits) ──────────────────────────────
# Create a new standalone ticket (not subtask)
jira_create_ticket() {
  local summary="$1" description="$2" parent_ref="$3"
  local json_summary json_desc
  json_summary=$(python3 -c "import json,sys; print(json.dumps(sys.argv[1]))" "$summary")
  json_desc=$(python3 -c "import json,sys; print(json.dumps(sys.argv[1]))" "$description")

  "${SCRIPT_DIR}/jira-curl.sh" -s -X POST \
    -H "Authorization: Basic $(jira_auth)" \
    -H "Content-Type: application/json" \
    "${JIRA_BASE_URL}/rest/api/3/issue" \
    -d "{
      \"fields\": {
        \"project\": {\"key\": \"${JIRA_PROJECT}\"},
        \"summary\": ${json_summary},
        \"description\": {\"type\":\"doc\",\"version\":1,\"content\":[{\"type\":\"paragraph\",\"content\":[{\"type\":\"text\",\"text\":${json_desc}}]}]},
        \"issuetype\": {\"name\": \"Task\"},
        \"labels\": [\"split-from:${parent_ref}\"]
      }
    }" | python3 -c "import sys,json; print(json.load(sys.stdin).get('key',''))" 2>/dev/null
}

# ─── Sprint Management ───────────────────────────────────────────────────

# Get the active sprint ID for the project board
jira_get_active_sprint_id() {
  "${SCRIPT_DIR}/jira-curl.sh" -s -X GET \
    -H "Authorization: Basic $(jira_auth)" \
    "${JIRA_BASE_URL}/rest/agile/1.0/board/34/sprint?state=active,future" \
    | python3 -c "import sys,json; sprints=json.load(sys.stdin).get('values',[]); active=[s for s in sprints if s['state']=='active']; future=[s for s in sprints if s['state']=='future']; s=active[0] if active else (future[0] if future else None); print(s['id'] if s else '')" 2>/dev/null
}

# Move an issue into a sprint
# Usage: jira_move_to_sprint ISSUE_KEY SPRINT_ID
jira_move_to_sprint() {
  local key="$1" sprint_id="$2"
  if [[ -z "$sprint_id" ]]; then
    log_error "No sprint ID provided for ${key}"
    return 1
  fi
  "${SCRIPT_DIR}/jira-curl.sh" -s -X POST \
    -H "Authorization: Basic $(jira_auth)" \
    -H "Content-Type: application/json" \
    "${JIRA_BASE_URL}/rest/agile/1.0/sprint/${sprint_id}/issue" \
    -d "{\"issues\":[\"${key}\"]}" > /dev/null 2>&1
  log_info "Moved ${key} to sprint ${sprint_id}"
}

# ─── Sprint Ceremony Functions ──────────────────────────────────────────────

jira_close_sprint() {
  local sprint_id="$1"
  if [[ -z "$sprint_id" ]]; then
    log_error "No sprint ID provided for close"
    return 1
  fi
  local end_date
  end_date=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)
  "${SCRIPT_DIR}/jira-curl.sh" -s -X POST \
    -H "Authorization: Basic $(jira_auth)" \
    -H "Content-Type: application/json" \
    "${JIRA_BASE_URL}/rest/agile/1.0/sprint/${sprint_id}" \
    -d "{\"state\":\"closed\",\"completeDate\":\"${end_date}\"}" > /dev/null 2>&1
  log_info "Sprint ${sprint_id} closed"
}

jira_create_sprint() {
  local name="$1" goal="${2:-}"
  local start_date end_date
  start_date=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)
  end_date=$(date -u -d "+7 days" +%Y-%m-%dT%H:%M:%S.000Z)
  local json_payload
  json_payload=$(python3 -c "
import json, sys
d = {'name': sys.argv[1], 'originBoardId': 34, 'startDate': sys.argv[2], 'endDate': sys.argv[3]}
if sys.argv[4]: d['goal'] = sys.argv[4]
print(json.dumps(d))
" "$name" "$start_date" "$end_date" "$goal")
  local response
  response=$("${SCRIPT_DIR}/jira-curl.sh" -s -X POST \
    -H "Authorization: Basic $(jira_auth)" \
    -H "Content-Type: application/json" \
    "${JIRA_BASE_URL}/rest/agile/1.0/sprint" \
    -d "$json_payload")
  echo "$response" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null
}

jira_start_sprint() {
  local sprint_id="$1"
  if [[ -z "$sprint_id" ]]; then
    log_error "No sprint ID provided for start"
    return 1
  fi
  local start_date end_date
  start_date=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)
  end_date=$(date -u -d "+7 days" +%Y-%m-%dT%H:%M:%S.000Z)
  local json_payload
  json_payload=$(python3 -c "
import json, sys
d = {'state': 'active', 'startDate': sys.argv[1], 'endDate': sys.argv[2]}
print(json.dumps(d))
" "$start_date" "$end_date")
  "${SCRIPT_DIR}/jira-curl.sh" -s -X POST \
    -H "Authorization: Basic $(jira_auth)" \
    -H "Content-Type: application/json" \
    "${JIRA_BASE_URL}/rest/agile/1.0/sprint/${sprint_id}" \
    -d "$json_payload" > /dev/null 2>&1
  log_info "Sprint ${sprint_id} started"
}

jira_get_backlog_tickets() {
  local limit="${1:-10}"
  local jql="project = ${JIRA_PROJECT} AND sprint is EMPTY AND statusCategory != 'Done' AND labels NOT IN ('blocked','needs-human-review') ORDER BY priority DESC, created ASC"
  jira_search_keys_with_summaries "$jql" "$limit"
}

jira_get_sprint_number() {
  local sprint_id="$1"
  "${SCRIPT_DIR}/jira-curl.sh" -s \
    -H "Authorization: Basic $(jira_auth)" \
    "${JIRA_BASE_URL}/rest/agile/1.0/sprint/${sprint_id}" | \
    python3 -c "
import sys, json, re
data = json.load(sys.stdin)
name = data.get('name', '')
match = re.search(r'Sprint\s+(\d+)', name)
print(match.group(1) if match else '0')
" 2>/dev/null
}


# ─── Jira Description Update ──────────────────────────────────────────────

# Simple text description update
jira_update_description() {
  local key="$1" description="$2"
  local json_desc
  json_desc=$(python3 -c "import json,sys; print(json.dumps(sys.argv[1]))" "$description")
  "${SCRIPT_DIR}/jira-curl.sh" -s -X PUT \
    -H "Authorization: Basic $(jira_auth)" \
    -H "Content-Type: application/json" \
    "${JIRA_BASE_URL}/rest/api/3/issue/${key}" \
    -d "{\"fields\":{\"description\":{\"type\":\"doc\",\"version\":1,\"content\":[{\"type\":\"paragraph\",\"content\":[{\"type\":\"text\",\"text\":${json_desc}}]}]}}}" > /dev/null 2>&1
}

# Rich ADF description update (supports markdown-like text → ADF conversion)
# Usage: jira_update_description_adf KEY "ADF_JSON_STRING"
# The ADF must be a valid Atlassian Document Format JSON object
jira_update_description_adf() {
  local key="$1" adf_json="$2"
  "${SCRIPT_DIR}/jira-curl.sh" -s -X PUT \
    -H "Authorization: Basic $(jira_auth)" \
    -H "Content-Type: application/json" \
    "${JIRA_BASE_URL}/rest/api/3/issue/${key}" \
    -d "{\"fields\":{\"description\":${adf_json}}}" > /dev/null 2>&1
}

# Update a single Jira field (e.g., story points, assignee, etc.)
# Usage: jira_update_field KEY FIELD_NAME VALUE
# Example: jira_update_field "BISB-123" "customfield_10016" "5"
jira_update_field() {
  local key="$1" field_name="$2" value="$3"
  "${SCRIPT_DIR}/jira-curl.sh" -s -X PUT \
    -H "Authorization: Basic $(jira_auth)" \
    -H "Content-Type: application/json" \
    "${JIRA_BASE_URL}/rest/api/3/issue/${key}" \
    -d "{\"fields\":{\"${field_name}\":${value}}}" > /dev/null 2>&1
}

# Convert markdown-like spec text to rich ADF with agent-colored panels
# Usage: jira_set_spec KEY AGENT_NAME "SPEC_TEXT"
# AGENT_NAME determines panel color: salma=info(blue), youssef=success(green),
# nadia=error(red), karim=warning(orange)
jira_set_spec() {
  local key="$1" agent="$2" spec_text="$3"

  local panel_type="info"
  case "$agent" in
    salma)   panel_type="info" ;;     # blue
    youssef) panel_type="success" ;;  # green
    nadia)   panel_type="error" ;;    # red
    rami)    panel_type="info" ;;     # blue
    *)       panel_type="note" ;;     # purple
  esac

  local agent_display="${AGENT_SLACK_USERNAME[$agent]:-$agent}"

  # Build ADF using python (handles escaping properly)
  local adf_json
  adf_json=$(python3 -c "
import json, sys

spec_text = sys.argv[1]
agent_display = sys.argv[2]
panel_type = sys.argv[3]

# Parse spec_text into ADF content blocks
lines = spec_text.strip().split('\n')
content_blocks = []

for line in lines:
    stripped = line.strip()
    if not stripped:
        continue
    elif stripped.startswith('## '):
        content_blocks.append({
            'type': 'heading', 'attrs': {'level': 2},
            'content': [{'type': 'text', 'text': stripped[3:]}]
        })
    elif stripped.startswith('### '):
        content_blocks.append({
            'type': 'heading', 'attrs': {'level': 3},
            'content': [{'type': 'text', 'text': stripped[4:]}]
        })
    elif stripped.startswith('- [ ] ') or stripped.startswith('- [x] '):
        # Checkbox item — add as bullet with status prefix
        checked = stripped.startswith('- [x] ')
        text = stripped[6:]
        prefix = '✅ ' if checked else '☐ '
        content_blocks.append({
            'type': 'paragraph',
            'content': [{'type': 'text', 'text': prefix + text}]
        })
    elif stripped.startswith('- '):
        content_blocks.append({
            'type': 'paragraph',
            'content': [{'type': 'text', 'text': '• ' + stripped[2:]}]
        })
    else:
        content_blocks.append({
            'type': 'paragraph',
            'content': [{'type': 'text', 'text': stripped}]
        })

# Wrap in panel
doc = {
    'type': 'doc',
    'version': 1,
    'content': [
        {
            'type': 'panel',
            'attrs': {'panelType': panel_type},
            'content': [
                {
                    'type': 'heading', 'attrs': {'level': 3},
                    'content': [
                        {'type': 'text', 'text': agent_display, 'marks': [{'type': 'strong'}]}
                    ]
                }
            ] + content_blocks
        }
    ]
}

print(json.dumps(doc))
" "$spec_text" "$agent_display" "$panel_type" 2>/dev/null)

  if [[ -n "$adf_json" ]]; then
    jira_update_description_adf "$key" "$adf_json"
    log_info "Updated description for ${key} with ${agent} spec (${panel_type} panel)"
  else
    log_error "Failed to generate ADF for ${key}"
    # Fallback to plain text
    jira_update_description "$key" "$spec_text"
  fi
}

# ─── Cooldown Check ─────────────────────────────────────────────────────────
COOLDOWN_SECONDS=900  # 15 minutes — matches cron interval

check_cooldown() {
  local ticket="$1" agent="$2"
  local file="${RETRY_DIR}/${ticket}-${agent}"
  if [[ -f "$file" ]]; then
    local age=$(( $(date +%s) - $(stat -c %Y "$file" 2>/dev/null || stat -f %m "$file" 2>/dev/null || echo 0) ))
    if (( age < COOLDOWN_SECONDS )); then
      log_info "Cooldown active for ${ticket}/${agent} (${age}s < ${COOLDOWN_SECONDS}s). Skipping."
      return 1
    fi
  fi
  return 0
}

# ─── Layla Report Access ─────────────────────────────────────────────────────
# Returns Layla's latest daily market intelligence report if it exists and
# was generated today or yesterday (still relevant).
get_layla_report() {
  local report_file="/tmp/${PROJECT_PREFIX}-layla-latest-report.md"
  local date_file="/tmp/${PROJECT_PREFIX}-layla-latest-report-date.txt"
  if [[ -f "$report_file" && -f "$date_file" ]]; then
    local report_date
    report_date=$(cat "$date_file")
    local today
    today=$(date -u +%Y-%m-%d)
    local yesterday
    yesterday=$(date -u -d "yesterday" +%Y-%m-%d 2>/dev/null || date -u -v-1d +%Y-%m-%d 2>/dev/null || echo "")
    if [[ "$report_date" == "$today" || "$report_date" == "$yesterday" ]]; then
      echo "## Latest Market Intelligence (${report_date})"
      head -100 "$report_file"
    fi
  fi
}

# ─── Hedi Message Access ────────────────────────────────────────────────────
# Returns any pending messages from Hedi for a specific agent.
# Messages are stored in /tmp/${PROJECT_PREFIX}-hedi-messages/{agent}-{timestamp}.md
# Usage: get_hedi_messages "nadia"
get_hedi_messages() {
  local agent_name="$1"
  local msg_dir="/tmp/${PROJECT_PREFIX}-hedi-messages"
  [[ -d "$msg_dir" ]] || return 0

  local found=false
  for msg_file in "${msg_dir}/${agent_name}"-*.md; do
    [[ -f "$msg_file" ]] || continue
    if [[ "$found" == "false" ]]; then
      echo "## Messages from Hedi"
      found=true
    fi
    echo "---"
    cat "$msg_file"
    echo ""
    # Archive after reading (move to .read suffix)
    mv "$msg_file" "${msg_file}.read" 2>/dev/null || true
  done
}


# ─── Verdict Parser ──────────────────────────────────────────────────────────
# Strips markdown bold (**) from Claude's verdict output, returns clean uppercase verdict
# Usage: VERDICT=$(parse_verdict "$output_file")
parse_verdict() {
  local output_file="$1"
  local raw
  raw=$(grep -oiP 'VERDICT:\s*\**\s*\w[\w_]*' "$output_file" | head -1) || true
  if [[ -z "$raw" ]]; then
    echo "UNKNOWN"
    return
  fi
  local verdict
  verdict=$(echo "$raw" | sed 's/\*//g; s/[Vv][Ee][Rr][Dd][Ii][Cc][Tt]:\s*//; s/^[[:space:]]*//; s/[[:space:]]*$//' | tr '[:lower:]' '[:upper:]')
  # Normalize non-standard verdicts to PASS/FAIL
  case "$verdict" in
    PASS*) echo "PASS" ;;
    FAIL*|EXCEED*|REJECT*|BLOCK*) echo "FAIL" ;;
    *) echo "$verdict" ;;
  esac
}

# ─── Initialization ──────────────────────────────────────────────────────────
load_env

# ─── Project Config Loader (multi-project support) ─────────────────────────
# Reads .agent-config.json from PROJECT_DIR for project-specific settings.
# Falls back to env vars if config file doesn't exist (backward compatible).
PROJECT_CONFIG_FILE="${PROJECT_DIR:-.}/.agent-config.json"
PROJECT_KEY="${JIRA_PROJECT:-BISB}"
PROJECT_NAME=""
PROJECT_REPO="${GITHUB_REPO:-}"
PROJECT_DOMAIN=""
PROJECT_DOMAIN_CONTEXT=""
PROJECT_TEST_CMD=""
PROJECT_BUILD_CMD=""
PROJECT_LINT_CMD=""
PROJECT_TYPECHECK_CMD=""
PROJECT_QA_RULES=""
PROJECT_ARCH_RULES=""
PROJECT_GAME_RULES=""
PROJECT_MAX_PR_LINES=300
PROJECT_BUDGET_DAILY=150
PROJECT_CAPACITY=1.0

load_project_config() {
  if [[ ! -f "$PROJECT_CONFIG_FILE" ]]; then
    log_info "No .agent-config.json found, using env defaults"
    return 0
  fi
  PROJECT_KEY=$(python3 -c "import json; d=json.load(open('$PROJECT_CONFIG_FILE')); print(d.get('project_key','$PROJECT_KEY'))" 2>/dev/null || echo "$PROJECT_KEY")
  PROJECT_NAME=$(python3 -c "import json; d=json.load(open('$PROJECT_CONFIG_FILE')); print(d.get('name',''))" 2>/dev/null || echo "")
  PROJECT_REPO=$(python3 -c "import json; d=json.load(open('$PROJECT_CONFIG_FILE')); print(d.get('repo','$PROJECT_REPO'))" 2>/dev/null || echo "$PROJECT_REPO")
  BASE_BRANCH=$(python3 -c "import json; d=json.load(open('$PROJECT_CONFIG_FILE')); print(d.get('base_branch','$BASE_BRANCH'))" 2>/dev/null || echo "$BASE_BRANCH")
  PROJECT_DOMAIN=$(python3 -c "import json; d=json.load(open('$PROJECT_CONFIG_FILE')); print(d.get('domain',''))" 2>/dev/null || echo "")
  PROJECT_DOMAIN_CONTEXT=$(python3 -c "import json; d=json.load(open('$PROJECT_CONFIG_FILE')); print(d.get('domain_context',''))" 2>/dev/null || echo "")
  PROJECT_TEST_CMD=$(python3 -c "import json; d=json.load(open('$PROJECT_CONFIG_FILE')); print(d.get('stack',{}).get('test',''))" 2>/dev/null || echo "")
  PROJECT_BUILD_CMD=$(python3 -c "import json; d=json.load(open('$PROJECT_CONFIG_FILE')); print(d.get('stack',{}).get('build',''))" 2>/dev/null || echo "")
  PROJECT_LINT_CMD=$(python3 -c "import json; d=json.load(open('$PROJECT_CONFIG_FILE')); print(d.get('stack',{}).get('lint',''))" 2>/dev/null || echo "")
  PROJECT_TYPECHECK_CMD=$(python3 -c "import json; d=json.load(open('$PROJECT_CONFIG_FILE')); print(d.get('stack',{}).get('typecheck',''))" 2>/dev/null || echo "")
  PROJECT_QA_RULES=$(python3 -c "import json; d=json.load(open('$PROJECT_CONFIG_FILE')); print(d.get('qa_rules',''))" 2>/dev/null || echo "")
  PROJECT_ARCH_RULES=$(python3 -c "import json; d=json.load(open('$PROJECT_CONFIG_FILE')); print(d.get('architecture_rules',''))" 2>/dev/null || echo "")
  PROJECT_GAME_RULES=$(python3 -c "import json; d=json.load(open('$PROJECT_CONFIG_FILE')); print(d.get('game_rules',''))" 2>/dev/null || echo "")
  PROJECT_MAX_PR_LINES=$(python3 -c "import json; d=json.load(open('$PROJECT_CONFIG_FILE')); print(d.get('max_pr_lines',300))" 2>/dev/null || echo "300")
  PROJECT_BUDGET_DAILY=$(python3 -c "import json; d=json.load(open('$PROJECT_CONFIG_FILE')); print(d.get('cost_budget_daily_calls',150))" 2>/dev/null || echo "150")
  PROJECT_CAPACITY=$(python3 -c "import json; d=json.load(open('$PROJECT_CONFIG_FILE')); print(d.get('capacity_allocation',1.0))" 2>/dev/null || echo "1.0")
  # Override JIRA_PROJECT with config value for all downstream Jira queries
  JIRA_PROJECT="$PROJECT_KEY"
  log_info "Loaded project config: ${PROJECT_KEY} (${PROJECT_NAME:-unnamed})"
}

load_project_config

# ─── Tracker/Chat Backend Abstraction ──────────────────────────────────────
# No-op stubs for Plane-only functions — overridden by tracker-common.sh when TRACKER_BACKEND=plane
plane_set_assignee() { :; }
plane_set_state() { :; }
plane_update_state() { :; }
plane_get_assigned_tickets() { :; }
jira_set_state() { jira_transition "$1" "$2" 2>/dev/null || true; }

# Source tracker-common.sh to override jira_*/slack_notify with Plane/Mattermost
# when TRACKER_BACKEND=plane or CHAT_BACKEND=mattermost is set.
if [[ -f "${SCRIPT_DIR}/tracker-common.sh" ]]; then
  source "${SCRIPT_DIR}/tracker-common.sh"
fi

# ─── Isolated Git Workspace (worktree-based) ──────────────────────────────
# Each agent works in its own worktree — no branch conflicts
WORKTREE_BASE="${PROJECT_DIR:-/opt/bisb}-worktrees"
mkdir -p "$WORKTREE_BASE"

prepare_isolated_workspace() {
  local ticket="$1" branch="$2"
  local worktree_path="${WORKTREE_BASE}/${branch}"

  # Ensure parent directory exists (branch may contain / e.g. feature/XXX)
  mkdir -p "$(dirname "$worktree_path")"

  # Clean up stale worktree
  if [[ -d "$worktree_path" ]]; then
    cd "$PROJECT_DIR"
    git worktree remove "$worktree_path" --force >/dev/null 2>&1 || rm -rf "$worktree_path"
  fi
  cd "$PROJECT_DIR"
  git worktree prune >/dev/null 2>&1
  git fetch origin >/dev/null 2>&1 || true
  
  # Delete local branch if it exists (worktree needs to create it fresh)
  git branch -D "$branch" >/dev/null 2>&1 || true
  
  # Create worktree
  if git ls-remote --heads origin "$branch" 2>/dev/null | grep -q "$branch"; then
    git worktree add "$worktree_path" -b "$branch" "origin/$branch" >/dev/null 2>&1
  else
    git worktree add "$worktree_path" -b "$branch" "origin/${BASE_BRANCH}" >/dev/null 2>&1
  fi
  
  if [[ ! -d "$worktree_path" ]]; then
    log_info "Worktree creation failed, falling back to main repo" >&2
    echo "$PROJECT_DIR"
    return
  fi
  
  cd "$worktree_path"
  if [[ ! -d "node_modules" ]]; then
    npm install --prefer-offline >/dev/null 2>&1 || true
  fi

  # Clean stale compiled files from engine/src — vitest imports .js over .ts
  # causing tests to run against old master code instead of branch source
  find "$worktree_path/packages/engine/src" \( -name '*.js' -o -name '*.d.ts' -o -name '*.js.map' -o -name '*.d.ts.map' \) -delete 2>/dev/null || true

  log_info "Working in isolated worktree: $worktree_path" >&2
  echo "$worktree_path"
}


cleanup_worktree() {
  local worktree_path="$1"
  if [[ -d "$worktree_path" ]]; then
    cd "$PROJECT_DIR" && git worktree remove "$worktree_path" --force 2>/dev/null || true
  fi
}

# ─── Shared Memory System ──────────────────────────────────────────────────
# Persistent structured data store (replaces /tmp ephemeral files)
# Stores: agent context, sprint metrics, cost tracking, decision logs
DATA_DIR="${PROJECT_DIR:-/opt/bisb}/data"

init_shared_memory() {
  local pk="${PROJECT_KEY,,}"  # lowercase
  mkdir -p "${DATA_DIR}/context/projects/${pk}"
  mkdir -p "${DATA_DIR}/sprints/history"
  mkdir -p "${DATA_DIR}/agents"/{salma,youssef,nadia,omar,layla,rami}
  mkdir -p "${DATA_DIR}/tickets"
  mkdir -p "${DATA_DIR}/costs/daily"
  mkdir -p "${DATA_DIR}/costs/sprint"
  mkdir -p "${DATA_DIR}/metrics"
  mkdir -p "${DATA_DIR}/messages/inbox"/{salma,youssef,nadia,omar,layla,rami}
}

# Initialize shared memory dirs (silent, idempotent)
init_shared_memory 2>/dev/null || true

# Write a decision to the project decision log (append-only JSONL)
log_decision() {
  local agent="$1" ticket="$2" decision="$3" reason="$4"
  local ts
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  echo "{\"ts\":\"${ts}\",\"agent\":\"${agent}\",\"ticket\":\"${ticket}\",\"decision\":\"${decision}\",\"reason\":$(python3 -c "import json,sys; print(json.dumps(sys.argv[1]))" "$reason")}" \
    >> "${DATA_DIR}/context/projects/${PROJECT_KEY,,}/decisions.jsonl" 2>/dev/null || true
}

# Update agent's last activity (for real standup reports)
update_agent_activity() {
  local agent="$1" ticket="$2" action="$3" detail="$4"
  local ts
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  local activity_file="${DATA_DIR}/agents/${agent}/last-activity.json"
  python3 -c "
import json, sys
d = {
    'timestamp': sys.argv[1],
    'ticket': sys.argv[2],
    'action': sys.argv[3],
    'detail': sys.argv[4]
}
print(json.dumps(d, indent=2))
" "$ts" "$ticket" "$action" "$detail" > "$activity_file" 2>/dev/null || true
}

# Read ticket feedback from shared memory (with fallback to /tmp)
read_ticket_data() {
  local ticket="$1" field="$2"
  local data_file="${DATA_DIR}/tickets/${ticket}/${field}.json"
  if [[ -f "$data_file" ]]; then
    cat "$data_file"
  fi
}

# Write ticket data to shared memory
write_ticket_data() {
  local ticket="$1" field="$2" data="$3"
  local ticket_dir="${DATA_DIR}/tickets/${ticket}"
  mkdir -p "$ticket_dir"
  echo "$data" > "${ticket_dir}/${field}.json"
}

# Append to ticket history (JSONL)
append_ticket_history() {
  local ticket="$1" agent="$2" action="$3" detail="$4"
  local ticket_dir="${DATA_DIR}/tickets/${ticket}"
  mkdir -p "$ticket_dir"
  local ts
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  echo "{\"ts\":\"${ts}\",\"agent\":\"${agent}\",\"action\":\"${action}\",\"detail\":$(python3 -c "import json,sys; print(json.dumps(sys.argv[1]))" "$detail")}" \
    >> "${ticket_dir}/history.jsonl" 2>/dev/null || true
}

# ─── Token Budget Tracking (Claude Max) ──────────────────────────────────
# Wraps claude CLI calls with usage tracking per 5-hour rolling window.
# Records: model, tokens in/out, agent, ticket, window consumption.
#
# Usage: claude_with_tracking AGENT TICKET MODEL MAX_TURNS [EXTRA_ARGS...]
#   Reads prompt from stdin (pipe-friendly).
#   Outputs Claude's response to stdout.
#   Logs token usage to /opt/bisb/data/costs/daily/YYYY-MM-DD.json
#
# Example:
#   echo "$PROMPT" | claude_with_tracking "youssef" "BISB-42" "sonnet" 30 --allowedTools "Read Write Edit"
claude_with_tracking() {
  local agent="$1" ticket="$2" model="$3" max_turns="${4:-15}"
  shift 4  # remaining args passed to claude

  local start_time
  start_time=$(date +%s)
  local today
  today=$(date -u +%Y-%m-%d)
  local cost_file="${DATA_DIR}/costs/daily/${today}.json"

  # Build claude command args
  local claude_args=(-p --model "$model" --max-turns "$max_turns")
  # Append any extra args (--allowedTools, --disallowedTools, etc.)
  claude_args+=("$@")

  # Run claude, capture output and exit code
  local output_file
  output_file=$(mktemp /tmp/${PROJECT_PREFIX}-claude-output-XXXXXX)
  local exit_code=0

  claude "${claude_args[@]}" > "$output_file" 2>/dev/null || exit_code=$?

  local end_time
  end_time=$(date +%s)
  local duration=$(( end_time - start_time ))

  # Output the result to stdout
  cat "$output_file"

  # Record usage (append to daily cost file)
  python3 -c "
import json, sys, os
from datetime import datetime, timezone

cost_file = sys.argv[1]
agent = sys.argv[2]
ticket = sys.argv[3]
model = sys.argv[4]
duration = int(sys.argv[5])
exit_code = int(sys.argv[6])

# Load existing daily data
data = {'date': sys.argv[7], 'entries': [], 'totals': {}}
if os.path.exists(cost_file):
    try:
        with open(cost_file) as f:
            data = json.load(f)
    except:
        pass

# Estimate tokens from output size (rough: 1 token ~ 4 chars)
output_size = 0
try:
    output_size = os.path.getsize(sys.argv[8])
except:
    pass
estimated_output_tokens = output_size // 4

# Add entry
entry = {
    'ts': datetime.now(timezone.utc).isoformat(),
    'agent': agent,
    'ticket': ticket,
    'model': model,
    'duration_seconds': duration,
    'estimated_output_tokens': estimated_output_tokens,
    'exit_code': exit_code
}
data.setdefault('entries', []).append(entry)

# Update totals
totals = data.setdefault('totals', {})
agent_totals = totals.setdefault(agent, {'calls': 0, 'total_duration': 0, 'estimated_tokens': 0})
agent_totals['calls'] += 1
agent_totals['total_duration'] += duration
agent_totals['estimated_tokens'] += estimated_output_tokens

with open(cost_file, 'w') as f:
    json.dump(data, f, indent=2)
" "$cost_file" "$agent" "$ticket" "$model" "$duration" "$exit_code" "$today" "$output_file" 2>/dev/null || true

  # Update agent activity
  update_agent_activity "$agent" "$ticket" "claude_call" "model=${model} duration=${duration}s exit=${exit_code}"

  # Cleanup
  rm -f "$output_file"
  return $exit_code
}

# Get current daily token budget usage summary
get_budget_status() {
  local today
  today=$(date -u +%Y-%m-%d)
  local cost_file="${DATA_DIR}/costs/daily/${today}.json"
  if [[ -f "$cost_file" ]]; then
    python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
totals = data.get('totals', {})
total_calls = sum(t.get('calls', 0) for t in totals.values())
total_duration = sum(t.get('total_duration', 0) for t in totals.values())
print(f'Calls today: {total_calls}, Total duration: {total_duration}s')
for agent, t in sorted(totals.items()):
    print(f'  {agent}: {t[\"calls\"]} calls, {t[\"total_duration\"]}s')
" "$cost_file" 2>/dev/null
  else
    echo "No usage data for today"
  fi
}

# ─── Agent Messaging System ──────────────────────────────────────────────
# Send a direct message to another agent's inbox
# Usage: send_agent_message FROM TO TICKET TYPE "content"
send_agent_message() {
  local from="$1" to="$2" ticket="$3" msg_type="$4" content="$5"
  local inbox_dir="${DATA_DIR}/messages/inbox/${to}"
  mkdir -p "$inbox_dir"
  local msg_id="msg-$(date +%s)-$$"
  local ts
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  python3 -c "
import json, sys
msg = {
    'id': sys.argv[1],
    'from': sys.argv[2],
    'to': sys.argv[3],
    'ticket': sys.argv[4],
    'type': sys.argv[5],
    'content': sys.argv[6],
    'created': sys.argv[7],
    'read': False
}
print(json.dumps(msg, indent=2))
" "$msg_id" "$from" "$to" "$ticket" "$msg_type" "$content" "$ts" > "${inbox_dir}/${msg_id}.json" 2>/dev/null || true
  log_info "Message sent: ${from} -> ${to} [${msg_type}] re: ${ticket}"
}

# Read all unread messages for an agent
# Usage: read_agent_messages AGENT_NAME
read_agent_messages() {
  local agent="$1"
  local inbox_dir="${DATA_DIR}/messages/inbox/${agent}"
  [[ -d "$inbox_dir" ]] || return 0

  local found=false
  for msg_file in "${inbox_dir}"/msg-*.json; do
    [[ -f "$msg_file" ]] || continue
    # Check if unread
    local is_read
    is_read=$(python3 -c "import json; d=json.load(open('$msg_file')); print(d.get('read', False))" 2>/dev/null || echo "False")
    if [[ "$is_read" == "False" ]]; then
      if [[ "$found" == "false" ]]; then
        echo "## Inbox Messages"
        found=true
      fi
      echo "---"
      python3 -c "
import json
d = json.load(open('$msg_file'))
print(f\"From: {d['from']} | Type: {d['type']} | Ticket: {d['ticket']}\")
print(f\"Time: {d['created']}\")
print(d['content'])
" 2>/dev/null || true
      # Mark as read
      python3 -c "
import json
f = '$msg_file'
d = json.load(open(f))
d['read'] = True
json.dump(d, open(f, 'w'), indent=2)
" 2>/dev/null || true
    fi
  done
}

# ─── Person-Days Estimation ──────────────────────────────────────────────
# Estimation model: converts story points + complexity into person-days
# for billing as a dev team service.
#
# Conversion table (calibrated for AI team):
#   Story Points → Person-Days (includes impl + QA + review + deploy)
#   1 pt → 0.15 PD    (trivial: typo, config, 1-line fix)
#   2 pt → 0.3 PD     (small: simple bug fix, minor UI change)
#   3 pt → 0.5 PD     (medium: new component, moderate logic)
#   5 pt → 1.0 PD     (large: new feature, multiple files)
#   8 pt → 1.5 PD     (complex: cross-system feature, new system)
#   13 pt → 2.5 PD    (epic-size: should probably be split)

# Convert story points to person-days
story_points_to_person_days() {
  local sp="${1:-0}"
  case "$sp" in
    1)  echo "0.15" ;;
    2)  echo "0.3" ;;
    3)  echo "0.5" ;;
    5)  echo "1.0" ;;
    8)  echo "1.5" ;;
    13) echo "2.5" ;;
    *)  echo "0.5" ;;  # default for unknown
  esac
}

# Save person-days estimate for a ticket
# Usage: save_estimate TICKET_KEY PERSON_DAYS STORY_POINTS COMPLEXITY ESTIMATED_BY
save_estimate() {
  local ticket="$1" person_days="$2" story_points="${3:-0}" complexity="${4:-M}" estimated_by="${5:-salma}"
  local ticket_dir="${DATA_DIR}/tickets/${ticket}"
  mkdir -p "$ticket_dir"
  local ts
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  python3 -c "
import json, sys
d = {
    'person_days': float(sys.argv[1]),
    'story_points': int(sys.argv[2]),
    'complexity': sys.argv[3],
    'breakdown': {
        'implementation': round(float(sys.argv[1]) * 0.50, 2),
        'testing': round(float(sys.argv[1]) * 0.20, 2),
        'review': round(float(sys.argv[1]) * 0.20, 2),
        'deployment': round(float(sys.argv[1]) * 0.10, 2)
    },
    'estimated_by': sys.argv[4],
    'estimated_at': sys.argv[5]
}
print(json.dumps(d, indent=2))
" "$person_days" "$story_points" "$complexity" "$estimated_by" "$ts" > "${ticket_dir}/estimate.json" 2>/dev/null || true
  log_info "Saved estimate for ${ticket}: ${person_days} person-days (${story_points} SP, ${complexity})"
}

# Read person-days estimate for a ticket
get_estimate() {
  local ticket="$1"
  local est_file="${DATA_DIR}/tickets/${ticket}/estimate.json"
  if [[ -f "$est_file" ]]; then
    python3 -c "import json; d=json.load(open('$est_file')); print(d.get('person_days', 0))" 2>/dev/null || echo "0"
  else
    echo "0"
  fi
}

# ─── Sprint Velocity Tracking ───────────────────────────────────────────
# Records sprint metrics for velocity calculation and billing.

# Save sprint data snapshot
# Usage: save_sprint_data SPRINT_NUMBER PLANNED_PD DELIVERED_PD TICKETS_PLANNED TICKETS_DONE
save_sprint_data() {
  local sprint_num="$1" planned_pd="$2" delivered_pd="$3" tickets_planned="$4" tickets_done="$5"
  local sprint_file="${DATA_DIR}/sprints/history/sprint-$(printf '%03d' "$sprint_num").json"
  local ts
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  # Read daily cost data for this sprint period
  local total_duration=0
  local total_calls=0
  for cost_file in "${DATA_DIR}/costs/daily/"*.json; do
    [[ -f "$cost_file" ]] || continue
    local file_stats
    file_stats=$(python3 -c "
import json
with open('$cost_file') as f:
    d = json.load(f)
totals = d.get('totals', {})
calls = sum(t.get('calls', 0) for t in totals.values())
dur = sum(t.get('total_duration', 0) for t in totals.values())
print(f'{calls} {dur}')
" 2>/dev/null || echo "0 0")
    total_calls=$(( total_calls + $(echo "$file_stats" | cut -d' ' -f1) ))
    total_duration=$(( total_duration + $(echo "$file_stats" | cut -d' ' -f2) ))
  done

  local velocity_ratio="0"
  if [[ "$planned_pd" != "0" ]] && [[ -n "$planned_pd" ]]; then
    velocity_ratio=$(python3 -c "print(round(float('$delivered_pd') / float('$planned_pd'), 3))" 2>/dev/null || echo "0")
  fi

  local qa_pass_rate="0"
  # Count first-pass QA approvals from decision log
  local decisions_file="${DATA_DIR}/context/projects/${PROJECT_KEY,,}/decisions.jsonl"
  if [[ -f "$decisions_file" ]]; then
    local total_reviews pass_first
    total_reviews=$(grep -c '"decision":"PASS"\|"decision":"FAIL"' "$decisions_file" 2>/dev/null || echo "0")
    pass_first=$(grep -c '"decision":"PASS"' "$decisions_file" 2>/dev/null || echo "0")
    if (( total_reviews > 0 )); then
      qa_pass_rate=$(python3 -c "print(round($pass_first / $total_reviews, 2))" 2>/dev/null || echo "0")
    fi
  fi

  python3 -c "
import json, sys
d = {
    'sprint_number': int(sys.argv[1]),
    'sprint_name': f'${PROJECT_KEY} Sprint {sys.argv[1]}',
    'recorded_at': sys.argv[2],
    'planned_person_days': float(sys.argv[3]),
    'delivered_person_days': float(sys.argv[4]),
    'velocity_ratio': float(sys.argv[5]),
    'tickets_planned': int(sys.argv[6]),
    'tickets_completed': int(sys.argv[7]),
    'total_calls': int(sys.argv[8]),
    'total_duration_seconds': int(sys.argv[9]),
    'qa_first_pass_rate': float(sys.argv[10])
}
print(json.dumps(d, indent=2))
" "$sprint_num" "$ts" "$planned_pd" "$delivered_pd" "$velocity_ratio" \
  "$tickets_planned" "$tickets_done" "$total_calls" "$total_duration" "$qa_pass_rate" \
  > "$sprint_file" 2>/dev/null || true

  # Also append to velocity time-series
  echo "{\"sprint\":${sprint_num},\"planned\":${planned_pd},\"delivered\":${delivered_pd},\"velocity\":${velocity_ratio},\"ts\":\"${ts}\"}" \
    >> "${DATA_DIR}/metrics/velocity.jsonl" 2>/dev/null || true

  log_info "Saved sprint ${sprint_num} data: ${delivered_pd}/${planned_pd} PD, velocity=${velocity_ratio}"
}

# Get current sprint velocity (average of last 3 sprints)
get_velocity() {
  local velocities=()
  for sprint_file in $(ls -t "${DATA_DIR}/sprints/history/"sprint-*.json 2>/dev/null | head -3); do
    local v
    v=$(python3 -c "import json; print(json.load(open('$sprint_file')).get('velocity_ratio', 0))" 2>/dev/null || echo "0")
    velocities+=("$v")
  done

  if [[ ${#velocities[@]} -eq 0 ]]; then
    echo "0.8"  # default assumption
    return
  fi

  python3 -c "
vs = [float(v) for v in '${velocities[*]}'.split()]
print(round(sum(vs) / len(vs), 3) if vs else 0.8)
" 2>/dev/null || echo "0.8"
}

# Sum planned person-days for all sprint-active tickets
sum_sprint_person_days() {
  local total=0
  local ticket_dir
  for ticket_dir in "${DATA_DIR}/tickets/"${PROJECT_KEY}-*/; do
    [[ -d "$ticket_dir" ]] || continue
    local est_file="${ticket_dir}estimate.json"
    [[ -f "$est_file" ]] || continue
    local pd
    pd=$(python3 -c "import json; print(json.load(open('$est_file')).get('person_days', 0))" 2>/dev/null || echo "0")
    total=$(python3 -c "print(round(float('$total') + float('$pd'), 2))" 2>/dev/null || echo "$total")
  done
  echo "$total"
}
