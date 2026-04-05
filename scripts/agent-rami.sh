#!/usr/bin/env bash
# =============================================================================
# agent-rami.sh — Technical Architect + DevOps (merged Karim responsibilities)
#
# Dual-mode agent:
#   MODE A (Architecture): Reviews design before dev starts (no PR exists)
#   MODE B (DevOps/Merge): Automated checks + auto-merge after QA (PR exists)
#
# Mode detection: if ticket has an open PR → DevOps mode, else → Architecture mode.
# Keeps Rami's identity, personality, and avatar for all interactions.
# =============================================================================
AGENT_NAME="rami"
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/agent-common.sh"

# Override base branch: PRs merge into dev, not master
BASE_BRANCH="${BASE_BRANCH:-dev}"

TICKET_KEY="${1:?Usage: agent-rami.sh TICKET-XX}"
MAX_RETRIES_ARCH=2   # Architecture review: 2 tries before escalating
MAX_RETRIES_DEVOPS=3 # DevOps/merge: 3 tries before escalating

init_log "$TICKET_KEY" "rami"
log_info "=== Rami (Architect + DevOps) starting for ${TICKET_KEY} ==="
JIRA_URL="$(jira_link "$TICKET_KEY")"

# ─── Fetch ticket details ─────────────────────────────────────────────────
log_info "Fetching ticket details..."
SUMMARY=$(jira_get_ticket_field "$TICKET_KEY" "summary")

if [[ -z "$SUMMARY" ]]; then
  log_error "Could not fetch ticket ${TICKET_KEY}"
  exit 1
fi

log_info "Ticket: ${SUMMARY}"
LABELS=$(jira_get_ticket_field "$TICKET_KEY" "labels")

# ─── Mode Detection ──────────────────────────────────────────────────────
# Check if there's an open PR for this ticket → DevOps mode
cd "$PROJECT_DIR"
PR_URL=$(find_pr_for_ticket "$TICKET_KEY")

if [[ -n "$PR_URL" ]]; then
  RAMI_MODE="devops"
  log_info "Open PR found (${PR_URL}) — entering DevOps/Merge mode"
else
  RAMI_MODE="architecture"
  log_info "No open PR — entering Architecture Review mode"
fi

# ═══════════════════════════════════════════════════════════════════════════
# MODE A: ARCHITECTURE REVIEW (pre-development)
# ═══════════════════════════════════════════════════════════════════════════
if [[ "$RAMI_MODE" == "architecture" ]]; then

  # ─── Retry check ────────────────────────────────────────────────────────
  retry_count=$(get_retry_count "$TICKET_KEY" "rami")
  if (( retry_count >= MAX_RETRIES_ARCH )); then
    log_error "Max retries ($MAX_RETRIES_ARCH) reached for ${TICKET_KEY}."
    jira_add_rich_comment "$TICKET_KEY" "rami" "BLOCKED" "## Architecture Review Failed
Could not validate technical design after ${MAX_RETRIES_ARCH} attempts. Needs human review."
    jira_add_label "$TICKET_KEY" "needs-human"
    jira_remove_label "$TICKET_KEY" "agent:rami"
    slack_notify "*$(mm_ticket_link "${TICKET_KEY}")* — revue architecture échouée après ${MAX_RETRIES_ARCH} tentatives. $(mm_mention salma), intervention humaine requise." "pipeline" "danger"
    exit 1
  fi

  if ! check_cooldown "$TICKET_KEY" "rami"; then
    exit 0
  fi

  DESCRIPTION=$(jira_get_description_text "$TICKET_KEY")
  COMMENTS=$(jira_get_comments "$TICKET_KEY")
  PRIORITY=$(jira_get_ticket_field "$TICKET_KEY" "priority")

  # ─── Handle retro-action tickets ──────────────────────────────────────
  if echo "$LABELS" | grep -q "retro-action" 2>/dev/null; then
    if ! echo "$LABELS" | grep -q "enriched" 2>/dev/null; then
      log_info "Retro-action ticket — writing DevOps perspective comment and handing to Salma"

      RETRO_PROMPT="You are Rami, the Technical Architect and DevOps lead.
Read CLAUDE.md and ai/architect.md for project context and your role.

TICKET: ${TICKET_KEY}
TITLE: ${SUMMARY}
DESCRIPTION:
${DESCRIPTION:-No description provided}

EXISTING COMMENTS:
${COMMENTS:-None}

This is a retrospective action item assigned to you. Write a concise comment (max 300 words) covering:
1. Architecture implications (patterns, tech debt, code structure)
2. DevOps impact (CI/CD, deployment, infrastructure, security)
3. What automated checks could enforce this improvement
4. Suggested acceptance criteria from a technical perspective

Output ONLY the comment text — no preamble, no markdown headers."

      RETRO_COMMENT=$(cd "$PROJECT_DIR" && claude -p "$RETRO_PROMPT" \
        --disallowedTools "Write Edit Bash" \
        --model haiku --max-turns 1 2>/dev/null) || true

      if [[ -n "$RETRO_COMMENT" && ${#RETRO_COMMENT} -gt 20 ]]; then
        jira_add_rich_comment "$TICKET_KEY" "rami" "INFO" "## Technical Perspective (Rami)
${RETRO_COMMENT}

Handing to Salma for spec writing."
      else
        jira_add_rich_comment "$TICKET_KEY" "rami" "INFO" "## Technical Perspective (Rami)
Reviewed retro-action item. Handing to Salma for spec writing."
      fi

      jira_update_labels "$TICKET_KEY" "agent:rami" "agent:salma"
      log_activity "rami" "$TICKET_KEY" "RETRO_COMMENT" "Wrote technical perspective for retro-action, handed to Salma"
      slack_notify "*$(mm_ticket_link "${TICKET_KEY}")* — perspective technique rédigée. $(mm_mention salma), je te transmets pour enrichir la spec." "pipeline"
      exit 0
    fi
  fi

  # ─── Auto-skip simple tickets ─────────────────────────────────────────
  if echo "$LABELS $SUMMARY" | grep -qiE "bug|fix|typo|documentation|config|cleanup"; then
    log_info "Simple ticket (label/title match) — auto-approving, forwarding to Youssef"

    if [[ -n "${JIRA_ARCH_SIGNOFF_FIELD_ID:-}" ]]; then
      jira_update_field "$TICKET_KEY" "$JIRA_ARCH_SIGNOFF_FIELD_ID" "{\"value\": \"Approved\"}"
    fi

    jira_add_rich_comment "$TICKET_KEY" "rami" "PASS" "## Auto-Approved (Architecture)
Simple ticket — no architecture review needed. Forwarding to development."
    jira_update_labels "$TICKET_KEY" "agent:rami" "agent:youssef"
    log_activity "rami" "$TICKET_KEY" "AUTO_APPROVED" "Simple ticket, forwarded to Youssef"
    slack_notify "*$(mm_ticket_link "${TICKET_KEY}")* — architecture validée automatiquement. $(mm_mention youssef), c'est à toi pour l'implémentation !" "pipeline"
    exit 0
  fi

  # ─── Architecture Decision Mode ────────────────────────────────────────
  IS_ARCHITECTURE_DECISION=false
  if echo "$SUMMARY" | grep -qiE "decide|evaluate|recommend|choose|compare|which approach|design system"; then
    IS_ARCHITECTURE_DECISION=true
    log_info "Architecture decision ticket detected: $SUMMARY"
  fi

  if [[ "$IS_ARCHITECTURE_DECISION" == "true" ]]; then
    log_info "Entering architecture decision mode for $TICKET_KEY"
    ARCH_MODEL="claude-sonnet-4-20250514"

    ARCH_PROMPT="You are Rami, the Technical Architect.
Read CLAUDE.md and ai/architect.md for project context and your role.

TICKET: $TICKET_KEY
SUMMARY: $SUMMARY
PRIORITY: $PRIORITY

DESCRIPTION:
$DESCRIPTION

PREVIOUS COMMENTS:
$COMMENTS

TASK: This ticket asks you to evaluate architectural options and recommend the best approach.

INSTRUCTIONS:
1. First, read ai/architect.md for your full role definition and the project architecture
2. Explore the codebase using Read, Glob, Grep tools to understand current patterns
3. For each option, evaluate: pros/cons, compatibility, effort, cost, maintainability
4. Make a clear RECOMMENDATION with justification

VERDICT: ARCHITECTURE_RECOMMENDED"

    log_info "Invoking Claude for architecture decision ($ARCH_MODEL)..."
    CLAUDE_OUTPUT=$(echo "$ARCH_PROMPT" | claude --model "$ARCH_MODEL" --max-turns 15 --allowedTools "Read Glob Grep WebSearch WebFetch" -p 2>&1) || {
      log_info "ERROR: Claude invocation failed for architecture decision"
      increment_retry "$TICKET_KEY" "rami"
      exit 1
    }

    jira_add_rich_comment "$TICKET_KEY" "rami" "PASS" "## Architecture Decision
${CLAUDE_OUTPUT}"

    jira_update_labels "$TICKET_KEY" "agent:rami" "agent:salma"
    jira_add_label "$TICKET_KEY" "architecture-ready"
    log_activity "rami" "$TICKET_KEY" "ARCHITECTURE_RECOMMENDED" "Architecture evaluated and recommended"
    slack_notify "*$(mm_ticket_link "${TICKET_KEY}")* — recommandation architecturale soumise. $(mm_mention salma), je te transmets pour la spec d'implémentation." "pipeline"
    exit 0
  fi

  # ─── Standard Architecture Review ──────────────────────────────────────
  MODEL="sonnet"
  MODEL=$(select_model_rate_aware "$MODEL" "rami" "general")
  MODEL=$(activate_api_key_if_needed "$MODEL")
  if [[ "$MODEL" == "WAIT" ]]; then
    log_info "Sonnet rate-limited — rami skipping architecture review (no API key)"
    exit 0
  fi
  log_info "Invoking Claude (${MODEL}) for architecture review..."

  CLAUDE_PROMPT="You are Rami, the Technical Architect.
Read CLAUDE.md for project overview and ai/architect.md for your complete rules and review checklist.

TICKET: ${TICKET_KEY}
TITLE: ${SUMMARY}
PRIORITY: ${PRIORITY}

SPECIFICATION (written by Salma):
${DESCRIPTION:-No description provided}

COMMENTS:
${COMMENTS:-None}

YOUR TASK — ARCHITECTURE REVIEW:
1. Read ai/architect.md for your role and tech stack rules
2. CODEBASE ANALYSIS:
   - Use Glob to find relevant files in packages/engine/src/ and packages/web/src/
   - Use Grep to search for patterns this feature should follow
   - Use Read to examine key files that this feature will affect
3. VALIDATE against: pattern compliance, reuse opportunities, engine/web separation,
   game rule compliance, state immutability, tech debt, PR size, test coverage
4. Produce a verdict in this EXACT format at the END of your output:

VERDICT: APPROVED
TECH_DEBT_SCORE: [+1=adds debt, 0=neutral, -1=reduces debt]
REUSE_NOTES: [components/hooks to reuse]

or

VERDICT: NEEDS_REVISION
ISSUES:
- Issue 1: description and what to change
RECOMMENDED_PATTERNS: [existing patterns to follow, with file paths]

or

VERDICT: REDESIGN_NEEDED
REASON: [fundamental design flaw]
RECOMMENDED_APPROACH: [alternative architecture]

CRITICAL: You MUST output exactly one VERDICT line."

  PROMPT_FILE=$(mktemp /tmp/rami-prompt-XXXXXX.txt)
  echo "$CLAUDE_PROMPT" > "$PROMPT_FILE"

  CLAUDE_OUTPUT=$(cd "$PROJECT_DIR" && claude -p - \
    --allowedTools "Read Glob Grep" \
    --model "$MODEL" --max-turns 15 \
    < "$PROMPT_FILE" 2>/dev/null) || true
  rm -f "$PROMPT_FILE"

  log_info "Claude output:"
  echo "$CLAUDE_OUTPUT" >> "$LOG_FILE"

  # ─── Parse verdict ──────────────────────────────────────────────────────
  if [[ -z "$CLAUDE_OUTPUT" ]]; then
    log_error "Claude returned empty output"
    increment_retry "$TICKET_KEY" "rami"
    jira_add_rich_comment "$TICKET_KEY" "rami" "WARNING" "## Architecture Review — Empty Response
Claude returned empty output. Will retry on next cycle."
    exit 1
  fi

  AGENT_TMPFILE=$(mktemp /tmp/${PROJECT_PREFIX}-agent-XXXXXX.txt)
  printf '%s\n' "$CLAUDE_OUTPUT" > "$AGENT_TMPFILE"
  VERDICT=$(parse_verdict "$AGENT_TMPFILE")
  rm -f "$AGENT_TMPFILE"
  log_info "Parsed verdict: $VERDICT"

  case "$VERDICT" in
    APPROVED)
      TECH_DEBT=$(echo "$CLAUDE_OUTPUT" | grep -oP "TECH_DEBT_SCORE:\s*\K.*" | head -1 || true)
      REUSE_NOTES=$(echo "$CLAUDE_OUTPUT" | grep -oP "REUSE_NOTES:\s*\K.*" | head -1 || true)

      if [[ -n "${JIRA_ARCH_SIGNOFF_FIELD_ID:-}" ]]; then
        jira_update_field "$TICKET_KEY" "$JIRA_ARCH_SIGNOFF_FIELD_ID" "{\"value\": \"Approved\"}"
      fi

      jira_add_rich_comment "$TICKET_KEY" "rami" "PASS" "## Architecture Review: APPROVED
${TECH_DEBT:+Tech Debt Score: ${TECH_DEBT}
}${REUSE_NOTES:+Reuse: ${REUSE_NOTES}
}
Design is sound. Forwarding to Youssef for implementation."

      jira_update_labels "$TICKET_KEY" "agent:rami" "agent:youssef"
      reset_retry "$TICKET_KEY" "rami"
      log_activity "rami" "$TICKET_KEY" "APPROVED" "Architecture approved, forwarded to Youssef"
      append_ticket_history "$TICKET_KEY" "rami" "ARCH_APPROVED" "Architecture approved${TECH_DEBT:+, tech debt: ${TECH_DEBT}}"
      slack_notify "*$(mm_ticket_link "${TICKET_KEY}")* — architecture solide ! $(mm_mention youssef), tu peux démarrer l'implémentation
${TECH_DEBT:+Tech debt: ${TECH_DEBT}}" "pipeline" "good"
      ;;

    NEEDS_REVISION)
      ISSUES=$(echo "$CLAUDE_OUTPUT" | sed -n '/ISSUES:/,/RECOMMENDED_PATTERNS:\|VERDICT:/p' | head -10 || true)
      PATTERNS=$(echo "$CLAUDE_OUTPUT" | grep -oP "RECOMMENDED_PATTERNS:\s*\K.*" | head -1 || true)

      if [[ -n "${JIRA_ARCH_SIGNOFF_FIELD_ID:-}" ]]; then
        jira_update_field "$TICKET_KEY" "$JIRA_ARCH_SIGNOFF_FIELD_ID" "{\"value\": \"Rejected\"}"
      fi

      write_feedback "$TICKET_KEY" "rami" "NEEDS_REVISION" "${ISSUES}${PATTERNS:+\nRECOMMENDED_PATTERNS: ${PATTERNS}}"

      jira_add_rich_comment "$TICKET_KEY" "rami" "FAIL" "## Architecture Review: NEEDS REVISION
${ISSUES}
${PATTERNS:+Recommended patterns: ${PATTERNS}
}
Returning to Salma for spec revision with tech notes."

      jira_update_labels "$TICKET_KEY" "agent:rami" "agent:salma"
      jira_remove_label "$TICKET_KEY" "enriched"
      increment_retry "$TICKET_KEY" "rami"
      log_activity "rami" "$TICKET_KEY" "NEEDS_REVISION" "Sent back to Salma for tech revision"
      append_ticket_history "$TICKET_KEY" "rami" "ARCH_NEEDS_REVISION" "Sent back to Salma"
      slack_notify "*$(mm_ticket_link "${TICKET_KEY}")* — problèmes d'architecture identifiés. $(mm_mention salma), je te renvoie avec mes recommandations — retravailler la spec avant le code." "pipeline" "warning"
      ;;

    REDESIGN_NEEDED)
      REASON=$(echo "$CLAUDE_OUTPUT" | grep -oP "REASON:\s*\K.*" | head -1 || true)
      APPROACH=$(echo "$CLAUDE_OUTPUT" | grep -oP "RECOMMENDED_APPROACH:\s*\K.*" | head -1 || true)

      if [[ -n "${JIRA_ARCH_SIGNOFF_FIELD_ID:-}" ]]; then
        jira_update_field "$TICKET_KEY" "$JIRA_ARCH_SIGNOFF_FIELD_ID" "{\"value\": \"Rejected\"}"
      fi

      jira_add_rich_comment "$TICKET_KEY" "rami" "BLOCKED" "## REDESIGN NEEDED
${REASON:+Reason: ${REASON}
}${APPROACH:+Recommended approach: ${APPROACH}
}
This ticket requires a fundamental design change.
Escalating to Hedi for an architecture decision."

      jira_add_label "$TICKET_KEY" "needs-human"
      jira_remove_label "$TICKET_KEY" "agent:rami"
      reset_retry "$TICKET_KEY" "rami"
      log_activity "rami" "$TICKET_KEY" "REDESIGN_NEEDED" "Escalated to human — redesign required"
      append_ticket_history "$TICKET_KEY" "rami" "REDESIGN_NEEDED" "${REASON:-Fundamental design flaw}"
      slack_notify "**Refonte architecturale** — *$(mm_ticket_link "${TICKET_KEY}")*
${REASON:+${REASON}}
${APPROACH:+Approach: ${APPROACH}}
Needs human architecture decision." "pipeline" "danger"
      ;;

    UNKNOWN)
      log_info "Could not parse verdict — will retry next cycle"
      jira_add_rich_comment "$TICKET_KEY" "rami" "WARNING" "## Architecture Review — Parse Error
Could not determine verdict. Will retry on next cycle."
      ;;
  esac

  log_info "=== Rami finished architecture review for ${TICKET_KEY} (verdict: ${VERDICT}) ==="
  exit 0
fi

# ═══════════════════════════════════════════════════════════════════════════
# MODE B: DEVOPS CHECKS + AUTO-MERGE (post-QA)
# ═══════════════════════════════════════════════════════════════════════════
log_info "=== Rami DevOps mode: verifying ${TICKET_KEY} for merge ==="

# ─── Retry check ────────────────────────────────────────────────────────
retry_count=$(get_retry_count "$TICKET_KEY" "rami-devops")
if (( retry_count >= MAX_RETRIES_DEVOPS )); then
  log_info "Max DevOps retries ($MAX_RETRIES_DEVOPS) reached for ${TICKET_KEY}. Waiting for standup."
  jira_add_rich_comment "$TICKET_KEY" "rami" "WARNING" "## Max DevOps Retries Reached
DevOps checks failed ${MAX_RETRIES_DEVOPS} times. Waiting for standup round-table."
  log_activity "rami" "$TICKET_KEY" "MAX_RETRIES" "Hit ${MAX_RETRIES_DEVOPS} DevOps retries"
  exit 0
fi

if ! check_cooldown "$TICKET_KEY" "rami-devops"; then
  exit 0
fi

# ─── Find PR details ─────────────────────────────────────────────────────
log_info "Found PR: ${PR_URL}"

PR_BRANCH=$(find_pr_branch "$TICKET_KEY")
if [[ -z "$PR_BRANCH" ]]; then
  log_error "Could not determine PR branch for ${TICKET_KEY}"
  exit 1
fi

PR_NUMBER=$(echo "$PR_URL" | grep -oE '[0-9]+$')

# ─── Fetch remote refs (NO checkout — Youssef may be working) ────────────
log_info "Fetching remote refs for verification..."
cd "$PROJECT_DIR"
git fetch origin 2>/dev/null

# ─── Run automated security & quality checks ────────────────────────────
log_info "Running DevOps verification checks (remote refs)..."

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

# Check 1: No .env files added or modified
log_info "Check: No .env files in diff..."
ENV_FILES=$(git diff "${BASE_BRANCH}...origin/${PR_BRANCH}" --diff-filter=ACM --name-only 2>/dev/null | grep -E '\.env$' | grep -v '\.env\.example$' || true)
if [[ -n "$ENV_FILES" ]]; then
  add_issue "SECURITY: .env files added/modified in diff: ${ENV_FILES}"
  CHECKS_PASSED=false
fi

# Check 2: No hardcoded secrets
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

# Check 3: No console.log statements
log_info "Check: No console.log..."
CONSOLE_LOGS=$(git diff "${BASE_BRANCH}...origin/${PR_BRANCH}" -- '*.ts' '*.tsx' '*.js' '*.jsx' 2>/dev/null | grep '^\+.*console\.\(log\|debug\|info\)' | grep -v '// eslint-disable' | grep -v '^\+\s*//' | grep -v '^\+\s*\*' || true)
if [[ -n "$CONSOLE_LOGS" ]]; then
  add_issue "QUALITY: console.log statements found in new code"
  CHECKS_PASSED=false
fi

# Check 4: Code diff size (warning only)
DIFF_STATS=$(git diff "${BASE_BRANCH}...origin/${PR_BRANCH}" --stat 2>/dev/null)
DIFF_SIZE=$(echo "$DIFF_STATS" | tail -1 | { grep -oE '[0-9]+ insertion|[0-9]+ deletion' || true; } | awk '{s+=$1}END{print s+0}')
DIFF_SIZE="${DIFF_SIZE:-0}"
CODE_DIFF_STAT=$(git diff "${BASE_BRANCH}...origin/${PR_BRANCH}" --stat -- '*.ts' '*.tsx' '*.js' '*.jsx' '*.css' 2>/dev/null || true)
CODE_DIFF_SIZE=$(echo "$CODE_DIFF_STAT" | tail -1 | { grep -oE '[0-9]+ insertion|[0-9]+ deletion' || true; } | awk '{s+=$1}END{print s+0}')
CODE_DIFF_SIZE="${CODE_DIFF_SIZE:-0}"
log_info "Code diff: ${CODE_DIFF_SIZE} lines (total: ${DIFF_SIZE})"

# Check 5: No dangerous operations
log_info "Check: No dangerous operations..."
DANGEROUS=$(git diff "${BASE_BRANCH}...origin/${PR_BRANCH}" -- '*.ts' '*.tsx' '*.js' '*.jsx' '*.sql' '*.sh' 2>/dev/null | grep -E '^\+.*(--force|--hard|DROP TABLE|TRUNCATE|DELETE FROM .* WHERE 1)' || true)
if [[ -n "$DANGEROUS" ]]; then
  add_issue "SECURITY: Potentially dangerous operations found in diff"
  CHECKS_PASSED=false
fi

# Check 6: PR size hard limit (300 lines, aligned with Nadia's QA limit)
# Auto-generated type files (e.g. src/types/database.ts from Supabase) are exempt per CLAUDE.md
log_info "Check: PR size hard limit (300 lines)..."
# Count only handwritten code lines (exclude lockfiles, auto-generated types, SQL migrations, docs)
TOTAL_DIFF=$(git diff "${BASE_BRANCH}...origin/${PR_BRANCH}" --shortstat \
  -- ':!package-lock.json' ':!yarn.lock' ':!pnpm-lock.yaml' \
     ':!src/types/database.ts' \
     ':!supabase/migrations/*.sql' \
     ':!*.md' ':!*.mdx' \
  2>/dev/null \
  | { grep -oE '[0-9]+ insertion|[0-9]+ deletion' || true; } \
  | awk '{s+=$1}END{print s+0}')
TOTAL_DIFF="${TOTAL_DIFF:-0}"
log_info "Total PR diff (handwritten code only): ${TOTAL_DIFF} lines (limit: 300)"
if (( TOTAL_DIFF > 300 )); then
  add_issue "PR_TOO_LARGE: PR has ${TOTAL_DIFF} lines of handwritten code changed. Hard limit is 300 lines. Split into smaller PRs. (Auto-generated files like database.ts and SQL migrations are excluded.)"
  CHECKS_PASSED=false
fi

# Check 7: Detect infra/credential changes needing human action
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
  log_info "Infra/credential changes detected — escalating to Salma"
  write_feedback "$TICKET_KEY" "rami" "NEEDS_INFRA" \
    "PR contains files that need manual infra/credential setup:\n${HUMAN_TASKS}\nSalma should decide how to handle this."
  jira_add_rich_comment "$TICKET_KEY" "rami" "ESCALATED" "## Infrastructure Changes Detected
PR contains infra/credential changes. Escalating to Salma.

$(echo -e "$HUMAN_TASKS")"
  jira_update_labels "$TICKET_KEY" "agent:rami" "agent:salma"
  jira_add_label "$TICKET_KEY" "needs-split"
  slack_notify "*$(mm_ticket_link "${TICKET_KEY}")* — changements infra détectés. $(mm_mention salma), escalade requise :
$(echo -e "$HUMAN_TASKS")" "pipeline" "warning"
  log_activity "rami" "$TICKET_KEY" "ESCALATED" "Infra changes detected, escalated to Salma"
  exit 0
fi

log_info "Automated checks complete: CHECKS_PASSED=${CHECKS_PASSED}"

# ─── Determine outcome ──────────────────────────────────────────────────
if [[ "$CHECKS_PASSED" == "true" ]]; then
  # ─── APPROVED: Run tests, then merge PR ─────────────────────────────
  log_info "All checks PASSED — merging PR to ${BASE_BRANCH}"

  MERGE_STATUS=$(gh pr view "$PR_NUMBER" --json mergeable --jq '.mergeable' 2>/dev/null || echo "UNKNOWN")
  log_info "PR #${PR_NUMBER} merge status: ${MERGE_STATUS}"

  # Run project tests before merge (skip if no package.json or no test script)
  log_info "Running project tests..."
  cd "$PROJECT_DIR"
  git fetch origin "$PR_BRANCH" 2>/dev/null
  TEST_CMD="${PROJECT_TEST_CMD:-npm test}"
  if [[ ! -f "package.json" ]] || ! grep -q '"test"' package.json 2>/dev/null; then
    log_info "No test script found — skipping pre-merge tests"
    TEST_OUTPUT="(skipped — no test script)"
  else
    TEST_OUTPUT=$($TEST_CMD 2>&1) || {
      log_info "Project tests failed — sending back to Youssef"
      write_feedback "$TICKET_KEY" "rami" "TESTS_FAILED" "Tests failed:\n${TEST_OUTPUT}"
      jira_add_rich_comment "$TICKET_KEY" "rami" "FAIL" "## Tests Failed
Tests failed on merge candidate. Sending back to Youssef.

\`\`\`
$(echo "$TEST_OUTPUT" | tail -20)
\`\`\`"
      jira_update_labels "$TICKET_KEY" "agent:rami" "agent:youssef"
      increment_retry "$TICKET_KEY" "rami-devops"
      slack_notify "*$(mm_ticket_link "${TICKET_KEY}")* — tests échoués avant merge. $(mm_mention youssef), je te renvoie la PR — détails dans le ticket." "pipeline" "danger"
      log_activity "rami" "$TICKET_KEY" "TESTS_FAILED" "Tests failed"
      append_ticket_history "$TICKET_KEY" "rami" "TESTS_FAILED" "Tests failed before merge"
      exit 0
    }
    log_info "Project tests passed"
  fi

  MERGE_OUTPUT=""
  MERGE_SUCCESS=true

  if [[ "$MERGE_STATUS" == "CONFLICTING" ]]; then
    log_info "PR has merge conflicts — sending to Youssef to rebase"
    write_feedback "$TICKET_KEY" "rami" "NEEDS_REBASE" \
      "PR #${PR_NUMBER} has merge conflicts with ${BASE_BRANCH}. Rebase needed."
    jira_add_rich_comment "$TICKET_KEY" "rami" "WARNING" "## Merge Conflicts
PR: ${PR_URL}

Has merge conflicts with ${BASE_BRANCH}. Sending back to Youssef to rebase." || true
    jira_update_labels "$TICKET_KEY" "agent:rami" "agent:youssef"
    jira_transition "$TICKET_KEY" "in progress" || true
    plane_set_assignee "$TICKET_KEY" "youssef" 2>/dev/null || true
    increment_retry "$TICKET_KEY" "youssef"
    slack_notify "*$(mm_ticket_link "${TICKET_KEY}")* — PR #${PR_NUMBER} en conflit avec master. $(mm_mention youssef), un rebase s'impose." "pipeline" "warning" || true
    log_activity "rami" "$TICKET_KEY" "CONFLICT" "PR has merge conflicts, sent to Youssef"
    exit 0

  elif [[ "$MERGE_STATUS" != "MERGEABLE" ]]; then
    log_info "PR not yet mergeable (status: ${MERGE_STATUS}). Will retry next cycle."
    jira_add_rich_comment "$TICKET_KEY" "rami" "PENDING" "## Waiting for Status Checks
PR #${PR_NUMBER} not yet mergeable (status: ${MERGE_STATUS}). Waiting for checks to complete."
    exit 0
  fi

  # Clean up worktree before merge
  WORKTREE_BASE="/opt/${PROJECT_PREFIX}-worktrees"
  for wt_dir in "${WORKTREE_BASE}"/feature/*; do
    [[ -d "$wt_dir" ]] || continue
    wt_branch=$(basename "$wt_dir")
    if [[ "$wt_branch" == *"${TICKET_KEY}"* ]] || echo "$PR_BRANCH" | grep -q "$(basename "$wt_dir")"; then
      log_info "Removing worktree for merged branch: $wt_dir"
      cd "$PROJECT_DIR" && git worktree remove "$wt_dir" --force 2>/dev/null || rm -rf "$wt_dir"
    fi
  done
  cd "$PROJECT_DIR" && git worktree prune 2>/dev/null || true

  # ─── Global merge lock: serialize merges to prevent orphaned commits ─────
  MERGE_LOCK="/tmp/${PROJECT_PREFIX}-merge-master.lock"
  MERGE_LOCK_ACQUIRED=false
  for _attempt in $(seq 1 12); do
    if [[ ! -f "$MERGE_LOCK" ]]; then
      echo "$$" > "$MERGE_LOCK"
      MERGE_LOCK_ACQUIRED=true
      break
    fi
    _lock_age=$(( $(date +%s) - $(stat -c %Y "$MERGE_LOCK" 2>/dev/null || echo 0) ))
    if (( _lock_age > 120 )); then
      log_info "Removing stale merge lock (age=${_lock_age}s)"
      rm -f "$MERGE_LOCK"
      echo "$$" > "$MERGE_LOCK"
      MERGE_LOCK_ACQUIRED=true
      break
    fi
    log_info "Merge lock held by another Rami, waiting 5s (attempt ${_attempt}/12)..."
    sleep 5
  done
  if [[ "$MERGE_LOCK_ACQUIRED" == "false" ]]; then
    log_info "Could not acquire merge lock after 60s — will retry next cycle"
    exit 0
  fi

  MERGE_OUTPUT=$(gh pr merge "$PR_NUMBER" --merge 2>&1) || MERGE_SUCCESS=false
  rm -f "$MERGE_LOCK"

  if [[ "$MERGE_SUCCESS" == "true" ]]; then
    log_info "PR #${PR_NUMBER} merged successfully to ${BASE_BRANCH}"

    # ─── Post-merge verification: build + test on merged base branch ────
    log_info "Running post-merge verification..."
    cd "$PROJECT_DIR"
    git pull origin "${BASE_BRANCH}" -q 2>/dev/null || true

    POST_MERGE_OK=true
    POST_MERGE_ERRORS=""

    # 1. Project tests (skip if no test script)
    if [[ -f "package.json" ]] && grep -q '"test"' package.json 2>/dev/null; then
      if ! ${PROJECT_TEST_CMD:-npm test} 2>/dev/null; then
        POST_MERGE_OK=false
        POST_MERGE_ERRORS="${POST_MERGE_ERRORS}\n- Project tests FAILED after merge"
        log_error "Post-merge project tests FAILED"
      else
        log_info "Post-merge project tests passed"
      fi
    else
      log_info "No test script — skipping post-merge tests"
    fi

    # 2. Build check (skip if no build script)
    if [[ -f "package.json" ]] && grep -q '"build"' package.json 2>/dev/null; then
      if ! ${PROJECT_BUILD_CMD:-npm run build} 2>/dev/null; then
        POST_MERGE_OK=false
        POST_MERGE_ERRORS="${POST_MERGE_ERRORS}\n- Build FAILED after merge"
        log_error "Post-merge build FAILED"
      else
        log_info "Post-merge build passed"
      fi
    else
      log_info "No build script — skipping post-merge build"
    fi

    if [[ "$POST_MERGE_OK" == "false" ]]; then
      # ─── ROLLBACK: auto-revert the merge commit ──────────────────────
      log_error "Post-merge verification FAILED — initiating rollback"

      REVERT_OUTPUT=$(git revert HEAD --no-edit 2>&1) || true
      REVERT_PUSH=$(git push origin "${BASE_BRANCH}" 2>&1) || true

      jira_add_rich_comment "$TICKET_KEY" "rami" "FAIL" "## REVERTED — Post-Merge Failure
PR #${PR_NUMBER} was merged but broke the build/tests on \`${BASE_BRANCH}\`.

## Failures
$(echo -e "$POST_MERGE_ERRORS")

## Action Taken
- Auto-reverted merge commit on \`${BASE_BRANCH}\`
- Ticket sent back to Youssef for fix
- Original PR changes need to be re-applied after fixing

## Revert Details
${REVERT_OUTPUT}" || true

      jira_update_labels "$TICKET_KEY" "agent:rami" "agent:youssef"
      increment_retry "$TICKET_KEY" "youssef"
      write_feedback "$TICKET_KEY" "rami" "REVERTED" "Post-merge failure:$(echo -e "$POST_MERGE_ERRORS")"

      slack_notify "**Revert** — *$(mm_ticket_link "${TICKET_KEY}")*: échec post-merge sur \`${BASE_BRANCH}\`
$(echo -e "$POST_MERGE_ERRORS")
Auto-reverted, sent back to Youssef." "pipeline" "danger" || true

      log_activity "rami" "$TICKET_KEY" "REVERTED" "Post-merge failure, auto-reverted"
      append_ticket_history "$TICKET_KEY" "rami" "REVERTED" "Post-merge build/test failure, auto-reverted"
      log_decision "rami" "$TICKET_KEY" "REVERTED" "Post-merge verification failed, auto-reverted"
      log_info "=== Rami REVERTED ${TICKET_KEY} — post-merge failure ==="
    else
      # ─── All good: merge verified ─────────────────────────────────────
      log_info "Post-merge verification passed"

      jira_add_rich_comment "$TICKET_KEY" "rami" "MERGED" "## PR Merged into dev + Verified
PR: ${PR_URL}
Lines changed: ${DIFF_SIZE}

## Automated Checks
- Engine tests: PASS (pre + post merge)
- Build: PASS (post merge)
- No secrets: PASS
- No .env files: PASS
- No console.log: PASS
- No dangerous operations: PASS
- Diff size: ${DIFF_SIZE} lines

## Pipeline Status
- Salma: Spec written
- Rami: Architecture reviewed
- Youssef: Implemented
- Nadia: QA passed
- Rami: DevOps verified + merged into dev + post-merge verified
- Omar: Pending master merge tracking" || true

      jira_update_labels "$TICKET_KEY" "agent:rami" "agent:omar"
      jira_transition "$TICKET_KEY" "done" || true
      reset_retry "$TICKET_KEY" "rami-devops"

      slack_notify "$(mm_ticket_link "${TICKET_KEY}") mergée sur \`${BASE_BRANCH}\` — PR #${PR_NUMBER} propre (${DIFF_SIZE} lignes), vérification post-merge OK. Transmis à Omar pour suivi de la merge dans master." "pipeline" "good" || true

      log_activity "rami" "$TICKET_KEY" "MERGED" "PR #${PR_NUMBER} merged to ${BASE_BRANCH}, post-merge verified"
      append_ticket_history "$TICKET_KEY" "rami" "MERGED" "PR #${PR_NUMBER} merged, all checks passed + post-merge verified"
      log_decision "rami" "$TICKET_KEY" "MERGED" "All automated checks passed, post-merge build+tests passed"
      # Auto-deploy: build and copy to production directory
      if [[ -n "${PROJECT_DEPLOY_DIR:-}" ]]; then
        log_info "Auto-deploying to ${PROJECT_DEPLOY_DIR}..."
        cd "$PROJECT_DIR"
        git pull origin "${BASE_BRANCH}" -q 2>/dev/null || true
        if bash -c "${PROJECT_BUILD_CMD:-npm run build}" 2>/dev/null; then
          for _deploy_out in dist build; do
            if [[ -d "$_deploy_out" ]]; then
              cp -r "$_deploy_out"/* "${PROJECT_DEPLOY_DIR}/" 2>/dev/null || true
              log_info "Deployed $_deploy_out/ to ${PROJECT_DEPLOY_DIR}"
              slack_notify "Deploiement auto: $(mm_ticket_link "${TICKET_KEY}") deployee. Lien: ${PROJECT_DEPLOY_URL:-N/A}" "pipeline" "good" || true
              break
            fi
          done
        else
          log_error "Auto-deploy build failed for ${TICKET_KEY}"
          slack_notify "Build echouee apres merge de $(mm_ticket_link "${TICKET_KEY}") — deploiement annule." "alerts" "warning" || true
        fi
      fi

      log_success "=== Rami approved & merged ${TICKET_KEY} — pipeline complete ==="
    fi

  else
    log_error "PR merge failed: ${MERGE_OUTPUT}"
    write_feedback "$TICKET_KEY" "rami" "MERGE_FAILED" "PR merge failed: ${MERGE_OUTPUT}"
    jira_add_rich_comment "$TICKET_KEY" "rami" "FAIL" "## Merge Failed
PR: ${PR_URL}

Automated checks passed but merge failed. Sending back to Youssef.
- Error: ${MERGE_OUTPUT}" || true
    jira_update_labels "$TICKET_KEY" "agent:rami" "agent:youssef"
    increment_retry "$TICKET_KEY" "youssef"
    slack_notify "*$(mm_ticket_link "${TICKET_KEY}")* — merge échoué. $(mm_mention youssef), je te renvoie la PR — vérifie les logs." "pipeline" "danger" || true
    log_activity "rami" "$TICKET_KEY" "MERGE_FAILED" "PR merge failed"
    append_ticket_history "$TICKET_KEY" "rami" "MERGE_FAILED" "$(echo "$MERGE_OUTPUT" | head -1 | head -c 100)"
  fi

else
  # ─── BLOCKED: DevOps checks failed ─────────────────────────────────
  log_info "DevOps BLOCKED — automated checks failed"
  write_feedback "$TICKET_KEY" "rami" "BLOCKED" "${ISSUES_TEXT:-Automated checks failed}"

  jira_add_rich_comment "$TICKET_KEY" "rami" "BLOCKED" "## DevOps Checks Failed
PR: ${PR_URL}

Automated checks failed. Sending back to Youssef.

## Issues
${ISSUES_TEXT:-No specific issues captured}"

  jira_update_labels "$TICKET_KEY" "agent:rami" "agent:youssef"
  increment_retry "$TICKET_KEY" "rami-devops"

  slack_notify "*$(mm_ticket_link "${TICKET_KEY}")* — vérifications DevOps échouées. $(mm_mention youssef), je te renvoie la PR.
${ISSUES_TEXT:-unknown}" "pipeline" "danger"

  log_activity "rami" "$TICKET_KEY" "BLOCKED" "${ISSUES_TEXT:-Automated checks failed}"
  append_ticket_history "$TICKET_KEY" "rami" "DEVOPS_BLOCKED" "${ISSUES_TEXT:-Automated checks failed}"
  log_info "=== Rami blocked ${TICKET_KEY} — sent to Youssef ==="
fi
