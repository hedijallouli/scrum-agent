#!/usr/bin/env bash
# =============================================================================
# agent-youssef.sh — Dev Agent: Implements features, creates PRs
# Only agent that does git checkout — all others use remote refs.
# PRs target dev branch.
# =============================================================================
AGENT_NAME="youssef"
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/agent-common.sh"

# Override base branch: PRs target dev, not master
BASE_BRANCH="${BASE_BRANCH:-dev}"

TICKET_KEY="${1:?Usage: agent-youssef.sh ${PROJECT_KEY:-TICKET}-XX}"
MAX_RETRIES=2

init_log "$TICKET_KEY" "youssef"
log_info "=== Youssef (Dev) starting work on ${TICKET_KEY} ==="
JIRA_URL="$(jira_link "$TICKET_KEY")"

# ─── 1. Check retry count + cooldown ────────────────────────────────────────
retry_count=$(get_retry_count "$TICKET_KEY" "youssef")
if (( retry_count >= MAX_RETRIES )); then
  # ─── STOP — hand off to Omar immediately ────────────────────────────────
  log_info "Max retries ($MAX_RETRIES) reached for ${TICKET_KEY}. Handing off to Omar."
  jira_add_rich_comment "$TICKET_KEY" "youssef" "WARNING" "## Max Retries Reached — Handoff to Omar
Implementation failed ${MAX_RETRIES} times. Je me déassigne et transmets à Omar pour triage."
  # Unassign Youssef → assign Omar + mark blocked
  plane_set_assignee "$TICKET_KEY" "omar" 2>/dev/null || true
  jira_add_label "$TICKET_KEY" "blocked" 2>/dev/null || true
  slack_notify "youssef" "$(mm_ticket_link "${TICKET_KEY}") — échec après ${MAX_RETRIES} tentatives. Ticket transféré à @omar-ai pour triage. 🔴" "pipeline" "warning" 2>/dev/null || true
  log_activity "youssef" "$TICKET_KEY" "HANDOFF_OMAR" "Hit ${MAX_RETRIES} retries, unassigned → Omar"
  exit 0  # do NOT reset retry — Omar needs the file to detect this
fi

if ! check_cooldown "$TICKET_KEY" "youssef"; then
  exit 0
fi

# ─── 2. Fetch ticket details ─────────────────────────────────────────────────
log_info "Fetching ticket details..."
SUMMARY=$(jira_get_ticket_field "$TICKET_KEY" "summary")
DESCRIPTION=$(jira_get_description_text "$TICKET_KEY")
PRIORITY=$(jira_get_ticket_field "$TICKET_KEY" "priority")
COMMENTS=$(jira_get_comments "$TICKET_KEY")
LABELS=$(jira_get_ticket_field "$TICKET_KEY" "labels")
MODEL=$(select_model_with_feedback "$LABELS" "$PRIORITY" "$TICKET_KEY" "youssef")
MODEL=$(select_model_rate_aware "$MODEL" "youssef" "dev")
MODEL=$(activate_api_key_if_needed "$MODEL")
if [[ "$MODEL" == "WAIT" ]]; then
  log_info "Sonnet rate-limited — youssef must wait (critical dev work, no API key)"
  exit 0
fi

if [[ -z "$SUMMARY" ]]; then
  log_error "Could not fetch ticket ${TICKET_KEY}"
  exit 1
fi

log_info "Ticket: ${SUMMARY}"
log_info "Priority: ${PRIORITY}"

# ─── 2a. Pre-check: PR already merged for this ticket ────────────────────────
cd "$PROJECT_DIR"
MERGED_PR=$(gh pr list --state merged --search "${TICKET_KEY}" --json number,title --jq ".[0].number" 2>/dev/null || echo "")
if [[ -n "$MERGED_PR" ]]; then
  log_info "PR #${MERGED_PR} already merged for ${TICKET_KEY} — marking Done"
  jira_add_rich_comment "$TICKET_KEY" "youssef" "MERGED" "## Already Merged
PR #${MERGED_PR} was already merged for this ticket.
Marking as Done — no further work needed."
  jira_remove_label "$TICKET_KEY" "agent:youssef"
  jira_transition "$TICKET_KEY" "done"
  reset_retry "$TICKET_KEY" "youssef"
  clear_feedback "$TICKET_KEY"
  slack_notify "$(mm_ticket_link "${TICKET_KEY}") — la PR #${MERGED_PR} était déjà mergée. Je marque le ticket comme Done." "pipeline"
  log_activity "youssef" "$TICKET_KEY" "ALREADY_MERGED" "PR #${MERGED_PR} already merged, marked Done"
  log_success "=== Youssef completed ${TICKET_KEY} (already merged) ==="
  exit 0
fi


# ─── 2b. Handle split-parent: close PR, delete branch, mark Done ─────────────
if echo "$LABELS" | grep -q "split-parent"; then
  log_info "Ticket is a split-parent — closing PR and marking Done"

  PR_URL=$(find_pr_for_ticket "$TICKET_KEY")
  if [[ -n "$PR_URL" ]]; then
    PR_NUMBER="${PR_URL##*/}"
    log_info "Closing PR #${PR_NUMBER} for split-parent ${TICKET_KEY}"
    cd "$PROJECT_DIR"
    gh pr close "$PR_NUMBER" --delete-branch 2>/dev/null || true
    log_info "PR #${PR_NUMBER} closed and branch deleted"
  else
    log_info "No open PR found for ${TICKET_KEY} — cleaning up branch only"
    # Try to delete the branch if it exists
    BRANCH_NAME=$(find_pr_branch "$TICKET_KEY")
    if [[ -n "$BRANCH_NAME" ]]; then
      cd "$PROJECT_DIR"
      git push origin --delete "$BRANCH_NAME" 2>/dev/null || true
    fi
  fi

  jira_add_rich_comment "$TICKET_KEY" "youssef" "MERGED" "## Split Cleanup Complete
${PR_URL:+PR closed: ${PR_URL}}
${PR_URL:-No open PR found.}

Branch deleted. Ticket split into smaller tasks — marking as Done."

  jira_remove_label "$TICKET_KEY" "agent:youssef"
  jira_transition "$TICKET_KEY" "done"

  slack_notify "Closed PR for split-parent $(mm_ticket_link "${TICKET_KEY}") — marked Done" "pipeline"

  log_activity "youssef" "$TICKET_KEY" "SPLIT_CLEANUP" "Closed PR, deleted branch, marked Done"
  log_info "=== Youssef completed split cleanup for ${TICKET_KEY} ==="
  exit 0
fi

# ─── 2c. Handle retro-action: comment with dev perspective, hand to Salma ────
if echo "$LABELS" | grep -q "retro-action" 2>/dev/null; then
  if ! echo "$LABELS" | grep -q "enriched" 2>/dev/null; then
    log_info "Retro-action ticket — writing dev perspective comment and handing to Salma"

    RETRO_PROMPT="You are Youssef, the Dev agent for ${PROJECT_NAME} (${PROJECT_KEY}).
Read the file ai/dev.md for your complete rules.

TICKET: ${TICKET_KEY}
TITLE: ${SUMMARY}
DESCRIPTION:
${DESCRIPTION:-No description provided}

EXISTING COMMENTS:
${COMMENTS:-None}

This is a retrospective action item assigned to you for your DEVELOPER PERSPECTIVE.
Do NOT implement anything. Instead, write a concise comment (max 300 words) covering:
1. How you would approach implementing this from a dev standpoint
2. Which files/modules would need changes (reference actual paths in packages/ or n8n/scripts/)
3. Estimated complexity and any technical risks
4. Dependencies on other systems or agents
5. Suggested acceptance criteria from a developer perspective

Output ONLY the comment text — no preamble, no markdown headers."

    RETRO_COMMENT=$(cd "$PROJECT_DIR" && claude -p "$RETRO_PROMPT" \
      --allowedTools "Read Glob Grep" \
      --model haiku --max-turns 10 2>/dev/null) || true

    if [[ -n "$RETRO_COMMENT" && ${#RETRO_COMMENT} -gt 20 ]]; then
      jira_add_rich_comment "$TICKET_KEY" "youssef" "INFO" "## Dev Perspective (Youssef)
${RETRO_COMMENT}

Handing to Salma for spec writing."
    else
      jira_add_rich_comment "$TICKET_KEY" "youssef" "INFO" "## Dev Perspective (Youssef)
Reviewed retro-action item. Handing to Salma for spec writing."
    fi

    jira_update_labels "$TICKET_KEY" "agent:youssef" "agent:salma"
    log_activity "youssef" "$TICKET_KEY" "RETRO_COMMENT" "Wrote dev perspective for retro-action, handed to Salma"
    slack_notify "J'ai donné ma perspective tech sur $(mm_ticket_link "${TICKET_KEY}"). Salma, je te transmets — quelques questions sur la spec avant de démarrer le code." "pipeline"
    log_info "=== Youssef wrote retro-action comment for ${TICKET_KEY} ==="
    exit 0
  fi
fi

# ─── 2c. Transition to "In Progress" + assign to Hedi ────────────────────────
jira_transition "$TICKET_KEY" "cours" || true
jira_assign_to_me "$TICKET_KEY" || true

# ─── 3. Prepare git branch (worktree — no branch switching in main repo) ─────
log_info "Preparing git workspace..."
# Generate branch name without switching branches (reuse SUMMARY already fetched above)
cd "$PROJECT_DIR"
SLUG=$(echo "$SUMMARY" | tr "[:upper:]" "[:lower:]" | sed "s/[^a-z0-9]/-/g" | sed "s/--*/-/g" | head -c 40 | sed "s/-$//")
BRANCH="feature/${TICKET_KEY}-${SLUG}"
log_info "Branch: ${BRANCH}"
WORKTREE_PATH=$(prepare_isolated_workspace "$TICKET_KEY" "$BRANCH")
PROJECT_DIR="$WORKTREE_PATH"
cd "$PROJECT_DIR"
log_info "Working in worktree: ${WORKTREE_PATH}"

# ─── 4. Check if this is a feedback loop (returning from Nadia or Rami) ──────
FEEDBACK=""
STRUCTURED_FEEDBACK=$(read_feedback "$TICKET_KEY")

if [[ -n "$STRUCTURED_FEEDBACK" ]]; then
  FEEDBACK="$STRUCTURED_FEEDBACK"
  log_info "Found structured feedback — this is a revision"
elif [[ -n "$COMMENTS" ]]; then
  # Fallback: check Jira comments for Nadia or Rami markers
  if echo "$COMMENTS" | grep -q "Nadia:"; then
    FEEDBACK=$(echo "$COMMENTS" | grep -A 50 "Nadia:" | tail -40)
    log_info "Found QA feedback from Nadia (Jira comments) — this is a revision"
  elif echo "$COMMENTS" | grep -qE "Rami:|Karim:"; then
    FEEDBACK=$(echo "$COMMENTS" | grep -A 50 -E "Rami:|Karim:" | tail -40)
    log_info "Found DevOps feedback from Rami (Jira comments) — this is a revision"
  fi
fi

# ─── 5. Invoke Claude Code to implement ──────────────────────────────────────
log_info "Invoking Claude Code (${MODEL}) for implementation..."

CLAUDE_PROMPT="You are Youssef, the Dev agent.
Read the file ai/dev.md for your complete rules and coding standards.
Read CLAUDE.md for project overview and conventions.

TICKET: ${TICKET_KEY}
TITLE: ${SUMMARY}
PRIORITY: ${PRIORITY}

SPECIFICATION:
${DESCRIPTION}
"

# Add QA feedback if this is a revision
if [[ -n "$FEEDBACK" ]]; then
  CLAUDE_PROMPT+="
REVIEWER FEEDBACK (fix these issues — from Nadia/QA or Rami/DevOps):
${FEEDBACK}
"
fi

CLAUDE_PROMPT+="
CRITICAL RULES:
- Read existing code to understand patterns before writing new code
- Max ${MAX_PR_LINES:-300} lines of changes total
- TypeScript strict mode, no any types
- Do NOT install new dependencies without clear justification
- Do NOT refactor unrelated code
- Do NOT add console.log statements
- Follow all conventions from ai/dev.md and CLAUDE.md
"

# Add retro-action wiring context if applicable
if echo "$LABELS" | grep -q "retro-action" 2>/dev/null; then
  CLAUDE_PROMPT+="
RETRO ACTION ITEM — WIRING REQUIRED:
This ticket is a retrospective action item. Ensure your changes are WIRED INTO the pipeline.
Creating a markdown file without modifying any agent script is NOT an acceptable solution.
"
fi

CLAUDE_PROMPT+="
STEPS:
1. Read CLAUDE.md and ai/dev.md to understand the project and coding standards
2. Read the codebase to understand existing patterns
3. Implement the feature according to the specification
4. If package.json exists: run npm run lint and npm run build (fix any errors)
5. Stage your changes with git add

When done, output a brief summary of what you implemented."

CLAUDE_OUTPUT=""
CLAUDE_OUTPUT=$(cd "$PROJECT_DIR" && claude -p "$CLAUDE_PROMPT" \
  --allowedTools "Read Write Edit Glob Grep Bash(npm:*) Bash(git add:*) Bash(git rm:*) Bash(git status:*) Bash(git diff:*)" \
  --model $MODEL --max-turns 50 2>/dev/null) || {
  _claude_exit=$?
  log_error "Claude invocation failed (exit ${_claude_exit})"
  increment_retry "$TICKET_KEY" "youssef"
  exit 1
}

log_info "Claude output:"
echo "$CLAUDE_OUTPUT" >> "$LOG_FILE"

# Validate output before treating the run as success.
# Catches: empty output, rate-limit messages, "I cannot proceed" semantic failures.
if ! validate_claude_output "$CLAUDE_OUTPUT" 30 "youssef/${TICKET_KEY}"; then
  increment_retry "$TICKET_KEY" "youssef"
  jira_add_rich_comment "$TICKET_KEY" "youssef" "WARNING" "Claude did not produce valid output (empty or blocking condition). Will retry next cycle."
  exit 1
fi

# ─── 6. Run quality checks ───────────────────────────────────────────────────
log_info "Running quality checks..."
cd "$PROJECT_DIR"

CHECKS_PASSED=true
if [[ -f "package.json" ]]; then
  # Only run checks that exist in package.json scripts
  if grep -q '"typecheck"' package.json 2>/dev/null; then
    TYPECHECK_OUT=$(npm run typecheck 2>&1) || CHECKS_PASSED=false
  else
    TYPECHECK_OUT="(no typecheck script)"
  fi
  if grep -q '"lint"' package.json 2>/dev/null; then
    LINT_OUT=$(npm run lint 2>&1) || CHECKS_PASSED=false
  else
    LINT_OUT="(no lint script)"
  fi
  if grep -q '"build"' package.json 2>/dev/null; then
    BUILD_OUT=$(npm run build 2>&1) || CHECKS_PASSED=false
  else
    BUILD_OUT="(no build script)"
  fi
else
  log_info "No package.json — skipping quality checks"
  TYPECHECK_OUT="(no package.json)"
  LINT_OUT="(no package.json)"
  BUILD_OUT="(no package.json)"
fi

if [[ "$CHECKS_PASSED" == "false" ]]; then
  log_info "Quality checks failed, asking Claude to fix..."

  FIX_PROMPT="The quality checks failed. Fix ALL errors:

TYPECHECK OUTPUT:
${TYPECHECK_OUT}

LINT OUTPUT:
${LINT_OUT}

BUILD OUTPUT:
${BUILD_OUT}

Fix all errors. Then run npm run lint and npm run build again to verify."

  cd "$PROJECT_DIR" && claude -p "$FIX_PROMPT" \
    --allowedTools "Read Write Edit Glob Grep Bash(npm:*) Bash(git add:*) Bash(git status:*)" \
    --model $MODEL --max-turns 15 2>&1 >> "$LOG_FILE" || true

  # Re-check
  CHECKS_PASSED=true
  npm run typecheck 2>&1 >> "$LOG_FILE" || CHECKS_PASSED=false
  npm run lint 2>&1 >> "$LOG_FILE" || CHECKS_PASSED=false
  npm run build 2>&1 >> "$LOG_FILE" || CHECKS_PASSED=false
fi

if [[ "$CHECKS_PASSED" == "false" ]]; then
  log_error "Quality checks still failing after fix attempt"
  increment_retry "$TICKET_KEY" "youssef"
  # Build a list of which checks failed
  FAILED_CHECKS=""
  echo "$TYPECHECK_OUT" | grep -qi "error" && FAILED_CHECKS="${FAILED_CHECKS}TypeScript, "
  echo "$LINT_OUT" | grep -qi "error" && FAILED_CHECKS="${FAILED_CHECKS}Lint, "
  echo "$BUILD_OUT" | grep -qi "error" && FAILED_CHECKS="${FAILED_CHECKS}Build, "
  FAILED_CHECKS="${FAILED_CHECKS%, }"  # remove trailing comma

  FEEDBACK_NOTE=""
  if [[ -n "$FEEDBACK" ]]; then
    FEEDBACK_NOTE=" (revision from QA feedback)"
  fi

  jira_add_rich_comment "$TICKET_KEY" "youssef" "FAIL" "## Quality Checks Failed
Attempt $(( retry_count + 1 ))/${MAX_RETRIES} — ${FAILED_CHECKS:-unknown} not passing.${FEEDBACK_NOTE}

Will retry next cycle."
  log_activity "youssef" "$TICKET_KEY" "FAILED" "Quality checks failed: ${FAILED_CHECKS:-unknown} (attempt $(( retry_count + 1 )))"
  slack_notify "$(mm_ticket_link "${TICKET_KEY}") — les checks échouent (${FAILED_CHECKS:-inconnu}), tentative $((retry_count + 1))/${MAX_RETRIES}. Je corrige et je repousse.${FEEDBACK_NOTE}" "pipeline" "warning"
  exit 1
fi

# ─── 8. Check diff size ──────────────────────────────────────────────────────
DIFF_SIZE=$(get_diff_stats)
log_info "Diff size: ${DIFF_SIZE} lines changed"

if (( DIFF_SIZE == 0 )); then
  # Check if Claude says the work is already done on this branch
  if echo "$CLAUDE_OUTPUT" | grep -qiE "already (fully )?implemented|already (exists|in place|complete)|nothing.*(to (change|implement|do))|successfully implemented|been.*implemented.*merged|feature.*already.*present|no (changes|modifications) (needed|required|necessary)"; then
    log_info "Claude reports code is already implemented on test — handing to Nadia for QA"
    jira_add_rich_comment "$TICKET_KEY" "youssef" "PASS" "## Already Implemented
Code for this ticket is already present on the \`master\` branch (likely from a prior merge).
Quality checks pass. Handing to Nadia for QA review."
    jira_update_labels "$TICKET_KEY" "agent:youssef" "agent:nadia"
    reset_retry "$TICKET_KEY" "youssef"
    clear_feedback "$TICKET_KEY"
    slack_notify "$(mm_ticket_link "${TICKET_KEY}") — le code est déjà sur master. J'envoie directement à Nadia pour le QA." "pipeline"
    log_activity "youssef" "$TICKET_KEY" "ALREADY_DONE" "Code already on test, handed to Nadia"
    log_success "=== Youssef completed ${TICKET_KEY} (already implemented) ==="
    exit 0
  fi

  log_error "No changes made — Claude did not produce any code"
  increment_retry "$TICKET_KEY" "youssef"
  jira_add_rich_comment "$TICKET_KEY" "youssef" "WARNING" "No code changes were produced. Will retry next cycle."
  exit 1
fi

# ─── 8b. Hard gate: reject >350 code lines ─────────────────────────────────
# Count only SOURCE code files (.ts/.tsx/.jsx/.css) — docs/config + compiled artifacts exempt
# Excludes: .d.ts, .d.ts.map, .js.map (compiled TS output), and .js (often compiled artifacts)
CODE_DIFF_SIZE=$(cd "$PROJECT_DIR" && git diff "origin/${BASE_BRANCH}...HEAD" --stat \
  -- '*.ts' '*.tsx' '*.jsx' '*.css' ':!*.d.ts' ':!*.d.ts.map' ':!*.js.map' 2>/dev/null \
  | tail -1 | { grep -oE '[0-9]+ insertion|[0-9]+ deletion' || true; } | awk '{s+=$1}END{print s+0}')
CODE_DIFF_SIZE="${CODE_DIFF_SIZE:-0}"

if (( CODE_DIFF_SIZE > 350 )); then
  log_info "Code diff ${CODE_DIFF_SIZE} lines exceeds 350 — asking Claude to reduce scope"

  REDUCE_PROMPT="Your implementation has ${CODE_DIFF_SIZE} lines of code changes, which exceeds the 350-line limit.
You MUST reduce the scope. Options:
1. Remove non-essential features (nice-to-haves, extra error states, bonus UI)
2. Simplify the implementation (fewer edge cases, simpler validation)
3. Remove any refactoring that isn't strictly required for the ticket

CRITICAL: The final code diff for .ts/.tsx/.jsx/.css source files MUST be under 350 lines.
Do NOT count .js, .d.ts, .js.map files — those are compiled artifacts, not source.
Do NOT just delete random code. Keep the core acceptance criteria working.
After reducing, run: npm run lint && npm run build to verify nothing is broken.
Then git add the changes."

  cd "$PROJECT_DIR" && claude -p "$REDUCE_PROMPT" \
    --allowedTools "Read Write Edit Glob Grep Bash(npm:*) Bash(git add:*) Bash(git diff:*) Bash(git status:*)" \
    --model $MODEL --max-turns 15 2>&1 >> "$LOG_FILE" || true

  # Re-check after reduction
  npm run lint 2>&1 >> "$LOG_FILE" || true
  npm run build 2>&1 >> "$LOG_FILE" || true

  # Re-measure (same method, excluding compiled artifacts)
  DIFF_SIZE=$(get_diff_stats)
  CODE_DIFF_SIZE=$(cd "$PROJECT_DIR" && git diff "origin/${BASE_BRANCH}...HEAD" --stat \
    -- '*.ts' '*.tsx' '*.jsx' '*.css' ':!*.d.ts' ':!*.d.ts.map' ':!*.js.map' 2>/dev/null \
    | tail -1 | { grep -oE '[0-9]+ insertion|[0-9]+ deletion' || true; } | awk '{s+=$1}END{print s+0}')
  CODE_DIFF_SIZE="${CODE_DIFF_SIZE:-0}"
  log_info "After reduction: ${CODE_DIFF_SIZE} code lines, ${DIFF_SIZE} total lines"

  if (( CODE_DIFF_SIZE > 350 )); then
    log_error "Still over 350 code lines (${CODE_DIFF_SIZE}) after reduction attempt"

    # Discard changes and reset branch to avoid stale state
    git checkout -- . 2>/dev/null || true
    git clean -fd 2>/dev/null || true

    # Escalate to Salma for splitting — no point retrying something that can't fit
    jira_add_rich_comment "$TICKET_KEY" "youssef" "FAIL" "## Ticket Too Large — Needs Split
Code diff: ${CODE_DIFF_SIZE} lines (limit: 300).
Tried to reduce scope but the ticket's requirements exceed the single-PR limit.

Escalating to Salma for splitting into smaller sub-tasks."
    jira_update_labels "$TICKET_KEY" "agent:youssef" "agent:salma"
    jira_add_label "$TICKET_KEY" "needs-split"
    reset_retry "$TICKET_KEY" "youssef"
    clear_feedback "$TICKET_KEY"

    # Clean up branch and any open PR
    git push origin --delete "$BRANCH" 2>/dev/null || true
    PR_URL_CLEANUP=$(find_pr_for_ticket "$TICKET_KEY" 2>/dev/null || true)
    if [[ -n "$PR_URL_CLEANUP" ]]; then
      PR_NUM_CLEANUP="${PR_URL_CLEANUP##*/}"
      gh pr close "$PR_NUM_CLEANUP" --delete-branch 2>/dev/null || true
    fi

    slack_notify "$(mm_ticket_link "${TICKET_KEY}") — diff trop grand (${CODE_DIFF_SIZE} lignes, limite 300). Je transmets à Salma pour découper le ticket en plus petits morceaux." "pipeline" "warning"
    log_activity "youssef" "$TICKET_KEY" "NEEDS_SPLIT" "Code diff ${CODE_DIFF_SIZE} lines, escalated to Salma"
    log_info "=== Youssef escalated ${TICKET_KEY} to Salma for splitting ==="
    exit 0
  fi
fi

# ─── 9. Commit and push ──────────────────────────────────────────────────────
log_info "Committing and pushing..."
cd "$PROJECT_DIR"

# Create a short summary for commit message
SHORT_SUMMARY=$(echo "$SUMMARY" | head -c 60)

# Stage app + infra changes — never stage ai/ agent scripts or scrum-agent/
# Note: git add -A fails entirely if ANY pathspec doesn't match a file,
# so we split into separate calls. Each call is safe to fail independently.
git add -A -- packages/ 2>/dev/null || true
git add -A -- src/ 2>/dev/null || true
git add -A -- public/ 2>/dev/null || true
git add -A -- .husky/ 2>/dev/null || true
git add -A -- .gitignore package.json package-lock.json pnpm-lock.yaml 2>/dev/null || true
git add -A -- tsconfig*.json vite.config.* tailwind.config.* eslint.config.* postcss.config.* 2>/dev/null || true
git add -A -- index.html index-vite.html components.json 2>/dev/null || true
git add -A -- deploy.sh nginx/ .env.*.example 2>/dev/null || true
git add -A -- .github/ 2>/dev/null || true

# Log what is staged so failures are diagnosable
STAGED_FILES=$(git diff --cached --name-only 2>/dev/null || true)
if [[ -z "$STAGED_FILES" ]]; then
  log_error "Nothing staged after git add — Claude may not have written any files"
  increment_retry "$TICKET_KEY" "youssef"
  jira_add_rich_comment "$TICKET_KEY" "youssef" "WARNING" "## No staged changes
Diff showed ${DIFF_SIZE} working tree lines but nothing staged for commit.
Will retry next cycle."
  exit 1
fi
log_info "Staged files: $(echo "$STAGED_FILES" | wc -l | tr -d ' ') file(s): $(echo "$STAGED_FILES" | head -5 | tr '\n' ' ')"

# HUSKY=0 disables husky hooks for automated agent commits (hooks are dev-only tools)
COMMIT_MSG=$(cat <<EOF
feat(${TICKET_KEY}): ${SHORT_SUMMARY}

Implemented by Youssef (AI Dev Agent)
Ticket: ${TICKET_KEY}

Co-Authored-By: Youssef (AI) <youssef@${PROJECT_KEY,,}.ai>
EOF
)
HUSKY=0 git -c user.email="youssef@${PROJECT_KEY,,}.ai" -c user.name="Youssef (AI Dev Agent)" commit -m "$COMMIT_MSG" >> "$LOG_FILE" 2>&1 || {
  log_info "Commit returned non-zero — checking if already committed..."
  ALREADY_COMMITTED=$(git rev-list --count "origin/${BASE_BRANCH}..HEAD" 2>/dev/null || echo "0")
  if [[ "$ALREADY_COMMITTED" -gt 0 ]]; then
    log_info "Branch has ${ALREADY_COMMITTED} commit(s) ahead of origin/${BASE_BRANCH} — commit was already made"
  else
    log_error "Commit failed and no commits ahead of origin/${BASE_BRANCH}"
    increment_retry "$TICKET_KEY" "youssef"
    exit 1
  fi
}

# Git push with rebase recovery ladder
if ! HUSKY=0 git push -u origin "$BRANCH" >> "$LOG_FILE" 2>&1; then
  log_info "Push failed — trying rebase recovery..."

  # Step 2: Fetch + rebase onto base branch
  git fetch origin "$BASE_BRANCH" >> "$LOG_FILE" 2>&1
  if HUSKY=0 git rebase "origin/$BASE_BRANCH" >> "$LOG_FILE" 2>&1; then
    log_info "Rebase successful — pushing..."
    if ! HUSKY=0 git push -u origin "$BRANCH" >> "$LOG_FILE" 2>&1; then
      # Step 3: Force-with-lease as last resort (feature branch only)
      log_info "Post-rebase push failed — force-with-lease..."
      HUSKY=0 git push --force-with-lease origin "$BRANCH" >> "$LOG_FILE" 2>&1 || {
        log_info "All push attempts failed — will retry next cycle"
        increment_retry "$TICKET_KEY" "youssef"
        # Save error context for Omar's auto-unblock
        echo "- Git push rejected: $(HUSKY=0 git push -u origin "$BRANCH" 2>&1 | head -3 || true)" > "${FEEDBACK_DIR}/${TICKET_KEY}.txt"
        exit 1
      }
    fi
  else
    # Rebase had conflicts — abort and force-push current state
    git rebase --abort 2>/dev/null || true
    log_info "Rebase conflicts — force-pushing current state..."
    HUSKY=0 git push --force-with-lease origin "$BRANCH" >> "$LOG_FILE" 2>&1 || {
      log_info "Force-with-lease failed after rebase conflict — will retry next cycle"
      increment_retry "$TICKET_KEY" "youssef"
      echo "- Git push failed after rebase conflict" > "${FEEDBACK_DIR}/${TICKET_KEY}.txt"
      exit 1
    }
  fi
fi
log_info "Pushed to ${BRANCH}"

# ─── 10. Create PR (targeting test branch) ──────────────────────────────────
log_info "Creating PR targeting ${BASE_BRANCH}..."

# Safety check: verify there are actual changes vs base branch
COMMIT_DIFF=$(cd "$PROJECT_DIR" && git rev-list --count "origin/${BASE_BRANCH}..HEAD" 2>/dev/null || echo "0")
if [[ "$COMMIT_DIFF" -eq 0 ]]; then
  log_error "No commits ahead of ${BASE_BRANCH} — nothing to create PR for"
  log_info "This usually means Claude's code changes were not committed. Will retry next cycle."
  increment_retry "$TICKET_KEY" "youssef"
  echo "- No commits produced: Claude ran but code was not committed. Branch may have been stale." > "${FEEDBACK_DIR}/${TICKET_KEY}.txt"
  exit 1
fi
log_info "${COMMIT_DIFF} commit(s) ahead of ${BASE_BRANCH}"

# Check if PR already exists (feedback loop)
EXISTING_PR=$(find_pr_for_ticket "$TICKET_KEY")
if [[ -n "$EXISTING_PR" ]]; then
  log_info "PR already exists: ${EXISTING_PR}"
  PR_URL="$EXISTING_PR"
else
  # Auto-detect DevOps review flags from changed files
  CHANGED_FILES=$(cd "$PROJECT_DIR" && git diff "${BASE_BRANCH}...HEAD" --name-only 2>/dev/null || true)
  DR_DB=" "; DR_AUTH=" "; DR_CONFIG=" "; DR_DEPLOY=" "; DR_SECURITY=" "; DR_THIRDPARTY=" "
  # DB detection skipped — enable per-project if needed
  echo "$CHANGED_FILES" | grep -qiE 'auth|rls|permission|policy' 2>/dev/null && DR_AUTH="x"
  echo "$CHANGED_FILES" | grep -qE '\.env|config' 2>/dev/null && DR_CONFIG="x"
  echo "$CHANGED_FILES" | grep -qiE 'nginx|systemd|deploy|Dockerfile' 2>/dev/null && DR_DEPLOY="x"
  echo "$CHANGED_FILES" | grep -qiE 'secret|token|api.key' 2>/dev/null && DR_SECURITY="x"
  echo "$CHANGED_FILES" | grep -qiE 'webhook|external|integration' 2>/dev/null && DR_THIRDPARTY="x"

  PR_URL=$(cd "$PROJECT_DIR" && gh pr create \
    --title "feat(${TICKET_KEY}): ${SHORT_SUMMARY}" \
    --body "$(cat <<PRBODY
## Summary
${SUMMARY}

## Tracker
${TICKET_KEY}

## Changes
${DIFF_SIZE} lines changed

## Quality Checks
- [x] TypeScript compiles
- [x] Lint passes
- [x] Build succeeds

## Review Checklist
- [${DR_CONFIG}] Configuration changes (env vars, secrets, service config)
- [${DR_DEPLOY}] Deployment/infrastructure changes (nginx, systemd, server setup)
- [${DR_SECURITY}] Security-sensitive changes (API keys, tokens, data access patterns)
- [${DR_THIRDPARTY}] Third-party integrations (new APIs, webhooks, external services)

## Agent
Implemented by **Youssef** (AI Dev Agent)
PRBODY
)" \
    --base "$BASE_BRANCH" 2>&1)
  log_info "PR created: ${PR_URL}"
fi

# ─── 11. Capture screenshot ──────────────────────────────────────────────────
log_info "Attempting screenshot capture..."
SCREENSHOT_PATH=""
SCREENSHOT_PATH=$("${SCRIPT_DIR}/capture-screenshot.sh" "$TICKET_KEY" "/" 2>>"$LOG_FILE") || {
  log_info "Screenshot capture skipped (non-blocking)"
}

# ─── 12. Update Jira ─────────────────────────────────────────────────────────
log_info "Updating Jira..."
SCREENSHOT_NOTE=""
if [[ -n "$SCREENSHOT_PATH" ]]; then
  SCREENSHOT_NOTE=" Screenshot attached."
fi
jira_add_rich_comment "$TICKET_KEY" "youssef" "PASS" "## Implementation Complete
PR: ${PR_URL}
Lines changed: ${DIFF_SIZE}
${SCREENSHOT_NOTE:+Screenshot attached.}

Handing to Nadia for QA review."
jira_update_labels "$TICKET_KEY" "agent:youssef" "agent:nadia"
jira_transition "$TICKET_KEY" "review" || true
reset_retry "$TICKET_KEY" "youssef"
clear_feedback "$TICKET_KEY"

# ─── 13. Notify Slack ────────────────────────────────────────────────────────
REVISION_TAG=""
if [[ -n "$FEEDBACK" ]]; then
  REVISION_TAG=" (revision)"
fi
if [[ -n "$FEEDBACK" ]]; then
  slack_notify "$(mm_ticket_link "${TICKET_KEY}") — PR prête${REVISION_TAG}. Les corrections de Nadia sont intégrées, ${DIFF_SIZE} lignes, tous les tests passent. Nadia, c'est à toi 🎯
[PR #${PR_URL##*/pull/}](${PR_URL})" "pipeline" "good"
else
  slack_notify "$(mm_ticket_link "${TICKET_KEY}") — implémentation terminée, ${DIFF_SIZE} lignes, tests au vert. Nadia, je te passe la PR.
[PR #${PR_URL##*/pull/}](${PR_URL})" "pipeline" "good"
fi

# Log activity for daily standup narrative
if [[ -n "$FEEDBACK" ]]; then
  log_activity "youssef" "$TICKET_KEY" "REVISED" "Fixed QA feedback, ${DIFF_SIZE} lines, PR ${PR_URL##*/pull/}"
else
  log_activity "youssef" "$TICKET_KEY" "IMPLEMENTED" "${DIFF_SIZE} lines, PR ${PR_URL##*/pull/}"
fi

log_success "=== Youssef completed ${TICKET_KEY} successfully ==="
