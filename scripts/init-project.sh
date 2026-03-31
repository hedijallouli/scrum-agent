#!/usr/bin/env bash
# =============================================================================
# init-project.sh — Infrastructure onboarding wizard for scrum-agent (Layer 1)
#
# Creates all mechanical infrastructure for a new project:
#   1. Collects project info interactively (with sane defaults)
#   2. Creates Plane project + 11 workflow states via API
#   3. Creates Mattermost channels via API
#   4. Generates .agent-config.json, .env.agents, docs/project-context.md
#   5. Prints summary + next steps
#
# Usage:
#   ./init-project.sh                 # Interactive wizard
#   ./init-project.sh --help          # Show usage
#
# Environment variables (required for API calls):
#   PLANE_URL, PLANE_API_KEY, PLANE_WORKSPACE
#   MATTERMOST_URL, MATTERMOST_TOKEN, MATTERMOST_TEAM_ID
#
# Philosophy: pure Bash, graceful degradation, idempotent where possible.
# =============================================================================
set -euo pipefail

# ─── Colors ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m' # No Color

# ─── Help ────────────────────────────────────────────────────────────────────
show_help() {
  cat <<'HELP'
init-project.sh — Infrastructure onboarding wizard for scrum-agent

USAGE:
  ./init-project.sh              Interactive wizard
  ./init-project.sh --help       Show this help

ENVIRONMENT VARIABLES (set before running, or provide via .env file):
  PLANE_URL            Plane instance base URL (e.g., http://49.13.225.201:8090)
  PLANE_API_KEY        Plane API key for workspace admin
  PLANE_WORKSPACE      Plane workspace slug (e.g., "bisb")

  MATTERMOST_URL       Mattermost instance URL (e.g., http://49.13.225.201:8065)
  MATTERMOST_TOKEN     Mattermost admin/bot token
  MATTERMOST_TEAM_ID   Mattermost team ID for channel creation

WHAT IT CREATES:
  - Plane project with 11 workflow states (Backlog..Cancelled)
  - 4 Mattermost channels (pipeline, standup, dev, escalation)
  - .agent-config.json in the target project directory
  - .env.agents for VPS deployment
  - docs/project-context.md (from provided context or placeholder)
  - ai/ directory (empty, populated by sprint-zero.sh)

NOTES:
  - API failures are non-fatal: the script prints errors but continues
  - Idempotent: checks for existing projects/channels before creating
  - All credentials come from env vars — nothing is hardcoded
HELP
  exit 0
}

[[ "${1:-}" == "--help" || "${1:-}" == "-h" ]] && show_help

# ─── Logging ─────────────────────────────────────────────────────────────────
log_info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*"; }
log_step()    { echo -e "\n${BOLD}${CYAN}==> $*${NC}"; }

# ─── Prompt Helper ───────────────────────────────────────────────────────────
# Usage: ask VAR "Prompt text" "default_value"
ask() {
  local var_name="$1" prompt="$2" default="${3:-}"
  local display_default=""
  [[ -n "$default" ]] && display_default=" ${DIM}(${default})${NC}"
  echo -en "  ${prompt}${display_default}: "
  local answer
  read -r answer
  answer="${answer:-$default}"
  eval "$var_name=\"\$answer\""
}

# ─── Multi-select Helper ────────────────────────────────────────────────────
# Usage: ask_agents AGENTS_VAR
ask_agents() {
  local var_name="$1"
  local all_agents=("salma" "youssef" "nadia" "rami" "omar" "layla")
  echo -e "  Which agents to activate? ${DIM}(comma-separated, or 'all')${NC}"
  echo -e "    ${DIM}Available: salma, youssef, nadia, rami, omar, layla${NC}"
  echo -en "  Agents ${DIM}(all)${NC}: "
  local answer
  read -r answer
  answer="${answer:-all}"
  if [[ "$answer" == "all" ]]; then
    eval "$var_name=\"salma,youssef,nadia,rami,omar,layla\""
  else
    eval "$var_name=\"\$answer\""
  fi
}

# =============================================================================
# STEP 1: Collect project info
# =============================================================================
log_step "Step 1/5: Project Information"
echo

ask PROJECT_NAME    "Project name (e.g., Carre d'Or POS)" ""
[[ -z "$PROJECT_NAME" ]] && { log_error "Project name is required."; exit 1; }

# Suggest a key from the name: uppercase first letters, 3-4 chars
suggested_key=$(echo "$PROJECT_NAME" | tr '[:lower:]' '[:upper:]' | sed "s/[^A-Z ]//g" | awk '{for(i=1;i<=NF;i++) printf substr($i,1,1)}')
[[ ${#suggested_key} -lt 2 ]] && suggested_key=$(echo "$PROJECT_NAME" | tr '[:lower:]' '[:upper:]' | sed "s/[^A-Z]//g" | head -c 3)

ask PROJECT_KEY     "Project identifier (uppercase, 3-4 chars)" "$suggested_key"
PROJECT_KEY=$(echo "$PROJECT_KEY" | tr '[:lower:]' '[:upper:]' | sed "s/[^A-Z0-9]//g" | head -c 4)
[[ -z "$PROJECT_KEY" ]] && { log_error "Project key is required."; exit 1; }

ask GITHUB_REPO     "GitHub repo (owner/name)" ""
ask BASE_BRANCH     "Base branch" "main"
ask RUNTIME         "Tech stack runtime (npm/bun/python/cargo)" "npm"

# Set command defaults based on runtime
case "$RUNTIME" in
  bun)
    DEF_BUILD="bun run build"; DEF_TEST="bun test"; DEF_LINT="bun run lint"; DEF_TYPECHECK="bunx tsc --noEmit" ;;
  python)
    DEF_BUILD=""; DEF_TEST="pytest"; DEF_LINT="ruff check ."; DEF_TYPECHECK="mypy ." ;;
  cargo)
    DEF_BUILD="cargo build"; DEF_TEST="cargo test"; DEF_LINT="cargo clippy"; DEF_TYPECHECK="" ;;
  *)
    DEF_BUILD="npm run build"; DEF_TEST="npm test"; DEF_LINT="npm run lint"; DEF_TYPECHECK="npx tsc --noEmit" ;;
esac

ask BUILD_CMD       "Build command" "$DEF_BUILD"
ask TEST_CMD        "Test command" "$DEF_TEST"
ask LINT_CMD        "Lint command" "$DEF_LINT"
ask TYPECHECK_CMD   "Typecheck command" "$DEF_TYPECHECK"
ask SRC_PATHS       "Source paths" "src/"
ask MAX_PR_LINES    "Max PR lines" "300"
ask DAILY_BUDGET    "Daily budget (API calls)" "100"
ask_agents AGENTS
ask CONTEXT_FILE    "Path to project context file (optional)" ""

# Ask for target project directory
ask PROJECT_DIR     "Target project directory" ""
[[ -z "$PROJECT_DIR" ]] && { log_error "Target project directory is required."; exit 1; }
# Expand ~ if present
PROJECT_DIR="${PROJECT_DIR/#\~/$HOME}"

echo
log_info "Project: ${BOLD}${PROJECT_NAME}${NC} (${PROJECT_KEY})"
log_info "Repo: ${GITHUB_REPO:-none} | Branch: ${BASE_BRANCH} | Runtime: ${RUNTIME}"
log_info "Agents: ${AGENTS}"
log_info "Target: ${PROJECT_DIR}"
echo

# ─── Validate env vars for API calls ────────────────────────────────────────
PLANE_URL="${PLANE_URL:-}"
PLANE_API_KEY="${PLANE_API_KEY:-}"
PLANE_WORKSPACE="${PLANE_WORKSPACE:-}"
MATTERMOST_URL="${MATTERMOST_URL:-}"
MATTERMOST_TOKEN="${MATTERMOST_TOKEN:-}"
MATTERMOST_TEAM_ID="${MATTERMOST_TEAM_ID:-}"

PLANE_OK=false
MM_OK=false

if [[ -n "$PLANE_URL" && -n "$PLANE_API_KEY" && -n "$PLANE_WORKSPACE" ]]; then
  PLANE_OK=true
else
  log_warn "Plane env vars missing (PLANE_URL, PLANE_API_KEY, PLANE_WORKSPACE) — skipping Plane setup"
fi

if [[ -n "$MATTERMOST_URL" && -n "$MATTERMOST_TOKEN" && -n "$MATTERMOST_TEAM_ID" ]]; then
  MM_OK=true
else
  log_warn "Mattermost env vars missing (MATTERMOST_URL, MATTERMOST_TOKEN, MATTERMOST_TEAM_ID) — skipping Mattermost setup"
fi

# =============================================================================
# STEP 2: Create Plane project + states
# =============================================================================
log_step "Step 2/5: Plane Project Setup"

PLANE_PROJECT_ID=""
declare -A STATE_IDS=()

# All 11 states in order, with their group
# Plane state groups: backlog, unstarted, started, completed, cancelled
STATE_DEFS=(
  "Backlog:backlog"
  "Todo:unstarted"
  "Needs Human:unstarted"
  "Blocked:unstarted"
  "Ready:unstarted"
  "In Progress:started"
  "In Review:started"
  "QA:started"
  "Done:completed"
  "Merged:completed"
  "Cancelled:cancelled"
)

# State colors (hex without #)
declare -A STATE_COLORS=(
  ["Backlog"]="#a3a3a3"
  ["Todo"]="#d4d4d4"
  ["Needs Human"]="#f97316"
  ["Blocked"]="#ef4444"
  ["Ready"]="#3b82f6"
  ["In Progress"]="#8b5cf6"
  ["In Review"]="#6366f1"
  ["QA"]="#a855f7"
  ["Done"]="#22c55e"
  ["Merged"]="#15803d"
  ["Cancelled"]="#78716c"
)

plane_api() {
  local method="$1" path="$2" data="${3:-}"
  local url="${PLANE_URL}/api/v1${path}"
  local args=(-s -w "\n%{http_code}" -X "$method"
    -H "X-API-Key: ${PLANE_API_KEY}"
    -H "Content-Type: application/json")
  [[ -n "$data" ]] && args+=(-d "$data")
  curl "${args[@]}" "$url" 2>/dev/null
}

if $PLANE_OK; then
  # ── Check if project already exists ──────────────────────────────────────
  log_info "Checking for existing Plane project..."
  existing_projects=$(plane_api GET "/workspaces/${PLANE_WORKSPACE}/projects/" || echo "")
  existing_id=$(echo "$existing_projects" | head -n -1 | python3 -c "
import sys, json
try:
  data = json.load(sys.stdin)
  results = data if isinstance(data, list) else data.get('results', [])
  match = next((p for p in results if p.get('identifier') == '${PROJECT_KEY}'), None)
  if match: print(match['id'])
except: pass
" 2>/dev/null || echo "")

  if [[ -n "$existing_id" ]]; then
    PLANE_PROJECT_ID="$existing_id"
    log_warn "Project ${PROJECT_KEY} already exists (${PLANE_PROJECT_ID}) — reusing"
  else
    # ── Create project ───────────────────────────────────────────────────
    log_info "Creating Plane project: ${PROJECT_NAME} (${PROJECT_KEY})..."
    create_resp=$(plane_api POST "/workspaces/${PLANE_WORKSPACE}/projects/" \
      "{\"name\":\"${PROJECT_NAME}\",\"identifier\":\"${PROJECT_KEY}\",\"network\":2}" || echo "")
    http_code=$(echo "$create_resp" | tail -1)
    body=$(echo "$create_resp" | head -n -1)

    if [[ "$http_code" =~ ^2 ]]; then
      PLANE_PROJECT_ID=$(echo "$body" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || echo "")
      if [[ -n "$PLANE_PROJECT_ID" ]]; then
        log_success "Created Plane project: ${PLANE_PROJECT_ID}"
      else
        log_error "Plane project created but could not parse ID from response"
      fi
    else
      log_error "Failed to create Plane project (HTTP ${http_code}): $(echo "$body" | head -c 200)"
    fi
  fi

  # ── Create 11 workflow states ──────────────────────────────────────────
  if [[ -n "$PLANE_PROJECT_ID" ]]; then
    log_info "Setting up workflow states..."

    # Fetch existing states first (for idempotency)
    existing_states=$(plane_api GET "/workspaces/${PLANE_WORKSPACE}/projects/${PLANE_PROJECT_ID}/states/" || echo "")
    existing_state_json=$(echo "$existing_states" | head -n -1)

    for state_def in "${STATE_DEFS[@]}"; do
      state_name="${state_def%%:*}"
      state_group="${state_def##*:}"
      state_color="${STATE_COLORS[$state_name]:-#a3a3a3}"

      # Check if state already exists
      existing_state_id=$(echo "$existing_state_json" | python3 -c "
import sys, json
try:
  data = json.load(sys.stdin)
  results = data if isinstance(data, list) else data.get('results', [])
  match = next((s for s in results if s.get('name') == '${state_name}'), None)
  if match: print(match['id'])
except: pass
" 2>/dev/null || echo "")

      if [[ -n "$existing_state_id" ]]; then
        STATE_IDS["$state_name"]="$existing_state_id"
        log_info "  State '${state_name}' already exists: ${existing_state_id}"
        continue
      fi

      resp=$(plane_api POST "/workspaces/${PLANE_WORKSPACE}/projects/${PLANE_PROJECT_ID}/states/" \
        "{\"name\":\"${state_name}\",\"group\":\"${state_group}\",\"color\":\"${state_color}\"}" || echo "")
      code=$(echo "$resp" | tail -1)
      body=$(echo "$resp" | head -n -1)

      if [[ "$code" =~ ^2 ]]; then
        state_id=$(echo "$body" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || echo "")
        STATE_IDS["$state_name"]="$state_id"
        log_success "  Created state '${state_name}': ${state_id}"
      else
        log_error "  Failed to create state '${state_name}' (HTTP ${code})"
      fi
    done
  fi
else
  log_warn "Skipping Plane project creation (no credentials)"
fi

# =============================================================================
# STEP 3: Create Mattermost channels
# =============================================================================
log_step "Step 3/5: Mattermost Channel Setup"

declare -A CHANNEL_IDS=()
KEY_LOWER=$(echo "$PROJECT_KEY" | tr '[:upper:]' '[:lower:]')
CHANNEL_NAMES=("${KEY_LOWER}-pipeline" "${KEY_LOWER}-standup" "${KEY_LOWER}-dev" "${KEY_LOWER}-escalation")

mm_api() {
  local method="$1" path="$2" data="${3:-}"
  local url="${MATTERMOST_URL}/api/v4${path}"
  local args=(-s -w "\n%{http_code}" -X "$method"
    -H "Authorization: Bearer ${MATTERMOST_TOKEN}"
    -H "Content-Type: application/json")
  [[ -n "$data" ]] && args+=(-d "$data")
  curl "${args[@]}" "$url" 2>/dev/null
}

if $MM_OK; then
  for channel_name in "${CHANNEL_NAMES[@]}"; do
    purpose="${channel_name##*-}"
    display_name="${PROJECT_KEY} ${purpose^}"

    # Check if channel already exists
    log_info "Checking for channel: ${channel_name}..."
    check_resp=$(mm_api GET "/teams/${MATTERMOST_TEAM_ID}/channels/name/${channel_name}" || echo "")
    check_code=$(echo "$check_resp" | tail -1)
    check_body=$(echo "$check_resp" | head -n -1)

    if [[ "$check_code" == "200" ]]; then
      ch_id=$(echo "$check_body" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || echo "")
      if [[ -n "$ch_id" ]]; then
        CHANNEL_IDS["$channel_name"]="$ch_id"
        log_warn "  Channel '${channel_name}' already exists: ${ch_id}"
        continue
      fi
    fi

    # Create channel
    resp=$(mm_api POST "/channels" \
      "{\"team_id\":\"${MATTERMOST_TEAM_ID}\",\"name\":\"${channel_name}\",\"display_name\":\"${display_name}\",\"type\":\"O\"}" || echo "")
    code=$(echo "$resp" | tail -1)
    body=$(echo "$resp" | head -n -1)

    if [[ "$code" =~ ^2 ]]; then
      ch_id=$(echo "$body" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || echo "")
      CHANNEL_IDS["$channel_name"]="$ch_id"
      log_success "  Created channel '${channel_name}': ${ch_id}"
    else
      log_error "  Failed to create channel '${channel_name}' (HTTP ${code})"
    fi
  done
else
  log_warn "Skipping Mattermost channel creation (no credentials)"
fi

# =============================================================================
# STEP 4: Generate files
# =============================================================================
log_step "Step 4/5: Generate Config Files"

mkdir -p "$PROJECT_DIR"

# ── .agent-config.json ───────────────────────────────────────────────────────
CONFIG_FILE="${PROJECT_DIR}/.agent-config.json"

# Build agents JSON array
IFS=',' read -ra AGENT_LIST <<< "$AGENTS"
AGENTS_JSON=""
for a in "${AGENT_LIST[@]}"; do
  a=$(echo "$a" | tr -d ' ')
  [[ -n "$AGENTS_JSON" ]] && AGENTS_JSON="${AGENTS_JSON},"
  AGENTS_JSON="${AGENTS_JSON}\"${a}\""
done

# Build state_ids JSON object
STATE_IDS_JSON=""
for key in "${!STATE_IDS[@]}"; do
  [[ -n "$STATE_IDS_JSON" ]] && STATE_IDS_JSON="${STATE_IDS_JSON},"
  STATE_IDS_JSON="${STATE_IDS_JSON}\"${key}\": \"${STATE_IDS[$key]}\""
done

# Build channel_ids JSON object
CHANNEL_IDS_JSON=""
for key in "${!CHANNEL_IDS[@]}"; do
  [[ -n "$CHANNEL_IDS_JSON" ]] && CHANNEL_IDS_JSON="${CHANNEL_IDS_JSON},"
  CHANNEL_IDS_JSON="${CHANNEL_IDS_JSON}\"${key}\": \"${CHANNEL_IDS[$key]}\""
done

cat > "$CONFIG_FILE" <<JSONEOF
{
  "name": "${PROJECT_NAME}",
  "project_key": "${PROJECT_KEY}",
  "repo": "${GITHUB_REPO}",
  "base_branch": "${BASE_BRANCH}",
  "domain": "",
  "domain_context": "docs/project-context.md",
  "stack": {
    "runtime": "${RUNTIME}",
    "build": "${BUILD_CMD}",
    "test": "${TEST_CMD}",
    "lint": "${LINT_CMD}",
    "typecheck": "${TYPECHECK_CMD}",
    "src_paths": "${SRC_PATHS}"
  },
  "max_pr_lines": ${MAX_PR_LINES},
  "cost_budget_daily_calls": ${DAILY_BUDGET},
  "capacity_allocation": 1.0,
  "agents": [${AGENTS_JSON}],
  "plane": {
    "project_id": "${PLANE_PROJECT_ID}",
    "state_ids": {${STATE_IDS_JSON}}
  },
  "mattermost": {
    "channel_ids": {${CHANNEL_IDS_JSON}}
  }
}
JSONEOF
log_success "Generated ${CONFIG_FILE}"

# ── docs/project-context.md ──────────────────────────────────────────────────
DOCS_DIR="${PROJECT_DIR}/docs"
mkdir -p "$DOCS_DIR"
CONTEXT_TARGET="${DOCS_DIR}/project-context.md"

if [[ -n "$CONTEXT_FILE" && -f "$CONTEXT_FILE" ]]; then
  cp "$CONTEXT_FILE" "$CONTEXT_TARGET"
  log_success "Copied project context from ${CONTEXT_FILE}"
elif [[ ! -f "$CONTEXT_TARGET" ]]; then
  cat > "$CONTEXT_TARGET" <<MDEOF
# ${PROJECT_NAME} -- Project Context

## Overview
<!-- Brief description of the project -->

## Target Users
<!-- Who uses this product? -->

## Key Features
<!-- Main features / user stories -->

## Domain Knowledge
<!-- Industry-specific terms, business rules, client notes -->

## Design References
<!-- Links to Figma, Instagram, competitor analysis -->

## Technical Constraints
<!-- API limits, device targets, performance requirements -->
MDEOF
  log_success "Generated placeholder ${CONTEXT_TARGET}"
else
  log_info "docs/project-context.md already exists — skipping"
fi

# ── .env.agents ──────────────────────────────────────────────────────────────
ENV_FILE="${PROJECT_DIR}/.env.agents"

cat > "$ENV_FILE" <<ENVEOF
# =============================================================================
# .env.agents — Generated by init-project.sh on $(date '+%Y-%m-%d %H:%M:%S')
# Deploy this to VPS at /etc/bisb/.env.agents (or project-specific path)
# =============================================================================

# ─── Project ─────────────────────────────────────────────────────────────────
PROJECT_KEY="${PROJECT_KEY}"
PROJECT_NAME="${PROJECT_NAME}"
PROJECT_DIR="${PROJECT_DIR}"
GITHUB_REPO="${GITHUB_REPO}"
BASE_BRANCH="${BASE_BRANCH}"

# ─── Tracker (Plane) ────────────────────────────────────────────────────────
TRACKER_BACKEND=plane
PLANE_BASE_URL="${PLANE_URL}"
PLANE_API_KEY="${PLANE_API_KEY}"
PLANE_WORKSPACE_SLUG="${PLANE_WORKSPACE}"
PLANE_PROJECT_ID="${PLANE_PROJECT_ID}"
ENVEOF

# Append state IDs
{
  echo ""
  echo "# ─── Plane State UUIDs ──────────────────────────────────────────────────"
  for state_def in "${STATE_DEFS[@]}"; do
    state_name="${state_def%%:*}"
    state_id="${STATE_IDS[$state_name]:-}"
    var_name=$(echo "$state_name" | tr '[:lower:]' '[:upper:]' | tr ' ' '_')
    echo "PLANE_STATE_${var_name}=\"${state_id}\""
  done
} >> "$ENV_FILE"

# Append Mattermost config
{
  echo ""
  echo "# ─── Chat (Mattermost) ──────────────────────────────────────────────────"
  echo "CHAT_BACKEND=mattermost"
  echo "MATTERMOST_URL=\"${MATTERMOST_URL}\""
  echo "MATTERMOST_BOT_TOKEN=\"${MATTERMOST_TOKEN}\""
  echo "MATTERMOST_TEAM_ID=\"${MATTERMOST_TEAM_ID}\""
  echo ""
  echo "# Channel IDs"
  echo "MM_CHANNEL_PIPELINE=\"${CHANNEL_IDS[${KEY_LOWER}-pipeline]:-}\""
  echo "MM_CHANNEL_STANDUP=\"${CHANNEL_IDS[${KEY_LOWER}-standup]:-}\""
  echo "MM_CHANNEL_DEV=\"${CHANNEL_IDS[${KEY_LOWER}-dev]:-}\""
  echo "MM_CHANNEL_ESCALATION=\"${CHANNEL_IDS[${KEY_LOWER}-escalation]:-}\""
} >> "$ENV_FILE"

# Append agent toggle
{
  echo ""
  echo "# ─── Active Agents ───────────────────────────────────────────────────────"
  echo "ACTIVE_AGENTS=\"${AGENTS}\""
} >> "$ENV_FILE"

log_success "Generated ${ENV_FILE}"

# ── ai/ directory ────────────────────────────────────────────────────────────
AI_DIR="${PROJECT_DIR}/ai"
mkdir -p "$AI_DIR"
log_success "Created ${AI_DIR}/ (to be populated by sprint-zero.sh)"

# =============================================================================
# STEP 5: Summary
# =============================================================================
log_step "Step 5/5: Summary"
echo
echo -e "${BOLD}Project: ${PROJECT_NAME} (${PROJECT_KEY})${NC}"
echo -e "  Repo:       ${GITHUB_REPO:-not set}"
echo -e "  Branch:     ${BASE_BRANCH}"
echo -e "  Runtime:    ${RUNTIME}"
echo -e "  Agents:     ${AGENTS}"
echo

if [[ -n "$PLANE_PROJECT_ID" ]]; then
  echo -e "${BOLD}Plane Project:${NC}"
  echo -e "  ID: ${PLANE_PROJECT_ID}"
  echo -e "  States:"
  for state_def in "${STATE_DEFS[@]}"; do
    state_name="${state_def%%:*}"
    state_id="${STATE_IDS[$state_name]:-not created}"
    printf "    %-15s %s\n" "$state_name" "$state_id"
  done
  echo
fi

if [[ ${#CHANNEL_IDS[@]} -gt 0 ]]; then
  echo -e "${BOLD}Mattermost Channels:${NC}"
  for ch in "${!CHANNEL_IDS[@]}"; do
    printf "    %-25s %s\n" "$ch" "${CHANNEL_IDS[$ch]}"
  done
  echo
fi

echo -e "${BOLD}Generated Files:${NC}"
echo "    ${CONFIG_FILE}"
echo "    ${ENV_FILE}"
echo "    ${CONTEXT_TARGET}"
echo "    ${AI_DIR}/"
echo

echo -e "${BOLD}${GREEN}Next Steps:${NC}"
echo "  1. Add scrum-agent as a submodule to your project:"
echo "     cd ${PROJECT_DIR} && git submodule add <scrum-agent-url> scrum-agent"
echo "  2. Run sprint-zero.sh to populate ai/ with agent prompts:"
echo "     ./scrum-agent/scripts/sprint-zero.sh"
echo "  3. Deploy .env.agents to VPS:"
echo "     scp ${ENV_FILE} root@49.13.225.201:/etc/bisb/.env.agents.${KEY_LOWER}"
echo "  4. Review and edit docs/project-context.md with domain knowledge"
echo
log_success "Infrastructure onboarding complete."
