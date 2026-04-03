#!/usr/bin/env bash
# =============================================================================
# agent-nadia.sh — QA Agent: Reviews PRs, runs tests, approves or rejects
# Uses remote refs (no git checkout) so it can run parallel with Youssef.
# =============================================================================
AGENT_NAME="nadia"
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/agent-common.sh"

# Override base branch: diff against dev, not master
BASE_BRANCH="${BASE_BRANCH:-dev}"

TICKET_KEY="${1:?Usage: agent-nadia.sh BISB-XX}"
MAX_RETRIES=2  # Cap at 2 — after 2 Nadia FAILs, escalate to human instead of ping-ponging

init_log "$TICKET_KEY" "nadia"
log_info "=== Nadia (QA) starting review of ${TICKET_KEY} ==="
JIRA_URL="$(jira_link "$TICKET_KEY")"

# ─── 1. Check retry count + cooldown ────────────────────────────────────────
retry_count=$(get_retry_count "$TICKET_KEY" "nadia")
if (( retry_count >= MAX_RETRIES )); then
  # ─── STOP — hand off to Omar immediately ────────────────────────────────
  log_info "Max retries ($MAX_RETRIES) reached for ${TICKET_KEY}. Handing off to Omar."
  FEEDBACK_ISSUES=$({ cat "${FEEDBACK_DIR}/${TICKET_KEY}.txt" 2>/dev/null || true; } | { grep '^- ' || true; } | head -5)
  jira_add_rich_comment "$TICKET_KEY" "nadia" "WARNING" "## Max Retries Reached — Handoff to Omar
QA échoué ${MAX_RETRIES} fois. Je me déassigne et transmets à Omar pour triage.

## Derniers problèmes détectés
${FEEDBACK_ISSUES:-Pas de feedback structuré disponible}"
  # Unassign Nadia → assign Omar + mark blocked
  plane_set_assignee "$TICKET_KEY" "omar" 2>/dev/null || true
  jira_add_label "$TICKET_KEY" "blocked" 2>/dev/null || true
  slack_notify "nadia" "$(mm_ticket_link "${TICKET_KEY}") — QA échoué ${MAX_RETRIES} fois. Ticket transféré à @omar-ai pour triage. 🔴" "pipeline" "warning" 2>/dev/null || true
  log_activity "nadia" "$TICKET_KEY" "HANDOFF_OMAR" "Hit ${MAX_RETRIES} retries, unassigned → Omar"
  exit 0  # do NOT reset retry — Omar needs the file to detect this
fi

if ! check_cooldown "$TICKET_KEY" "nadia"; then
  exit 0
fi

# ─── 2. Fetch ticket details ─────────────────────────────────────────────────
log_info "Fetching ticket details..."
SUMMARY=$(jira_get_ticket_field "$TICKET_KEY" "summary")
DESCRIPTION=$(jira_get_description_text "$TICKET_KEY")
PRIORITY=$(jira_get_ticket_field "$TICKET_KEY" "priority")
LABELS=$(jira_get_ticket_field "$TICKET_KEY" "labels")

# Default: Sonnet for QA — Haiku produces too many UNKNOWN verdicts
# Upgraded to Opus when PR touches sensitive agent files (ai/*.md, n8n/scripts/agent-*.sh)
MODEL="sonnet"
MODEL=$(select_model_rate_aware "$MODEL" "nadia" "general")
MODEL=$(activate_api_key_if_needed "$MODEL")
if [[ "$MODEL" == "WAIT" ]]; then
  log_info "Sonnet rate-limited — nadia must wait (QA needs Sonnet, no API key)"
  exit 0
fi

if [[ -z "$SUMMARY" ]]; then
  log_error "Could not fetch ticket ${TICKET_KEY}"
  exit 1
fi

log_info "Ticket: ${SUMMARY}"

# ─── 2b. Handle retro-action: comment with QA perspective, hand to Salma ─────
if echo "$LABELS" | grep -q "retro-action" 2>/dev/null; then
  if ! echo "$LABELS" | grep -q "enriched" 2>/dev/null; then
    log_info "Retro-action ticket — writing QA perspective comment and handing to Salma"

    COMMENTS=$(jira_get_comments "$TICKET_KEY")

    RETRO_PROMPT="You are Nadia, the QA agent for BisB (Business is Business).

TICKET: ${TICKET_KEY}
TITLE: ${SUMMARY}
DESCRIPTION:
${DESCRIPTION:-No description provided}

EXISTING COMMENTS:
${COMMENTS:-None}

This is a retrospective action item assigned to you for your QA PERSPECTIVE.
Do NOT review any PR. Instead, write a concise comment (max 300 words) covering:
1. How this action item affects QA processes and test coverage
2. What validation rules or checks should be added/modified
3. How to verify this improvement is working (testable criteria)
4. Any risks to existing QA workflows
5. Suggested acceptance criteria from a QA perspective

IMPORTANT: Consider your own constraints:
- You review code via remote refs (no local checkout)
- You have READ access to source files for deeper review context
- Any new QA rules must be inlined in your prompt (agent-nadia.sh), not in separate files

Output ONLY the comment text — no preamble, no markdown headers."

    RETRO_COMMENT=$(cd "$PROJECT_DIR" && claude -p "$RETRO_PROMPT" \
      --disallowedTools "Write Edit Bash" \
      --model haiku --max-turns 1 2>/dev/null) || true

    if [[ -n "$RETRO_COMMENT" && ${#RETRO_COMMENT} -gt 20 ]]; then
      jira_add_rich_comment "$TICKET_KEY" "nadia" "INFO" "## QA Perspective (Nadia)
${RETRO_COMMENT}

Handing to Salma for spec writing."
    else
      jira_add_rich_comment "$TICKET_KEY" "nadia" "INFO" "## QA Perspective (Nadia)
Reviewed retro-action item. Handing to Salma for spec writing."
    fi

    jira_update_labels "$TICKET_KEY" "agent:nadia" "agent:salma"
    log_activity "nadia" "$TICKET_KEY" "RETRO_COMMENT" "Wrote QA perspective for retro-action, handed to Salma"
    slack_notify "J'ai donné ma perspective QA sur $(mm_ticket_link "${TICKET_KEY}"). Salma, je te transmets pour la spec — quelques points à clarifier avant qu'on puisse reviewer le code." "pipeline"
    log_info "=== Nadia wrote retro-action comment for ${TICKET_KEY} ==="
    exit 0
  fi
fi

# ─── 3. Find the PR ──────────────────────────────────────────────────────────
log_info "Looking for PR..."
cd "$PROJECT_DIR"

PR_URL=$(find_pr_for_ticket "$TICKET_KEY")
if [[ -z "$PR_URL" ]]; then
  log_error "No open PR found for ${TICKET_KEY}"
  jira_add_rich_comment "$TICKET_KEY" "nadia" "BLOCKED" "No open PR found for this ticket. Cannot review."
  exit 1
fi

log_info "Found PR: ${PR_URL}"

# Get PR branch
PR_BRANCH=$(find_pr_branch "$TICKET_KEY")
if [[ -z "$PR_BRANCH" ]]; then
  log_error "Could not determine PR branch for ${TICKET_KEY}"
  exit 1
fi

log_info "PR branch: ${PR_BRANCH}"

# ─── 4. Fetch remote refs (NO checkout — Youssef may be working) ────────────
log_info "Fetching remote refs (no checkout)..."
cd "$PROJECT_DIR"
git fetch origin 2>/dev/null

# Use remote refs for diff — never touch the working tree
DIFF=$(git diff "${BASE_BRANCH}...origin/${PR_BRANCH}" 2>/dev/null | head -c 50000 || true)
DIFF_STATS=$(git diff "${BASE_BRANCH}...origin/${PR_BRANCH}" --stat 2>/dev/null)
DIFF_SIZE=$(echo "$DIFF_STATS" | tail -1 | { grep -oE '[0-9]+ insertion|[0-9]+ deletion' || true; } | awk '{s+=$1}END{print s+0}')
DIFF_SIZE="${DIFF_SIZE:-0}"
FILES_CHANGED=$(git diff "${BASE_BRANCH}...origin/${PR_BRANCH}" --name-only 2>/dev/null)

log_info "Diff size: ${DIFF_SIZE} lines changed"

# Code-only diff (exclude docs/config from line count)
CODE_DIFF_STAT=$(git diff "${BASE_BRANCH}...origin/${PR_BRANCH}" --stat -- '*.ts' '*.tsx' '*.jsx' '*.css' ':!*.d.ts' ':!*.d.ts.map' ':!*.js.map' 2>/dev/null || true)
CODE_DIFF_SIZE=$(echo "$CODE_DIFF_STAT" | tail -1 | { grep -oE '[0-9]+ insertion|[0-9]+ deletion' || true; } | awk '{s+=$1}END{print s+0}')
CODE_DIFF_SIZE="${CODE_DIFF_SIZE:-0}"
DOCS_DIFF_SIZE=$(( DIFF_SIZE - CODE_DIFF_SIZE ))

log_info "Code diff: ${CODE_DIFF_SIZE} lines, Docs/config diff: ${DOCS_DIFF_SIZE} lines"
log_info "Files changed:\n${FILES_CHANGED}"

# ─── 4b. Upgrade model for sensitive agent files ─────────────────────────────
MODEL=$(upgrade_model_for_sensitive_files "$MODEL" "$FILES_CHANGED")

# ─── 4c. Diff classifier — fast-path for low-risk PRs ────────────────────────
# Classifies the PR into one of 4 modes, adjusts model + prompt depth accordingly:
#   test-only  → only *.test.ts / *.spec.ts files changed → Haiku, 1 turn, test quality only
#   docs-only  → only .md/.sh/.yml/.json changed           → Haiku, 1 turn, content accuracy only
#   small-fix  → code diff ≤ 25 lines                      → Haiku, 1 turn, focused review
#   standard   → everything else                            → Sonnet, 3 turns, full QA checklist
REVIEW_MODE="standard"
REVIEW_MODE_REASON="mixed changes"

TOTAL_FILES=$(echo "$FILES_CHANGED" | grep -c . 2>/dev/null || echo 0)
TEST_FILES=$(echo "$FILES_CHANGED"  | grep -cE '\.(test|spec)\.(ts|tsx|js|jsx)$' 2>/dev/null || echo 0)
DOCS_FILES=$(echo "$FILES_CHANGED"  | grep -cE '\.(md|sh|yml|yaml|json|txt|example)$' 2>/dev/null || echo 0)

if [[ "$TOTAL_FILES" -gt 0 && "$TEST_FILES" -eq "$TOTAL_FILES" ]]; then
  REVIEW_MODE="test-only"
  REVIEW_MODE_REASON="${TEST_FILES} test file(s) only"
  # Don't downgrade if model was upgraded for sensitive files (opus > sonnet)
  [[ "$MODEL" == "sonnet" ]] && MODEL="haiku"
elif [[ "$TOTAL_FILES" -gt 0 && "$DOCS_FILES" -eq "$TOTAL_FILES" ]]; then
  REVIEW_MODE="docs-only"
  REVIEW_MODE_REASON="${DOCS_FILES} docs/config file(s) only"
  [[ "$MODEL" == "sonnet" ]] && MODEL="haiku"
elif [[ "$CODE_DIFF_SIZE" -le 25 && "$TOTAL_FILES" -gt 0 ]]; then
  REVIEW_MODE="small-fix"
  REVIEW_MODE_REASON="code diff ${CODE_DIFF_SIZE} lines (≤25)"
  [[ "$MODEL" == "sonnet" ]] && MODEL="haiku"
fi

REVIEW_MAX_TURNS=3
[[ "$REVIEW_MODE" != "standard" ]] && REVIEW_MAX_TURNS=1

log_info "Model: ${MODEL} | Review mode: ${REVIEW_MODE} (${REVIEW_MODE_REASON}) | max-turns: ${REVIEW_MAX_TURNS}"

# ─── 5. Quality checks (read from remote, no local build) ───────────────────
QUALITY_REPORT="## Quality Checks
- TypeScript: VERIFIED BY YOUSSEF (pre-PR)
- Lint: VERIFIED BY YOUSSEF (pre-PR)
- Build: VERIFIED BY YOUSSEF (pre-PR)
- Note: Nadia reviews code via remote refs + can Read/Grep source files for context"

log_info "$QUALITY_REPORT"

# ─── 6. Fetch sprint context for cross-ticket awareness ────────────────────
SPRINT_CONTEXT=$(curl -s -X POST \
  -H "Authorization: Basic $(jira_auth)" \
  -H "Content-Type: application/json" \
  "${JIRA_BASE_URL}/rest/api/3/search/jql" \
  -d "{\"jql\":\"project=${JIRA_PROJECT} AND labels='sprint-active' AND key != '${TICKET_KEY}' AND statusCategory != 'Done'\",\"fields\":[\"summary\"],\"maxResults\":10}" \
  | python3 -c "
import sys,json
d=json.load(sys.stdin)
for i in d.get('issues',[]):
    print(f\"- {i['key']}: {i['fields']['summary']}\")
" 2>/dev/null || echo "Could not fetch sprint context")

log_info "Sprint context:\n${SPRINT_CONTEXT}"

# ─── 6b. Get Hedi messages for Nadia ──────────────────────────────────────
HEDI_CONTEXT=""
HEDI_MESSAGES=$(get_hedi_messages "nadia" 2>/dev/null || true)
if [[ -n "$HEDI_MESSAGES" ]]; then
  HEDI_CONTEXT="

MESSAGES FROM HEDI (human lead):
${HEDI_MESSAGES}

Incorporate Hedi's clarifications into your QA review. His feedback takes priority."
  log_info "Injected Hedi's messages into Nadia's prompt"
fi

# ─── 7. Invoke Claude Code for code review ──────────────────────────────────
log_info "Invoking Claude Code (${MODEL}) for QA review..."

# ─── 7a. Inject sprint failure patterns from latest QA report ────────────────
FAILURE_PATTERNS=""
LATEST_REPORT=$(ls -t "${SCRIPT_DIR}/../reports/qa-failure-analysis-"*.md 2>/dev/null | head -1 || true)
if [[ -n "$LATEST_REPORT" && -f "$LATEST_REPORT" ]]; then
  FAILURE_PATTERNS=$(grep -E '^\*\*Root Cause|^- [0-9]+%|failure rate|most common' "$LATEST_REPORT" 2>/dev/null | head -5 || true)
  [[ -n "$FAILURE_PATTERNS" ]] && log_info "Injecting failure patterns from $(basename "$LATEST_REPORT")"
fi

# ─── 7b. Detect template-only PRs (need integration verification) ────────────
TEMPLATE_ONLY_CHECK=""
if echo "$FILES_CHANGED" | grep -qE '^(ai/|\.github/.*\.md|.*template|.*checklist)' 2>/dev/null; then
  HAS_AGENT_SCRIPT_CHANGE=$(echo "$FILES_CHANGED" | grep -c 'n8n/scripts/agent-' 2>/dev/null || true)
  if [[ "${HAS_AGENT_SCRIPT_CHANGE:-0}" -eq 0 ]]; then
    TEMPLATE_ONLY_CHECK="
CRITICAL INTEGRATION CHECK:
This PR adds markdown templates, checklists, or documentation files but does NOT modify
any agent script (n8n/scripts/agent-*.sh). Templates without integration are DECORATIVE ONLY —
no agent will read or use them. You MUST mark FAIL unless the files are purely for human reference
(e.g., README updates). If the PR creates process templates, checklists, or guides that claim to
affect agent behavior but doesn't wire them into agent scripts — FAIL with clear explanation."
  fi
fi

# ─── 7b-fast. Fast-path prompt for non-standard review modes ─────────────────
# For test-only / docs-only / small-fix, skip the full 9-point QA checklist.
# This saves 2-3x API cost and is appropriate for low-risk PRs.
if [[ "$REVIEW_MODE" == "test-only" ]]; then
  QA_RULES_HEADER="You are Nadia, the QA agent for BisB (Business is Business).

FAST-PATH REVIEW: TEST FILES ONLY — skip all code quality checks.
Your ONLY job here is to verify the tests themselves are useful:
1. Tests actually test meaningful behaviour (not just echo the implementation)
2. Edge cases are covered (empty inputs, boundary values, error paths)
3. No flaky patterns (random, date-dependent, network calls without mocks)
4. Test descriptions clearly name what is being tested

Output format:
VERDICT: PASS  (if tests are reasonable)
VERDICT: PASS_WITH_WARNINGS + WARNINGS: bullet list  (if tests could be improved)
VERDICT: FAIL + ISSUES: bullet list  (only if tests are fundamentally broken)"

elif [[ "$REVIEW_MODE" == "docs-only" ]]; then
  QA_RULES_HEADER="You are Nadia, the QA agent for BisB (Business is Business).

FAST-PATH REVIEW: DOCS/CONFIG FILES ONLY — skip all code checks.
Your ONLY job is to verify the documentation is accurate and complete:
1. No factual errors or references to non-existent files/functions
2. Instructions are clear and would work if followed
3. No sensitive information (credentials, internal URLs) committed by mistake
4. Consistent terminology with the rest of the project

Output a VERDICT: PASS / PASS_WITH_WARNINGS / FAIL with brief justification."

elif [[ "$REVIEW_MODE" == "small-fix" ]]; then
  QA_RULES_HEADER="You are Nadia, the QA agent for BisB (Business is Business).

FAST-PATH REVIEW: SMALL FIX (${CODE_DIFF_SIZE} lines) — abbreviated check.
Focus only on:
1. No introduced bugs or regressions (check the specific lines changed)
2. No hardcoded secrets or debug console.log statements
3. Money values still use integer cents (if monetary code touched)
4. AC from spec are met (verify individually if spec has ACs)

Output a VERDICT: PASS / PASS_WITH_WARNINGS / FAIL with brief justification."

else
# ─── Standard full prompt (unchanged) ─────────────────────────────────────
# Always inline QA rules — never let Claude waste turns reading files
QA_RULES_HEADER="You are Nadia, the QA agent for BisB (Business is Business).

QA CHECKLIST — PRE-PR VERIFICATION (zero-rejection target)
These checks prevent 95% of historical QA failures. Review EVERY item:

1️⃣ LINE COUNT LIMITS (prevents 67% of failures)
   - CODE files (.ts/.tsx/.js/.jsx/.css): MAX 300 lines total
   - Count only insertions+deletions in code files
   - Documentation (.md/.sh/.yml/.example/.json): NO LIMIT
   - ❌ FAIL if code diff >300 lines (no exceptions)
   - ✅ PASS if docs >300 but code <300

2️⃣ MONEY FORMAT VALIDATION (prevents 14% of failures)
   - ALL monetary fields MUST use z.number().int().positive()
   - Search for: amount, price, cost, valuation, fee, balance, payment
   - ❌ FAIL if ANY money field uses z.number() without .int()
   - ❌ FAIL if money stored/displayed as float
   - ✅ PASS only if ALL money fields enforce integers (cents)

3️⃣ TYPE SAFETY (prevents data integrity issues)
   - Engine state must use TypeScript interfaces (no any types)
   - All player actions must be validated before execution
   - ALL API payloads MUST be validated
   - ❌ FAIL if game state is mutated directly (must use immutable updates)
   - ✅ PASS only if all state changes go through proper engine methods

4️⃣ DEBUG LOGGING (prevents 5% of failures)
   - ZERO console.log, console.warn, console.info in production code
   - ONLY console.error allowed in error boundaries
   - ❌ FAIL if ANY debug logging found
   - ✅ PASS only if no console statements (except error boundaries)

5️⃣ ACCEPTANCE CRITERIA COMPLIANCE (prevents 14% of failures)
   - EVERY AC from spec MUST be implemented
   - Report individually: ✅ AC1 verified, ❌ AC2 missing
   - Include count: AC_VERIFIED: X/Y
   - ❌ FAIL if X < Y (incomplete implementation)
   - ✅ PASS only if X == Y (all ACs met)

6️⃣ SECURITY & DATA EXPOSURE
   - No hardcoded secrets (.env values, API keys, tokens)
   - Auth required on protected routes
   - Engine/web separation maintained (no game logic in React components)
   - No sensitive data in console/logs
   - ❌ FAIL if ANY security issue found

7️⃣ CODE QUALITY STANDARDS
   - TypeScript strict mode (verified by Youssef pre-PR)
   - ESLint passes (verified by Youssef pre-PR)
   - Build succeeds (verified by Youssef pre-PR)
   - No unnecessary dependencies added
   - Follows existing patterns in src/
   - Error states handled gracefully
   - UI uses React + TailwindCSS + Zustand

8️⃣ DEVOPS ACCEPTANCE CRITERIA (check EVERY ticket)
   Security:
   - ❌ FAIL if hardcoded secrets (API keys, passwords, tokens) in diff
   - ❌ FAIL if .env files committed
   - ✅ PASS if environment variables used (import.meta.env.*)
   - ❌ FAIL if database changes lack RLS policies (auth.uid() checks required)

   TypeScript Strictness:
   - ❌ FAIL if 'any' types found in new code (must use explicit types)
   - ❌ FAIL if game logic leaks into React components (engine/web separation)
   - ❌ FAIL if new engine code lacks Vitest tests

   RLS Constraints (applies to database changes):
   - ❌ FAIL if new tables lack RLS policies (SELECT/INSERT/UPDATE/DELETE)
   - ❌ FAIL if user-specific queries missing user ID filters
   - ❌ FAIL if protected routes lack auth guards

   Money Handling (applies to monetary fields):
   - ❌ FAIL if money fields use z.number() without .int()
   - ❌ FAIL if floating-point math on money values
   - ✅ PASS only if money stored as integer cents

9️⃣ TEST CASES SECTION COMPLIANCE (spec quality gate)
   The spec MUST include a '## Test Cases' section with subsections:
   ### Happy Path, ### Edge Cases, ### Permission Boundaries, ### Failure Modes
   - Implementation MUST handle each Failure Mode listed in the spec (try/catch, error UI, or 403/404 response)
   - Implementation MUST respect each Permission Boundary listed (RLS, route guard, or role check)
   - ❌ FAIL if Failure Modes listed in spec have no corresponding error handling in diff
   - ❌ FAIL if Permission Boundaries listed are not enforced in the implementation
   - ⚠️ PASS_WITH_WARNINGS if spec has Test Cases section but implementation covers < all listed scenarios
   - ✅ PASS if all listed failure modes and permission boundaries are addressed
   Report: TC_VERIFIED: X/Y (test cases covered out of total listed)
   If TC_VERIFIED < TC_TOTAL, downgrade overall verdict to PASS_WITH_WARNINGS (not FAIL, unless Failure Modes are entirely missing)

${FAILURE_PATTERNS:+
📊 SPRINT FAILURE PATTERNS (be extra strict on these):
${FAILURE_PATTERNS}}
${TEMPLATE_ONLY_CHECK}

CI VALIDATION CRITERIA FORMAT (reference when testing PRs):
When the spec includes a '## CI Validation' section, verify against these automated checks:
• TypeScript: 'tsc --noEmit passes with 0 errors, no any types' (verified by Youssef pre-PR)
• Build: 'npm run build succeeds without warnings' (verified by Youssef pre-PR)
• Lint: 'npm run lint passes ESLint rules' (verified by Youssef pre-PR)
• Security: 'Game tests pass: npm test --workspace=@bisb/engine' (Rami automated check)
• Security: 'No hardcoded secrets' (Rami automated grep check)
• Line Limits: 'No file >200 lines, PR <250 lines total' (Rami automated check)
• DevOps: 'DevOps approval required for database/RLS/auth/config changes' (Rami review flag)

If the spec references 'validated in pipeline', match to the automated checks above.
If it says 'requires manual review', verify the acceptance criteria includes DevOps checkbox.

DEFINITION OF DONE — ACCEPTANCE CRITERIA VERIFICATION:
For EACH acceptance criterion in the specification, you MUST verify it individually and report:
  ✅ AC1: [short description] — verified
  ❌ AC2: [short description] — NOT implemented because [reason]
At the end, include a count: AC_VERIFIED: X/Y
If X < Y, you MUST use VERDICT: FAIL (not all acceptance criteria met).

TEST CASES VERIFICATION:
If the spec includes a '## Test Cases' section, also report TC_VERIFIED: X/Y.
If TC_VERIFIED < TC_TOTAL, downgrade PASS to PASS_WITH_WARNINGS in your verdict.

DO NOT use any tools. DO NOT try to read files. The full diff is below — review it directly."

fi  # end REVIEW_MODE else (standard)

CLAUDE_PROMPT="${QA_RULES_HEADER}

TICKET: ${TICKET_KEY}
TITLE: ${SUMMARY}
PRIORITY: ${PRIORITY}

SPECIFICATION:
${DESCRIPTION}

FILES CHANGED:
${FILES_CHANGED}

DIFF STATS:
${DIFF_STATS}

DIFF (first 50KB):
${DIFF}

YOUR TASK:
1. Read the specification above carefully
2. Review the diff above against the QA checklist provided at the top of this prompt
3. Verify:
   - All acceptance criteria from the spec are implemented
   - No hardcoded secrets or console.log statements
   - No exposed sensitive data
   - Error handling is present
   - Input validation uses TypeScript types
   - Money values are in cents (integers)
   - UI uses React + TailwindCSS + Zustand
   - Code follows existing patterns in src/
   - No unnecessary dependencies added
   - CODE diff is ${CODE_DIFF_SIZE} lines (limit: 300 for code files: .ts/.tsx/.js/.jsx/.css)
   - Docs/config diff is ${DOCS_DIFF_SIZE} lines (NO limit for .md, .sh, .yml, .example files)
   - Only FAIL for CODE exceeding 300 lines. Documentation and config are exempt
   - Auth/RLS rules are enforced where needed

   SPRINT CONTEXT — Other active tickets in this sprint:
${SPRINT_CONTEXT}
${HEDI_CONTEXT}
   IMPORTANT: If a feature is incomplete but another sprint ticket above will address it,
   use PASS_WITH_WARNINGS (not FAIL). Placeholders, stub pages, and TODO comments are
   acceptable when a follow-up ticket explicitly covers them. Only FAIL for issues that
   no other sprint ticket will fix.

6. Produce a verdict in this EXACT format at the end of your response:

VERDICT: PASS
or
VERDICT: PASS_WITH_WARNINGS
WARNINGS:
- Warning 1: description (will be addressed by TICKET-XXX)
- Warning 2: minor style issue, not blocking
or
VERDICT: FAIL
ISSUES:
- Issue 1: description
- Issue 2: description

Use PASS_WITH_WARNINGS when:
- Placeholder code exists but a later sprint ticket explicitly replaces it
- Minor style issues that don't affect functionality
- Technical debt that is tracked and acceptable for now

Be thorough but fair. Only FAIL for real issues that affect functionality, security, or code quality.
Do NOT fail for style preferences, minor naming choices, or placeholders covered by other tickets.

IMPORTANT: List ALL issues in a single review. Do NOT drip-feed issues across multiple rounds.
If you FAIL, list every issue you can find — not just the first few. Youssef only gets 2 revision
cycles before human escalation, so your feedback must be complete on the first pass.

CRITICAL: You MUST output a VERDICT line. If you are running low on turns, stop exploring files
and produce your verdict immediately based on what you have reviewed so far. A partial review with
a verdict is infinitely better than a thorough review with no verdict.

HUMAN INPUT REQUEST (optional):
If you need real-world context that only a human can provide (e.g., regulatory confirmations,
business decisions, information from external meetings), you may add this line ANYWHERE in your output:
NEEDS_HUMAN_INPUT: <your specific question for Hedi>
This will NOT block the review — you should still give your best verdict based on the code.
The question will be posted to Slack for Hedi to answer in the next cycle."

# Write prompt to temp file — use printf '%s' to preserve special chars in diff
PROMPT_FILE=$(mktemp /tmp/nadia-prompt-XXXXXX.txt)
printf '%s' "$CLAUDE_PROMPT" > "$PROMPT_FILE"
log_info "Prompt file: ${PROMPT_FILE} ($(wc -c < "$PROMPT_FILE") bytes)"

# Capture stdout and stderr separately
CLAUDE_STDOUT_FILE=$(mktemp /tmp/nadia-stdout-XXXXXX.txt)
CLAUDE_STDERR_FILE=$(mktemp /tmp/nadia-stderr-XXXXXX.txt)

# Read-only mode — Nadia can read source files for deeper review context
# but cannot write, edit, or execute anything
log_info "Read-only mode, up to ${REVIEW_MAX_TURNS} turn(s) (${DIFF_SIZE} lines, mode=${REVIEW_MODE})"
cd "$PROJECT_DIR" && claude -p - \
  --disallowedTools "Write Edit Bash" \
  --model $MODEL --max-turns "$REVIEW_MAX_TURNS" \
  < "$PROMPT_FILE" \
  > "$CLAUDE_STDOUT_FILE" 2> "$CLAUDE_STDERR_FILE" || true

CLAUDE_OUTPUT=$(cat "$CLAUDE_STDOUT_FILE")
CLAUDE_STDERR=$(cat "$CLAUDE_STDERR_FILE")

if [[ -n "$CLAUDE_STDERR" ]]; then
  log_info "Claude stderr: $(echo "$CLAUDE_STDERR" | head -5)"
fi
if [[ -z "$CLAUDE_OUTPUT" && -n "$CLAUDE_STDERR" ]]; then
  CLAUDE_OUTPUT="$CLAUDE_STDERR"
fi

log_info "Claude output size: $(echo "$CLAUDE_OUTPUT" | wc -c) bytes"
rm -f "$CLAUDE_STDOUT_FILE" "$CLAUDE_STDERR_FILE"

rm -f "$PROMPT_FILE"

log_info "Claude QA output:"
echo "$CLAUDE_OUTPUT" >> "$LOG_FILE"

# ─── 8. Parse verdict ────────────────────────────────────────────────────────
log_info "Parsing verdict..."

# Write output to temp file for reliable parsing
AGENT_TMPFILE=$(mktemp /tmp/${PROJECT_PREFIX}-agent-XXXXXX.txt)
printf '%s\n' "$CLAUDE_OUTPUT" > "$AGENT_TMPFILE"
VERDICT=$(parse_verdict "$AGENT_TMPFILE")
rm -f "$AGENT_TMPFILE"
log_info "Parsed verdict: $VERDICT"

# ─── 8b. Enforce AC verification count ──────────────────────────────────────
if [[ "$VERDICT" == "PASS" || "$VERDICT" == "PASS_WITH_WARNINGS" ]]; then
  AC_LINE=$(echo "$CLAUDE_OUTPUT" | grep -oE 'AC_VERIFIED: [0-9]+/[0-9]+' | tail -1 || true)
  if [[ -n "$AC_LINE" ]]; then
    AC_DONE=$(echo "$AC_LINE" | grep -oE '[0-9]+' | head -1)
    AC_TOTAL=$(echo "$AC_LINE" | grep -oE '[0-9]+' | tail -1)
    if [[ -n "$AC_DONE" && -n "$AC_TOTAL" ]] && (( AC_DONE < AC_TOTAL )); then
      log_info "AC verification failed: ${AC_DONE}/${AC_TOTAL} — overriding verdict to FAIL"
      VERDICT="FAIL"
    else
      log_info "AC verification: ${AC_LINE}"
    fi
  else
    log_info "No AC_VERIFIED count found in output (non-blocking)"
  fi
fi

# ─── 8c. Detect NEEDS_HUMAN_INPUT requests ──────────────────────────────────
# If Nadia's review identified a need for human clarification, post to Slack
HUMAN_INPUT_QUESTION=$(echo "$CLAUDE_OUTPUT" | { grep -oP 'NEEDS_HUMAN_INPUT:\s*(.+)' || true; } | head -1 | sed 's/NEEDS_HUMAN_INPUT:\s*//')
if [[ -n "$HUMAN_INPUT_QUESTION" ]]; then
  log_info "Nadia needs human input: ${HUMAN_INPUT_QUESTION}"

  # Post question to #si-alerts
  SAVED_AGENT="$AGENT_NAME"
  AGENT_NAME="nadia"
  QUESTION_MSG="📋 *Nadia needs your input on ${TICKET_KEY}:*
\"${HUMAN_INPUT_QUESTION}\"

Reply in #si-pipeline with \`@nadia <your answer>\` and I'll incorporate it in the next QA cycle."
  slack_notify "$QUESTION_MSG" "alerts" "warning"
  AGENT_NAME="$SAVED_AGENT"

  # Add label for tracking (doesn't block other tickets)
  jira_add_label "$TICKET_KEY" "needs-human-input"
  jira_add_rich_comment "$TICKET_KEY" "nadia" "PENDING" "## Human Input Needed
${HUMAN_INPUT_QUESTION}

Waiting for Hedi's response via Slack. QA review will continue regardless."
  log_info "Posted human input question to Slack alerts"
fi

# ─── 9. Act on verdict ───────────────────────────────────────────────────────
if [[ "$VERDICT" == "PASS" ]]; then
  # ─── PASS: Forward to Rami for DevOps checks + merge ────────────────────
  log_info "QA PASSED — forwarding to Rami (DevOps)"

  REVIEW_SUMMARY=$(echo "$CLAUDE_OUTPUT" | tail -20 | head -15)

  jira_add_rich_comment "$TICKET_KEY" "nadia" "PASS" "## QA Passed
PR: ${PR_URL}
Lines changed: ${DIFF_SIZE} (code: ${CODE_DIFF_SIZE})

## Review Summary
${REVIEW_SUMMARY}

Handing to Rami for DevOps verification and merge."

  jira_update_labels "$TICKET_KEY" "agent:nadia" "agent:rami"
  jira_transition "$TICKET_KEY" "review" || true
  reset_retry "$TICKET_KEY" "nadia"

  PR_NUM=$(echo "$PR_URL" | grep -oE '[0-9]+$')
  slack_notify "$(mm_ticket_link "${TICKET_KEY}") validé — tous les critères couverts, diff ${CODE_DIFF_SIZE} lignes, règles du jeu respectées. Je transmets à Rami pour l'intégration. Bon boulot Youssef 👏
[PR #${PR_NUM}](${PR_URL})" "pipeline" "good"

  log_activity "nadia" "$TICKET_KEY" "PASS" "QA approved: ${SUMMARY}"
  log_success "=== Nadia approved ${TICKET_KEY} ==="

elif [[ "$VERDICT" == "PASS_WITH_WARNINGS" ]]; then
  # ─── PASS WITH WARNINGS: Forward to Rami with warnings ──────────────────
  log_info "QA PASSED WITH WARNINGS — forwarding to Rami (DevOps)"

  WARNINGS=$(echo "$CLAUDE_OUTPUT" | sed -n '/VERDICT: PASS_WITH_WARNINGS/,$ p' | tail -n +2)

  jira_add_rich_comment "$TICKET_KEY" "nadia" "PASS_WITH_WARNINGS" "## QA Passed with Warnings
PR: ${PR_URL}
Lines changed: ${DIFF_SIZE} (code: ${CODE_DIFF_SIZE})

## Warnings (non-blocking)
${WARNINGS}

Forwarding to Rami for DevOps verification and merge."

  jira_update_labels "$TICKET_KEY" "agent:nadia" "agent:rami"
  jira_transition "$TICKET_KEY" "review" || true
  reset_retry "$TICKET_KEY" "nadia"

  PR_NUM=$(echo "$PR_URL" | grep -oE '[0-9]+$')
  SLACK_WARNINGS=$(echo "$WARNINGS" | strip_markdown | grep '^- ' | head -3 || true)
  slack_notify "$(mm_ticket_link "${TICKET_KEY}") approuvé avec réserves — fonctionnel, mais quelques points à surveiller pour les prochaines PRs. Rami, c'est à toi.
[PR #${PR_NUM}](${PR_URL})
${SLACK_WARNINGS}" "pipeline" "warning"

  log_activity "nadia" "$TICKET_KEY" "PASS_WITH_WARNINGS" "QA approved with warnings: ${SUMMARY}"
  log_success "=== Nadia approved ${TICKET_KEY} (with warnings) ==="

elif [[ "$VERDICT" == "FAIL" ]]; then
  # ─── FAIL: Send back to Youssef ─────────────────────────────────────────
  log_info "QA FAILED — sending back to Youssef"

  ISSUES=$(echo "$CLAUDE_OUTPUT" | sed -n '/VERDICT: FAIL/,$ p' | tail -n +2)

  write_feedback "$TICKET_KEY" "nadia" "FAIL" "$ISSUES"

  jira_add_rich_comment "$TICKET_KEY" "nadia" "FAIL" "## QA Failed
Attempt $((retry_count + 1))/${MAX_RETRIES}

PR: ${PR_URL}
Lines changed: ${DIFF_SIZE} (code: ${CODE_DIFF_SIZE})

## Issues Found
${ISSUES}

Sending back to Youssef for fixes."

  jira_update_labels "$TICKET_KEY" "agent:nadia" "agent:youssef"
  increment_retry "$TICKET_KEY" "nadia"

  PR_NUM=$(echo "$PR_URL" | grep -oE '[0-9]+$')
  SLACK_ISSUES=$(echo "$ISSUES" | strip_markdown | grep '^- ' | head -3 || true)
  slack_notify "$(mm_ticket_link "${TICKET_KEY}") refusé (tentative $((retry_count + 1))/${MAX_RETRIES}) — j'ai listé les points bloquants dans le ticket. Youssef, je te laisse corriger, c'est détaillé.
[PR #${PR_NUM}](${PR_URL})
${SLACK_ISSUES}" "pipeline" "danger"

  ISSUES_PREVIEW=$(echo "$ISSUES" | head -3 | tr '\n' '; ' | head -c 120)
  log_activity "nadia" "$TICKET_KEY" "FAIL" "${ISSUES_PREVIEW}"
  log_info "=== Nadia rejected ${TICKET_KEY} ==="

else
  # ─── UNKNOWN verdict: Parsing issue — do NOT burn a retry ────────────────
  log_error "Could not parse verdict from Claude output"
  # Do NOT increment retry — this is a parsing issue, not a real QA failure
  jira_add_rich_comment "$TICKET_KEY" "nadia" "WARNING" "Review inconclusive (parsing issue). Will retry next cycle. Not counted as failure."

  slack_notify "Review de $(mm_ticket_link "${TICKET_KEY}") inconclusif — problème d'analyse interne, pas un vrai FAIL. Je réessaie au prochain cycle sans compter cette tentative." "pipeline"

  log_info "=== Nadia review inconclusive for ${TICKET_KEY} ==="
fi
