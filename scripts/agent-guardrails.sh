#!/usr/bin/env bash
# =============================================================================
# agent-guardrails.sh — Pre-PR safety checks for autonomous coding agents
#
# Called by agent-youssef.sh BEFORE creating a PR.
# Blocks the PR and returns exit 1 if any guardrail is violated.
#
# Checks:
#   1. No secrets or credentials in diff
#   2. No dangerous operations (rm -rf, force push, etc.)
#   3. Protected directories not modified
#   4. Diff size within limit (< 350 lines)
#   5. TypeScript typecheck passes
#   6. Tests pass
#   7. No console.log in production code
#   8. Git repo integrity (git fsck --no-full)
#
# Usage: agent-guardrails.sh [BRANCH_NAME] [BASE_BRANCH]
# Returns: 0 = safe to PR, 1 = blocked
# =============================================================================
set -euo pipefail

BRANCH="${1:-HEAD}"
BASE="${2:-master}"
PROJECT_DIR="${PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

cd "$PROJECT_DIR"

VIOLATIONS=0
VIOLATION_DETAILS=""

add_violation() {
  local severity="$1" check="$2" detail="$3"
  VIOLATIONS=$(( VIOLATIONS + 1 ))
  VIOLATION_DETAILS="${VIOLATION_DETAILS}\n[${severity}] ${check}: ${detail}"
  echo "GUARDRAIL VIOLATION [${severity}] ${check}: ${detail}" >&2
}

# ─── 1. Secrets & Credentials ────────────────────────────────────────────────
echo "Guardrail 1/8: Checking for secrets..."

DIFF_TEXT=$(git diff "${BASE}...${BRANCH}" -- . ':!*.lock' ':!package-lock.json' 2>/dev/null || true)

# Patterns that should NEVER appear in a diff
SECRET_PATTERNS=(
  'ANTHROPIC_API_KEY'
  'OPENAI_API_KEY'
  'SLACK_BOT_TOKEN'
  'SLACK_WEBHOOK'
  'MM_BOT_TOKEN'
  'PLANE_API_KEY'
  'GITHUB_TOKEN'
  'AWS_SECRET'
  'DATABASE_URL'
  'PRIVATE_KEY'
  'password\s*=\s*["\x27][^"\x27]{8,}'
  'sk-[a-zA-Z0-9]{20,}'
  'xoxb-[0-9]'
  'ghp_[a-zA-Z0-9]{36}'
)

for pattern in "${SECRET_PATTERNS[@]}"; do
  if echo "$DIFF_TEXT" | grep -qiE "^\+.*${pattern}" 2>/dev/null; then
    add_violation "CRITICAL" "secrets" "Found '${pattern}' in diff — NEVER commit credentials"
  fi
done

# .env files should never be committed
if echo "$DIFF_TEXT" | grep -qE '^\+\+\+ b/.*\.env' 2>/dev/null; then
  add_violation "CRITICAL" "env_file" "Attempting to commit .env file"
fi

# ─── 2. Dangerous Operations ─────────────────────────────────────────────────
echo "Guardrail 2/8: Checking for dangerous operations..."

DANGEROUS_PATTERNS=(
  'rm\s+-rf\s+/'
  'rm\s+-rf\s+\*'
  'git\s+push\s+--force'
  'git\s+reset\s+--hard'
  'DROP\s+TABLE'
  'DROP\s+DATABASE'
  'process\.exit\(0\)'
  'eval\s*\('
  'child_process'
  'exec\s*\('
)

for pattern in "${DANGEROUS_PATTERNS[@]}"; do
  if echo "$DIFF_TEXT" | grep -qiE "^\+.*${pattern}" 2>/dev/null; then
    add_violation "HIGH" "dangerous_op" "Found dangerous pattern: ${pattern}"
  fi
done

# ─── 3. Protected Directories ────────────────────────────────────────────────
echo "Guardrail 3/8: Checking protected directories..."

PROTECTED_DIRS=(
  'n8n/scripts/'
  '.github/'
  'deploy/'
  '.claude/'
  'ai/'
)

CHANGED_FILES=$(git diff --name-only "${BASE}...${BRANCH}" 2>/dev/null || true)

for dir in "${PROTECTED_DIRS[@]}"; do
  if echo "$CHANGED_FILES" | grep -q "^${dir}" 2>/dev/null; then
    add_violation "HIGH" "protected_dir" "Agent modified protected directory: ${dir}"
  fi
done

# ─── 4. Diff Size ────────────────────────────────────────────────────────────
echo "Guardrail 4/8: Checking diff size..."

DIFF_LINES=$(echo "$DIFF_TEXT" | grep -cE '^\+[^+]' 2>/dev/null || echo 0)
DIFF_LIMIT=350

if (( DIFF_LINES > DIFF_LIMIT )); then
  add_violation "WARN" "diff_size" "Diff is ${DIFF_LINES} lines (limit: ${DIFF_LIMIT}) — consider splitting"
fi

# ─── 5. TypeScript Typecheck ─────────────────────────────────────────────────
echo "Guardrail 5/8: Running TypeScript typecheck..."

BUILD_EXIT=0
npm run build --workspace=@bisb/engine 2>/dev/null || BUILD_EXIT=$?
if [[ "$BUILD_EXIT" -ne 0 ]]; then
  add_violation "HIGH" "typecheck" "TypeScript build failed (exit ${BUILD_EXIT})"
fi

# ─── 6. Tests ────────────────────────────────────────────────────────────────
echo "Guardrail 6/8: Running tests..."

TEST_EXIT=0
npm test --workspace=@bisb/engine 2>/dev/null || TEST_EXIT=$?
if [[ "$TEST_EXIT" -ne 0 ]]; then
  add_violation "HIGH" "tests" "Tests failed (exit ${TEST_EXIT})"
fi

# ─── 7. Console.log in Production ────────────────────────────────────────────
echo "Guardrail 7/8: Checking for console.log..."

CONSOLE_LOGS=$(echo "$DIFF_TEXT" | grep -cE '^\+.*console\.(log|debug|warn|error)' 2>/dev/null || echo 0)
if (( CONSOLE_LOGS > 0 )); then
  add_violation "WARN" "console_log" "Found ${CONSOLE_LOGS} console.log statement(s) — remove before merge"
fi

# ─── 8. Git Integrity ────────────────────────────────────────────────────────
echo "Guardrail 8/8: Checking git integrity..."

FSCK_EXIT=0
git fsck --no-full --quiet 2>/dev/null || FSCK_EXIT=$?
if [[ "$FSCK_EXIT" -ne 0 ]]; then
  add_violation "CRITICAL" "git_fsck" "Git repository integrity check failed"
fi

# ─── Results ──────────────────────────────────────────────────────────────────
echo ""
echo "=== Guardrail Results ==="

if [[ "$VIOLATIONS" -eq 0 ]]; then
  echo "All 8 guardrails passed. Safe to create PR."
  exit 0
else
  echo "BLOCKED: ${VIOLATIONS} violation(s) found:"
  echo -e "$VIOLATION_DETAILS"
  echo ""

  # Count by severity
  CRITICAL=$(echo -e "$VIOLATION_DETAILS" | grep -c '\[CRITICAL\]' 2>/dev/null || echo 0)
  HIGH=$(echo -e "$VIOLATION_DETAILS" | grep -c '\[HIGH\]' 2>/dev/null || echo 0)
  WARN=$(echo -e "$VIOLATION_DETAILS" | grep -c '\[WARN\]' 2>/dev/null || echo 0)

  # CRITICAL and HIGH block PR; WARN is advisory
  if (( CRITICAL > 0 || HIGH > 0 )); then
    echo "PR BLOCKED: ${CRITICAL} critical + ${HIGH} high severity violations."
    exit 1
  else
    echo "PR ALLOWED with ${WARN} warning(s). Review recommended."
    exit 0
  fi
fi
