#!/usr/bin/env bash
# =============================================================================
# agent-karim.sh — DevOps Agent: Automated checks only (no Claude), auto-merge
# Uses remote refs (no git checkout) so it can run parallel with Youssef.
# NO Claude call — pure automated checks.
# =============================================================================
AGENT_NAME="karim"
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/agent-common.sh"

TICKET_KEY="${1:?Usage: agent-karim.sh BISB-XX}"
MAX_RETRIES=3

init_log "$TICKET_KEY" "karim"
log_info "=== Karim (DevOps) starting verification of ${TICKET_KEY} ==="
JIRA_URL="$(jira_link "$TICKET_KEY")"

# ─── 1. Check retry count + cooldown ────────────────────────────────────────
retry_count=$(get_retry_count "$TICKET_KEY" "karim")
if (( retry_count >= MAX_RETRIES )); then
  # ─── STOP — let Omar auto-unblock and standup decide ────────────────────
  log_info "Max retries ($MAX_RETRIES) reached for ${TICKET_KEY}. Waiting for Omar to route to standup."
  jira_add_rich_comment "$TICKET_KEY" "karim" "WARNING" "## Max Retries Reached
DevOps checks failed ${MAX_RETRIES} times. Waiting for standup round-table."
  log_activity "karim" "$TICKET_KEY" "MAX_RETRIES" "Hit ${MAX_RETRIES} retries, waiting for Omar"
  exit 0  # do NOT reset retry — Omar needs the file to detect this
fi

if ! check_cooldown "$TICKET_KEY" "karim"; then
  exit 0
fi

# ─── 2. Fetch ticket details ─────────────────────────────────────────────────
log_info "Fetching ticket details..."
SUMMARY=$(jira_get_ticket_field "$TICKET_KEY" "summary")

if [[ -z "$SUMMARY" ]]; then
  log_error "Could not fetch ticket ${TICKET_KEY}"
  exit 1
fi

log_info "Ticket: ${SUMMARY}"

# ─── 2b. Handle retro-action: comment with DevOps perspective, hand to Salma ─
LABELS=$(jira_get_ticket_field "$TICKET_KEY" "labels")
if echo "$LABELS" | grep -q "retro-action" 2>/dev/null; then
  if ! echo "$LABELS" | grep -q "enriched" 2>/dev/null; then
    log_info "Retro-action ticket — writing DevOps perspective comment and handing to Salma"

    DESCRIPTION=$(jira_get_description_text "$TICKET_KEY")
    COMMENTS=$(jira_get_comments "$TICKET_KEY")

    # Karim has no Claude call normally, but for retro-action comments we use Haiku
    RETRO_PROMPT="You are Karim, the DevOps agent for BisB (Business is Business).

TICKET: ${TICKET_KEY}
TITLE: ${SUMMARY}
DESCRIPTION:
${DESCRIPTION:-No description provided}

EXISTING COMMENTS:
${COMMENTS:-None}

This is a retrospective action item assigned to you for your DEVOPS PERSPECTIVE.
Do NOT run any checks. Instead, write a concise comment (max 300 words) covering:
1. How this action item affects CI/CD, deployment, or infrastructure
2. Security implications (secrets, env vars, access control)
3. What automated checks could enforce this improvement
4. Impact on the merge pipeline (your automated checks)
5. Suggested acceptance criteria from a DevOps perspective

IMPORTANT: Consider your own constraints:
- You run ONLY automated diff-based checks (no Claude, no file reading)
- You check for: .env files, hardcoded secrets, console.log, PR size, dangerous operations
- BisB uses npm workspaces (packages/engine + packages/web), Vitest for tests
- Any new checks must be implementable as grep/diff patterns in agent-karim.sh

Output ONLY the comment text — no preamble, no markdown headers."

    RETRO_COMMENT=$(cd "$PROJECT_DIR" && claude -p "$RETRO_PROMPT" \
      --disallowedTools "Read Write Edit Glob Grep Bash" \
      --model haiku --max-turns 1 2>/dev/null) || true

    if [[ -n "$RETRO_COMMENT" && ${#RETRO_COMMENT} -gt 20 ]]; then
      jira_add_rich_comment "$TICKET_KEY" "karim" "INFO" "## DevOps Perspective (Karim)
${RETRO_COMMENT}

Handing to Salma for spec writing."
    else
      jira_add_rich_comment "$TICKET_KEY" "karim" "INFO" "## DevOps Perspective (Karim)
Reviewed retro-action item. Handing to Salma for spec writing."
    fi

    jira_update_labels "$TICKET_KEY" "agent:karim" "agent:salma"
    log_activity "karim" "$TICKET_KEY" "RETRO_COMMENT" "Wrote DevOps perspective for retro-action, handed to Salma"
    slack_notify "Wrote DevOps perspective on *<$(jira_link "$TICKET_KEY")|${TICKET_KEY}>* — handed to Salma for spec" "pipeline"
    log_info "=== Karim wrote retro-action comment for ${TICKET_KEY} ==="
    exit 0
  fi
fi

# ─── 3. Find the PR ──────────────────────────────────────────────────────────
log_info "Looking for PR..."
cd "$PROJECT_DIR"

PR_URL=$(find_pr_for_ticket "$TICKET_KEY")
if [[ -z "$PR_URL" ]]; then
  log_error "No open PR found for ${TICKET_KEY}"
  jira_add_rich_comment "$TICKET_KEY" "karim" "BLOCKED" "No open PR found for this ticket. Cannot verify."
  exit 1
fi

log_info "Found PR: ${PR_URL}"

# Get PR branch and number
PR_BRANCH=$(find_pr_branch "$TICKET_KEY")
if [[ -z "$PR_BRANCH" ]]; then
  log_error "Could not determine PR branch for ${TICKET_KEY}"
  exit 1
fi

# Extract PR number from URL
PR_NUMBER=$(echo "$PR_URL" | grep -oE '[0-9]+$')

# ─── 4. Fetch remote refs (NO checkout — Youssef may be working) ────────────
log_info "Fetching remote refs for verification..."
cd "$PROJECT_DIR"
git fetch origin 2>/dev/null

# ─── 5. Run automated security & quality checks (remote refs only) ──────────
log_info "Running DevOps verification checks (remote refs)..."

# New spec format (ai/templates/spec-template.md) flags requirements as:
# - "validated in pipeline" → automated checks below (no human review)
# - "requires manual Karim review" → escalate if infra/credential changes detected
# Match your automated checks to 'validated in pipeline' items from spec CI Validation section

# Use string-based issues list (Bash 3.2 on macOS has bugs with empty arrays + set -u)
ISSUES_TEXT=""
CHECKS_PASSED=true

add_issue() {
  if [[ -n "$ISSUES_TEXT" ]]; then
    ISSUES_TEXT="${ISSUES_TEXT}
${1}"
  else
    ISSUES_TEXT="$1"
  fi
}

# Check 1: No .env files added or modified in diff (deletions are OK)
log_info "Check: No .env files in diff..."
ENV_FILES=$(git diff "${BASE_BRANCH}...origin/${PR_BRANCH}" --diff-filter=ACM --name-only 2>/dev/null | grep -E '\.env$' | grep -v '\.env\.example$' || true)
if [[ -n "$ENV_FILES" ]]; then
  add_issue "SECURITY: .env files added/modified in diff: ${ENV_FILES}"
  CHECKS_PASSED=false
fi

# Check 2: No hardcoded secrets (API keys, tokens, passwords)
log_info "Check: No hardcoded secrets..."
SECRETS_FOUND=$(git diff "${BASE_BRANCH}...origin/${PR_BRANCH}" 2>/dev/null \
  | grep '^\+' \
  | grep -iE '(api_key|api_secret|password|token|secret_key)\s*[:=]' \
  | grep -v 'process\.env\.' \
  | grep -v 'import\.meta\.env\.' \
  | grep -v 'env\.[A-Z_]' \
  | grep -v '= *env\.' \
  | grep -vE '\|\| *('"'"''"'"'|"")' \
  | grep -v 'timeout *:' \
  | grep -vE '= *[a-zA-Z_][a-zA-Z0-9_]*\.env\.' \
  | grep -vE 'const [A-Z_]+ *= *env\.[A-Z_]+' \
  || true)
if [[ -n "$SECRETS_FOUND" ]]; then
  add_issue "SECURITY: Potential hardcoded secrets found in diff"
  CHECKS_PASSED=false
fi

# Check 3: No console.log statements (only in .ts/.tsx/.js/.jsx files)
log_info "Check: No console.log..."
CONSOLE_LOGS=$(git diff "${BASE_BRANCH}...origin/${PR_BRANCH}" -- '*.ts' '*.tsx' '*.js' '*.jsx' 2>/dev/null | grep '^\+.*console\.\(log\|debug\|info\)' | grep -v '// eslint-disable' || true)
if [[ -n "$CONSOLE_LOGS" ]]; then
  add_issue "QUALITY: console.log statements found in new code"
  CHECKS_PASSED=false
fi

# Check 4: Code diff size under 300 lines (docs/config exempt)
# Exclude compiled TS artifacts (.d.ts, .d.ts.map, .js.map) from all size checks
DIFF_STATS=$(git diff "${BASE_BRANCH}...origin/${PR_BRANCH}" --stat \
  -- ':!*.d.ts' ':!*.d.ts.map' ':!*.js.map' 2>/dev/null)
DIFF_SIZE=$(echo "$DIFF_STATS" | tail -1 | { grep -oE '[0-9]+ insertion|[0-9]+ deletion' || true; } | awk '{s+=$1}END{print s+0}')
DIFF_SIZE="${DIFF_SIZE:-0}"
# Source code only: TypeScript/JSX/CSS, exclude compiled declaration files
CODE_DIFF_STAT=$(git diff "${BASE_BRANCH}...origin/${PR_BRANCH}" --stat \
  -- '*.ts' '*.tsx' '*.jsx' '*.css' ':!*.d.ts' ':!*.d.ts.map' 2>/dev/null || true)
CODE_DIFF_SIZE=$(echo "$CODE_DIFF_STAT" | tail -1 | { grep -oE '[0-9]+ insertion|[0-9]+ deletion' || true; } | awk '{s+=$1}END{print s+0}')
CODE_DIFF_SIZE="${CODE_DIFF_SIZE:-0}"
log_info "Code diff: ${CODE_DIFF_SIZE} lines (total: ${DIFF_SIZE})"
if (( CODE_DIFF_SIZE > 300 )); then
  add_issue "SIZE: PR has ${CODE_DIFF_SIZE} lines of CODE changed (limit: 300). Total with docs: ${DIFF_SIZE}"
  # Warning only, not a blocker
fi

# Check 5: No force-push markers or dangerous operations in code files
log_info "Check: No dangerous operations..."
DANGEROUS=$(git diff "${BASE_BRANCH}...origin/${PR_BRANCH}" -- '*.ts' '*.tsx' '*.js' '*.jsx' '*.sql' '*.sh' 2>/dev/null | grep -E '^\+.*(--force|--hard|DROP TABLE|TRUNCATE|DELETE FROM .* WHERE 1)' || true)
if [[ -n "$DANGEROUS" ]]; then
  add_issue "SECURITY: Potentially dangerous operations found in diff"
  CHECKS_PASSED=false
fi

# Check 6: No new dependencies without justification (check package.json changes)
log_info "Check: Dependencies..."
PKG_CHANGED=$(git diff "${BASE_BRANCH}...origin/${PR_BRANCH}" --name-only 2>/dev/null | grep -E 'package\.json$' || true)
if [[ -n "$PKG_CHANGED" ]]; then
  NEW_DEPS=$(git diff "${BASE_BRANCH}...origin/${PR_BRANCH}" -- package.json 2>/dev/null | grep '^\+.*"[^"]*":' | grep -v '"version"' | grep -v '"name"' | grep -v '"description"' || true)
  if [[ -n "$NEW_DEPS" ]]; then
    log_info "New dependencies detected (not a blocker, just noted)"
  fi
fi

# Check 7b: Parse PR body for DevOps review flags
log_info "Check: DevOps review flags in PR body..."
PR_BODY=$(gh pr view "$PR_NUMBER" --json body --jq '.body' 2>/dev/null || true)
if [[ -n "$PR_BODY" ]] && echo "$PR_BODY" | grep -q "## DevOps Review Required" 2>/dev/null; then
  # Extract only the DevOps Review Required section (exclude Quality Checks)
  # Use awk to extract from "## DevOps Review Required" to the next "##" header
  DEVOPS_SECTION=$(echo "$PR_BODY" | awk '/^## DevOps Review Required/,/^## / {if (/^## / && !/^## DevOps Review Required/) exit; print}')
  DEVOPS_FLAGS_CHECKED=$(echo "$DEVOPS_SECTION" | grep -c '\- \[x\]' 2>/dev/null || true)
  if (( DEVOPS_FLAGS_CHECKED > 0 )); then
    log_info "DevOps review flags found: ${DEVOPS_FLAGS_CHECKED} checked — noting for human review (not blocking)"
    CHECKED_ITEMS=$(echo "$DEVOPS_SECTION" | grep '\- \[x\]' | sed 's/- \[x\] /  - /' || true)
    # Note: DevOps flags are informational for human reviewer, not a blocker.
    # Karim passes the PR through — Hedi will see the flags during merge review.
    log_info "DevOps items for human review:
${CHECKED_ITEMS}"
  else
    log_info "DevOps review section present but no flags checked — OK"
  fi
fi

# Check 7c: PR size hard limit (350 lines total diff — source files only) — BLOCKING
# Excludes: compiled TS artifacts (.d.ts, .d.ts.map, .js.map) and lockfiles
# Rationale: UI features require component + CSS + store integration; 350 allows 1 new component
log_info "Check: PR size hard limit (350 lines)..."
TOTAL_DIFF=$(git diff "${BASE_BRANCH}...origin/${PR_BRANCH}" --shortstat \
  -- ':!*.d.ts' ':!*.d.ts.map' ':!*.js.map' ':!package-lock.json' ':!yarn.lock' ':!pnpm-lock.yaml' 2>/dev/null \
  | { grep -oE '[0-9]+ insertion|[0-9]+ deletion' || true; } \
  | awk '{s+=$1}END{print s+0}')
TOTAL_DIFF="${TOTAL_DIFF:-0}"
log_info "Total PR diff (source only, excl. compiled artifacts): ${TOTAL_DIFF} lines (limit: 350)"
if (( TOTAL_DIFF > 350 )); then
  add_issue "PR_TOO_LARGE: PR has ${TOTAL_DIFF} lines of source code changed (limit: 350). Compiled artifacts excluded. Split into smaller PRs."
  CHECKS_PASSED=false
fi

# Check 7: Detect files needing human credential/infra setup
log_info "Check: Human action needed..."
NEEDS_HUMAN_ACTION=false
HUMAN_TASKS=""

ENV_EXAMPLES=$(git diff "${BASE_BRANCH}...origin/${PR_BRANCH}" --diff-filter=ACM --name-only 2>/dev/null \
  | grep -E '\.env\.(example|production)' || true)
if [[ -n "$ENV_EXAMPLES" ]]; then
  NEEDS_HUMAN_ACTION=true
  HUMAN_TASKS="${HUMAN_TASKS}- Configure production env vars from: ${ENV_EXAMPLES}\n"
fi

DEPLOY_FILES=$(git diff "${BASE_BRANCH}...origin/${PR_BRANCH}" --diff-filter=ACM --name-only 2>/dev/null \
  | grep -iE '(deploy|docker|nginx|Dockerfile)' || true)
if [[ -n "$DEPLOY_FILES" ]]; then
  NEEDS_HUMAN_ACTION=true
  HUMAN_TASKS="${HUMAN_TASKS}- Review and configure deployment: ${DEPLOY_FILES}\n"
fi

if [[ "$NEEDS_HUMAN_ACTION" == "true" ]]; then
  # Escalate to Salma — she'll decide to split, rewrite, or flag for human
  log_info "Infra/credential changes detected — escalating to Salma"

  write_feedback "$TICKET_KEY" "karim" "NEEDS_INFRA" \
    "PR contains files that need manual infra/credential setup:\n${HUMAN_TASKS}\nSalma should decide how to handle this."

  jira_add_rich_comment "$TICKET_KEY" "karim" "ESCALATED" "## Infrastructure Changes Detected
PR contains infra/credential changes. Escalating to Salma.

$(echo -e "$HUMAN_TASKS")"
  jira_update_labels "$TICKET_KEY" "agent:karim" "agent:salma"
  jira_add_label "$TICKET_KEY" "needs-split"

  slack_notify "Escalated *<${JIRA_URL}|${TICKET_KEY}>* to Salma — PR has infra changes:
$(echo -e "$HUMAN_TASKS")" "pipeline" "warning"

  log_activity "karim" "$TICKET_KEY" "ESCALATED" "Infra changes detected, escalated to Salma"
  exit 0
fi

log_info "Automated checks complete: CHECKS_PASSED=${CHECKS_PASSED}"

# ─── 6. Determine verdict (no Claude — pure automated) ──────────────────────
FILES_CHANGED=$(git diff "${BASE_BRANCH}...origin/${PR_BRANCH}" --name-only 2>/dev/null)

if [[ "$CHECKS_PASSED" == "true" ]]; then
  # ─── APPROVED: Run tests, then merge PR to master ─────────────────────────────────
  log_info "All checks PASSED — merging PR to ${BASE_BRANCH}"

  # Check merge status before attempting
  MERGE_STATUS=$(gh pr view "$PR_NUMBER" --json mergeable --jq '.mergeable' 2>/dev/null || echo "UNKNOWN")
  log_info "PR #${PR_NUMBER} merge status: ${MERGE_STATUS}"

  # Run engine tests before merge
  log_info "Running engine tests..."
  cd "$PROJECT_DIR"
  git fetch origin "$PR_BRANCH" 2>/dev/null
  TEST_OUTPUT=$(npm test --workspace=@bisb/engine 2>&1) || {
    log_info "Engine tests failed — sending back to Youssef"
    write_feedback "$TICKET_KEY" "karim" "TESTS_FAILED" "Engine tests failed:\n${TEST_OUTPUT}"
    jira_add_rich_comment "$TICKET_KEY" "karim" "FAIL" "## Engine Tests Failed
Tests failed on merge candidate. Sending back to Youssef.

\`\`\`
$(echo "$TEST_OUTPUT" | tail -20)
\`\`\`"
    jira_update_labels "$TICKET_KEY" "agent:karim" "agent:youssef"
    increment_retry "$TICKET_KEY" "karim"
    slack_notify "Tests failed for *<${JIRA_URL}|${TICKET_KEY}>*, sent back to Youssef" "pipeline" "danger"
    log_activity "karim" "$TICKET_KEY" "TESTS_FAILED" "Engine tests failed"
    exit 0
  }
  log_info "Engine tests passed"

  MERGE_OUTPUT=""
  MERGE_SUCCESS=true

  if [[ "$MERGE_STATUS" == "CONFLICTING" ]]; then
    # PR has conflicts — send back to Youssef to rebase
    # NOTE: This is Youssef's problem, not a DevOps issue. Increment Youssef's
    # retry counter so HE escalates to Salma if rebase keeps failing.
    log_info "PR has merge conflicts — sending to Youssef to rebase"

    write_feedback "$TICKET_KEY" "karim" "NEEDS_REBASE" \
      "PR #${PR_NUMBER} has merge conflicts with ${BASE_BRANCH}. You must rebase:
1. git fetch origin ${BASE_BRANCH}
2. git rebase origin/${BASE_BRANCH}
3. Resolve any conflicts
4. git push --force-with-lease"

    jira_add_rich_comment "$TICKET_KEY" "karim" "WARNING" "## Merge Conflicts
PR: ${PR_URL}

Has merge conflicts with ${BASE_BRANCH}. Sending back to Youssef to rebase."
    jira_update_labels "$TICKET_KEY" "agent:karim" "agent:youssef"
    increment_retry "$TICKET_KEY" "youssef"

    slack_notify "PR #${PR_NUMBER} has conflicts for *<${JIRA_URL}|${TICKET_KEY}>*, sent to Youssef to rebase onto \`${BASE_BRANCH}\`" "pipeline" "warning"

    log_activity "karim" "$TICKET_KEY" "CONFLICT" "PR #${PR_NUMBER} has merge conflicts, sent to Youssef to rebase"
    exit 0

  elif [[ "$MERGE_STATUS" != "MERGEABLE" ]]; then
    # UNKNOWN or any unexpected status — skip, let next cron cycle retry
    log_info "PR not yet mergeable (status: ${MERGE_STATUS}). Will retry next cycle."
    jira_add_rich_comment "$TICKET_KEY" "karim" "PENDING" "## Waiting for Status Checks
PR #${PR_NUMBER} not yet mergeable (status: ${MERGE_STATUS}). Waiting for checks to complete."
    exit 0
  fi

  # Status is MERGEABLE — proceed with merge
  # Clean up worktree before merge (Youssef creates these, they block --delete-branch)
    WORKTREE_BASE="/opt/bisb-worktrees"
    for wt_dir in "${WORKTREE_BASE}"/feature/*; do
      [[ -d "$wt_dir" ]] || continue
      wt_branch=$(basename "$wt_dir")
      if [[ "$wt_branch" == *"${TICKET_KEY}"* ]] || echo "$PR_BRANCH" | grep -q "$(basename "$wt_dir")"; then
        log_info "Removing worktree for merged branch: $wt_dir"
        cd "$PROJECT_DIR" && git worktree remove "$wt_dir" --force 2>/dev/null || rm -rf "$wt_dir"
      fi
    done
    cd "$PROJECT_DIR" && git worktree prune 2>/dev/null || true

    MERGE_OUTPUT=$(gh pr merge "$PR_NUMBER" --merge 2>&1) || MERGE_SUCCESS=false

  if [[ "$MERGE_SUCCESS" == "true" ]]; then
    log_info "PR #${PR_NUMBER} merged successfully to ${BASE_BRANCH}"

    jira_add_rich_comment "$TICKET_KEY" "karim" "MERGED" "## PR Merged Successfully
PR: ${PR_URL}
Lines changed: ${DIFF_SIZE}

## Automated Checks
- Engine tests: PASS
- No secrets: PASS
- No .env files: PASS
- No console.log: PASS
- No dangerous operations: PASS
- Diff size: ${DIFF_SIZE} lines

## Pipeline Complete
- Salma: Spec written
- Youssef: Implemented
- Nadia: QA passed
- Karim: DevOps verified + merged

Awaiting Hedi's review in next sprint review."

    # Mark ticket as done
    jira_update_labels "$TICKET_KEY" "agent:karim" "ready-for-merge"
    jira_transition "$TICKET_KEY" "terminé"
    reset_retry "$TICKET_KEY" "karim"

    slack_notify "Merged *<${JIRA_URL}|${TICKET_KEY}>*: ${SUMMARY}
PR #${PR_NUMBER} merged to \`${BASE_BRANCH}\` (${DIFF_SIZE} lines)" "pipeline" "good"

    log_activity "karim" "$TICKET_KEY" "MERGED" "PR #${PR_NUMBER} merged to ${BASE_BRANCH}, all checks passed"
    log_success "=== Karim approved & merged ${TICKET_KEY} — pipeline complete ==="

  else
    # Merge failed (conflict, checks, etc.) — Youssef's problem, not DevOps
    log_error "PR merge failed: ${MERGE_OUTPUT}"

    write_feedback "$TICKET_KEY" "karim" "MERGE_FAILED" "PR merge failed: ${MERGE_OUTPUT}"

    jira_add_rich_comment "$TICKET_KEY" "karim" "FAIL" "## Merge Failed
PR: ${PR_URL}

Automated checks passed but merge failed. Sending back to Youssef.
- Error: ${MERGE_OUTPUT}"

    jira_update_labels "$TICKET_KEY" "agent:karim" "agent:youssef"
    increment_retry "$TICKET_KEY" "youssef"

    slack_notify "Merge failed for *<${JIRA_URL}|${TICKET_KEY}>*, sent back to Youssef" "pipeline" "danger"

    log_activity "karim" "$TICKET_KEY" "MERGE_FAILED" "PR merge failed: $(echo "$MERGE_OUTPUT" | head -1 | head -c 100)"
    log_info "=== Karim merge failed for ${TICKET_KEY} ==="
  fi

else
  # ─── BLOCKED: Send back to Youssef ─────────────────────────────────────
  log_info "DevOps BLOCKED — automated checks failed"

  # Write structured feedback for Youssef's next run
  write_feedback "$TICKET_KEY" "karim" "BLOCKED" "${ISSUES_TEXT:-Automated checks failed}"

  jira_add_rich_comment "$TICKET_KEY" "karim" "BLOCKED" "## DevOps Checks Failed
PR: ${PR_URL}

Automated checks failed. Sending back to Youssef.

## Issues
${ISSUES_TEXT:-No specific issues captured}"

  jira_update_labels "$TICKET_KEY" "agent:karim" "agent:youssef"
  increment_retry "$TICKET_KEY" "karim"

  slack_notify "Blocked *<${JIRA_URL}|${TICKET_KEY}>* — checks failed, sent back to Youssef.
${ISSUES_TEXT:-unknown}" "pipeline" "danger"

  log_activity "karim" "$TICKET_KEY" "BLOCKED" "${ISSUES_TEXT:-Automated checks failed}"
  log_info "=== Karim blocked ${TICKET_KEY} — sent to Youssef ==="
fi
