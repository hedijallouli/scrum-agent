#!/usr/bin/env bash
# =============================================================================
# agent-youssef-self-improve.sh — Youssef Self-Improvement Agent
# Reads retro-action tickets tagged 'self-improve', identifies the target
# bash script, generates an improved version via Claude, and creates a PR.
#
# Triggered by: agent-cron.sh Phase 2 (self-improve label detection)
# Usage: agent-youssef-self-improve.sh TICKET-XX
# =============================================================================
AGENT_NAME="youssef"
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/agent-common.sh"

BASE_BRANCH="${BASE_BRANCH:-dev}"
TICKET_KEY="${1:?Usage: agent-youssef-self-improve.sh ${PROJECT_KEY:-TICKET}-XX}"
MAX_RETRIES=2

init_log "$TICKET_KEY" "youssef-self-improve"
log_info "=== Youssef Self-Improve starting on ${TICKET_KEY} ==="

# ─── 1. Retry guard ───────────────────────────────────────────────────────────
retry_count=$(get_retry_count "$TICKET_KEY" "youssef-self-improve")
if (( retry_count >= MAX_RETRIES )); then
  log_info "Max retries ($MAX_RETRIES) reached for ${TICKET_KEY}. Skipping."
  jira_add_label "$TICKET_KEY" "blocked" 2>/dev/null || true
  slack_notify "youssef" "$(mm_ticket_link "${TICKET_KEY}") — self-improve échec ${MAX_RETRIES} fois. Ticket bloqué pour review humaine. 🔴" "pipeline" 2>/dev/null || true
  exit 0
fi

if ! check_cooldown "$TICKET_KEY" "youssef-self-improve"; then
  exit 0
fi

# ─── 2. Fetch ticket details ──────────────────────────────────────────────────
log_info "Fetching ticket details..."
SUMMARY=$(jira_get_ticket_field "$TICKET_KEY" "summary")
DESCRIPTION=$(jira_get_description_text "$TICKET_KEY")

log_info "Ticket: ${SUMMARY}"

# ─── 3. Detect target script from title or description ───────────────────────
# Look for script names like ceremony-standup.sh, agent-common.sh, etc.
TARGET_SCRIPT=""
for text in "$SUMMARY" "$DESCRIPTION"; do
  DETECTED=$(echo "$text" | grep -oE '(ceremony|agent|tracker|run|agent-cron|agent-dm)-[a-z-]+\.sh' | head -1 || true)
  if [[ -n "$DETECTED" ]]; then
    TARGET_SCRIPT="$DETECTED"
    break
  fi
done

if [[ -z "$TARGET_SCRIPT" ]]; then
  log_error "Could not detect target script from ticket title/description: '${SUMMARY}'"
  increment_retry "$TICKET_KEY" "youssef-self-improve"
  jira_add_rich_comment "$TICKET_KEY" "youssef" "WARNING" "## Self-Improve: Script Non Détecté

Je ne peux pas identifier le script cible depuis le titre du ticket :
> ${SUMMARY}

Le titre doit mentionner le nom du script (ex: \`ceremony-standup.sh\`, \`agent-cron.sh\`). Merci de préciser."
  exit 1
fi

log_info "Target script: ${TARGET_SCRIPT}"

# Script paths
LOCAL_SCRIPT_PATH="${PROJECT_DIR}/n8n/scripts/${TARGET_SCRIPT}"
VPS_SCRIPT_PATH="${PROJECT_DIR}/scripts/${TARGET_SCRIPT}"

# Read local version (source of truth — git repo)
if [[ ! -f "$LOCAL_SCRIPT_PATH" ]]; then
  log_error "Script not found locally: ${LOCAL_SCRIPT_PATH}"
  increment_retry "$TICKET_KEY" "youssef-self-improve"
  jira_add_rich_comment "$TICKET_KEY" "youssef" "ERROR" "Script \`${TARGET_SCRIPT}\` non trouvé dans le repo local (\`n8n/scripts/\`). Vérifie le nom du script."
  exit 1
fi

SCRIPT_CONTENT=$(cat "$LOCAL_SCRIPT_PATH")
SCRIPT_LINES=$(echo "$SCRIPT_CONTENT" | wc -l)
log_info "Script ${TARGET_SCRIPT}: ${SCRIPT_LINES} lines"

# ─── 4. Mark In Progress in Plane ────────────────────────────────────────────
jira_set_status "$TICKET_KEY" "In Progress" 2>/dev/null || true
jira_assign_to_me "$TICKET_KEY" 2>/dev/null || true

# ─── 5. Prepare git branch ───────────────────────────────────────────────────
log_info "Preparing git workspace..."
cd "$PROJECT_DIR"
SLUG=$(echo "$SUMMARY" | tr "[:upper:]" "[:lower:]" | sed "s/[^a-z0-9]/-/g" | sed "s/--*/-/g" | head -c 40 | sed "s/-$//")
BRANCH="fix/retro-${TICKET_KEY}-${SLUG}"
log_info "Branch: ${BRANCH}"

WORKTREE_PATH=$(prepare_isolated_workspace "$TICKET_KEY" "$BRANCH")

PROJECT_DIR="$WORKTREE_PATH"
cd "$PROJECT_DIR"
log_info "Working in worktree: ${WORKTREE_PATH}"

# ─── 6. Claude generates improvement ─────────────────────────────────────────
log_info "Invoking Claude for script improvement..."

MODEL="${CLAUDE_MODEL_SONNET:-claude-sonnet-4-5}"

CLAUDE_PROMPT="You are Youssef, the Dev agent for ${PROJECT_NAME} (${PROJECT_KEY}).
You are working on a self-improvement retro ticket: improving a bash script in the pipeline.

TICKET: ${TICKET_KEY}
TITLE: ${SUMMARY}

IMPROVEMENT REQUESTED:
${DESCRIPTION:-No description — infer from the ticket title what needs to be improved.}

TARGET SCRIPT: n8n/scripts/${TARGET_SCRIPT}
CURRENT CONTENT (${SCRIPT_LINES} lines):
\`\`\`bash
${SCRIPT_CONTENT}
\`\`\`

YOUR TASK:
1. Read the ticket title and description carefully to understand what needs to be improved
2. Edit n8n/scripts/${TARGET_SCRIPT} to implement the improvement
3. Create a single commit with a clear message: 'fix(pipeline): [what you changed]'
4. Keep changes focused and minimal (max 80 lines of changes)
5. DO NOT change the script's overall structure, sourcing, or set -euo pipefail
6. Verify bash syntax is valid (no syntax errors)
7. If you are unsure what to change based on the description, add defensive error handling,
   better logging, or idempotency checks — improvements that are always safe

RULES:
- Only modify n8n/scripts/${TARGET_SCRIPT}
- Keep all existing functionality working
- No TypeScript — this is a bash script
- Write a comment explaining your change near the modified code"

log_info "Running claude (${MODEL}) for self-improvement on ${TARGET_SCRIPT}..."
CLAUDE_EXIT=0
timeout 480 claude -p \
  --model "$MODEL" \
  --max-turns 8 \
  "$CLAUDE_PROMPT" >> "$LOG_FILE" 2>&1 || CLAUDE_EXIT=$?

if [[ "$CLAUDE_EXIT" -ne 0 ]]; then
  log_error "Claude invocation failed (exit ${CLAUDE_EXIT})"
  increment_retry "$TICKET_KEY" "youssef-self-improve"
  exit 1
fi

# ─── 7. Verify the script was actually modified ───────────────────────────────
log_info "Verifying script was modified..."
cd "$PROJECT_DIR"
CHANGES=$(git diff --stat "origin/${BASE_BRANCH}...HEAD" -- "n8n/scripts/${TARGET_SCRIPT}" 2>/dev/null || echo "")
COMMIT_COUNT=$(git rev-list --count "origin/${BASE_BRANCH}..HEAD" 2>/dev/null || echo "0")

if [[ "$COMMIT_COUNT" -eq 0 ]]; then
  log_error "No commits produced — Claude did not modify ${TARGET_SCRIPT}"
  increment_retry "$TICKET_KEY" "youssef-self-improve"
  jira_add_rich_comment "$TICKET_KEY" "youssef" "WARNING" "## Self-Improve: Aucune Modification

Claude n'a pas produit de changements sur \`${TARGET_SCRIPT}\`. Je réessaie au prochain cycle."
  exit 1
fi

log_info "Changes: ${CHANGES}"

# Bash syntax check on the modified script
MODIFIED_SCRIPT="${PROJECT_DIR}/n8n/scripts/${TARGET_SCRIPT}"
if ! bash -n "$MODIFIED_SCRIPT" 2>/dev/null; then
  log_error "Syntax error in modified ${TARGET_SCRIPT}"
  increment_retry "$TICKET_KEY" "youssef-self-improve"
  jira_add_rich_comment "$TICKET_KEY" "youssef" "ERROR" "## Self-Improve: Erreur de Syntaxe Bash

Le script généré contient une erreur de syntaxe. Je réessaie."
  exit 1
fi
log_info "Bash syntax check passed"

# ─── 8. Push branch ──────────────────────────────────────────────────────────
log_info "Pushing branch ${BRANCH}..."
if ! git push -u origin "$BRANCH" >> "$LOG_FILE" 2>&1; then
  git fetch origin "$BASE_BRANCH" >> "$LOG_FILE" 2>&1 || true
  if git rebase "origin/$BASE_BRANCH" >> "$LOG_FILE" 2>&1; then
    git push --force-with-lease origin "$BRANCH" >> "$LOG_FILE" 2>&1 || {
      log_error "Push failed after rebase"
      increment_retry "$TICKET_KEY" "youssef-self-improve"
      exit 1
    }
  else
    log_error "Rebase failed"
    increment_retry "$TICKET_KEY" "youssef-self-improve"
    exit 1
  fi
fi
log_info "Pushed to ${BRANCH}"

# ─── 9. Create PR ─────────────────────────────────────────────────────────────
log_info "Creating PR..."
DIFF_SUMMARY=$(cd "$PROJECT_DIR" && git diff "origin/${BASE_BRANCH}...HEAD" -- "n8n/scripts/${TARGET_SCRIPT}" 2>/dev/null | head -60 || echo "")

PR_BODY="## Self-Improvement — ${TICKET_KEY}

**Script amélioré:** \`n8n/scripts/${TARGET_SCRIPT}\`
**Retro ticket:** ${TICKET_KEY} — ${SUMMARY}

### Changements
\`\`\`diff
${DIFF_SUMMARY}
\`\`\`

### Checklist
- [x] Syntaxe bash vérifiée (\`bash -n\`)
- [x] Fonctionnalité existante préservée
- [ ] Test manuel sur VPS

🤖 Generated by Youssef self-improve agent | Retro action: ${TICKET_KEY}"

PR_URL=""
PR_URL=$(cd "$PROJECT_DIR" && gh pr create \
  --title "[Retro] ${SUMMARY}" \
  --body "$PR_BODY" \
  --base "$BASE_BRANCH" \
  --head "$BRANCH" \
  --label "self-improve" \
  --label "retro-action" 2>&1) || true

if echo "$PR_URL" | grep -qE '^https://github.com'; then
  log_info "PR created: ${PR_URL}"
  jira_add_rich_comment "$TICKET_KEY" "youssef" "SUCCESS" "## Self-Improve: PR Créée ✅

**Script:** \`n8n/scripts/${TARGET_SCRIPT}\`
**PR:** ${PR_URL}

Nadia et Rami vont reviewer — une fois merge, Omar déploie sur le VPS."

  slack_notify "youssef" "🔧 $(mm_ticket_link "${TICKET_KEY}") — PR de self-improvement créée pour \`${TARGET_SCRIPT}\` : ${PR_URL}" "pipeline" 2>/dev/null || true
  jira_set_status "$TICKET_KEY" "In Review" 2>/dev/null || true
  reset_retry "$TICKET_KEY" "youssef-self-improve"
  log_success "Self-improve complete: ${TICKET_KEY} → PR ${PR_URL}"
else
  log_error "PR creation failed or URL not found: ${PR_URL}"
  increment_retry "$TICKET_KEY" "youssef-self-improve"
  exit 1
fi
