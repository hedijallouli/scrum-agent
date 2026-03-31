#!/usr/bin/env bash
# =============================================================================
# sprint-zero.sh — Agent onboarding orchestrator (Layer 2)
#
# The most important script in scrum-agent: makes agents deeply understand
# a new project. Runs as the team's first sprint, where each agent researches
# the project and generates their own domain-aware persona file.
#
# Phases (sequential — each depends on previous outputs):
#   1. Layla  (Product Strategist)  — Brand & market research       [Opus]
#   2. Salma  (PM)                  — Project brief & roadmap       [Opus]
#   3. Rami   (Architect)           — Architecture & schema design  [Opus]
#   4. Youssef (Dev)                — Dev rules & code patterns     [Sonnet]
#   5. Nadia  (QA)                  — QA strategy & test plans      [Sonnet]
#   6. Omar   (Ops)                 — Monitoring & deploy rules     [Haiku]
#
# Usage:
#   sprint-zero.sh [PROJECT_DIR]     # default: current directory
#   sprint-zero.sh --help            # show usage
#
# Prerequisites:
#   - claude CLI installed (claude --print)
#   - .agent-config.json in project root (from init-project.sh)
#   - docs/project-context.md populated with domain knowledge
#
# Expected runtime: 10-20 minutes (Opus calls are slow)
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
NC='\033[0m'

# ─── Help ────────────────────────────────────────────────────────────────────
show_help() {
  cat <<'HELP'
sprint-zero.sh — Agent onboarding orchestrator for scrum-agent

USAGE:
  sprint-zero.sh [PROJECT_DIR]     Run Sprint 0 (default: current directory)
  sprint-zero.sh --help            Show this help

PREREQUISITES:
  - claude CLI installed and authenticated
  - .agent-config.json in project root (from init-project.sh)
  - docs/project-context.md populated with rich domain knowledge

WHAT IT DOES:
  Runs 6 agents sequentially, each generating a domain-aware persona file:
    Phase 1: Layla  — ai/product.md      (brand, audience, competitors)
    Phase 2: Salma  — ai/pm.md           (brief, glossary, roadmap)
    Phase 3: Rami   — ai/architect.md    (architecture, schema, patterns)
    Phase 4: Youssef — ai/dev.md         (dev rules, conventions)
    Phase 5: Nadia  — ai/qa.md           (QA strategy, test plans)
    Phase 6: Omar   — ai/ops.md          (monitoring, deploy procedures)

  Also generates: docs/project-brief.md, docs/architecture.md

OUTPUT:
  - Creates git branch sprint-0/onboarding
  - Commits each phase as it completes
  - Prints summary and next steps

NOTES:
  - If a phase fails, the script logs the error and continues
  - Total expected runtime: 10-20 minutes
HELP
  exit 0
}

[[ "${1:-}" == "--help" || "${1:-}" == "-h" ]] && show_help

# ─── Logging ─────────────────────────────────────────────────────────────────
log_info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*"; }
log_phase()   { echo -e "\n${BOLD}${CYAN}==> $*${NC}"; }

# ─── Configuration ───────────────────────────────────────────────────────────
PROJECT_DIR="${1:-.}"
PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd)"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRUM_AGENT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Detect scrum-agent location: standalone repo or submodule
if [[ -d "${PROJECT_DIR}/scrum-agent/agents" ]]; then
  SCRUM_AGENT_DIR="${PROJECT_DIR}/scrum-agent"
elif [[ -d "${SCRUM_AGENT_DIR}/agents" ]]; then
  : # already correct from script location
else
  log_error "Cannot find scrum-agent agents/ directory."
  log_error "Expected at: ${SCRUM_AGENT_DIR}/agents/ or ${PROJECT_DIR}/scrum-agent/agents/"
  exit 1
fi

AGENTS_DIR="${SCRUM_AGENT_DIR}/agents"
CONFIG_FILE="${PROJECT_DIR}/.agent-config.json"
CONTEXT_FILE="${PROJECT_DIR}/docs/project-context.md"
AI_DIR="${PROJECT_DIR}/ai"
DOCS_DIR="${PROJECT_DIR}/docs"

# ─── Pre-flight checks ──────────────────────────────────────────────────────
log_phase "Pre-flight checks"

# Check claude CLI
if ! command -v claude &>/dev/null; then
  log_error "claude CLI not found. Install it first:"
  log_error "  npm install -g @anthropic-ai/claude-code"
  exit 1
fi

# Check config file
if [[ ! -f "$CONFIG_FILE" ]]; then
  log_error "Missing ${CONFIG_FILE}"
  log_error "Run init-project.sh first to generate project configuration."
  exit 1
fi

# Check context file
if [[ ! -f "$CONTEXT_FILE" ]]; then
  log_error "Missing ${CONTEXT_FILE}"
  log_error "Populate docs/project-context.md with domain knowledge before running Sprint 0."
  exit 1
fi

# Check agent templates
for template in product-marketing.md pm.md architect.md dev.md qa.md ops.md; do
  if [[ ! -f "${AGENTS_DIR}/${template}" ]]; then
    log_error "Missing agent template: ${AGENTS_DIR}/${template}"
    exit 1
  fi
done

# Parse project info from config
PROJECT_NAME=$(python3 -c "import json; print(json.load(open('${CONFIG_FILE}')).get('name', 'Unknown'))" 2>/dev/null || echo "Unknown")
PROJECT_KEY=$(python3 -c "import json; print(json.load(open('${CONFIG_FILE}')).get('project_key', 'UNK'))" 2>/dev/null || echo "UNK")
BASE_BRANCH=$(python3 -c "import json; print(json.load(open('${CONFIG_FILE}')).get('base_branch', 'main'))" 2>/dev/null || echo "main")

log_success "Project: ${PROJECT_NAME} (${PROJECT_KEY})"
log_success "Scrum-agent: ${SCRUM_AGENT_DIR}"
log_success "Claude CLI: $(command -v claude)"

# ─── Prepare directories ────────────────────────────────────────────────────
mkdir -p "$AI_DIR" "$DOCS_DIR"

# ─── Git branch ──────────────────────────────────────────────────────────────
log_phase "Creating sprint-0 branch"

cd "$PROJECT_DIR"

# Stash any uncommitted changes
if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
  log_info "Stashing uncommitted changes..."
  git stash push -m "sprint-zero: stash before onboarding" -q 2>/dev/null || true
  STASHED=true
else
  STASHED=false
fi

# Create branch from base
git checkout "${BASE_BRANCH}" -q 2>/dev/null || true
git checkout -b "sprint-0/onboarding" 2>/dev/null || {
  log_warn "Branch sprint-0/onboarding already exists — switching to it"
  git checkout "sprint-0/onboarding" -q
}

log_success "On branch: sprint-0/onboarding"

# ─── Helper: read file safely ───────────────────────────────────────────────
read_file() {
  local path="$1"
  if [[ -f "$path" ]]; then
    cat "$path"
  else
    echo "[File not found: ${path}]"
  fi
}

# ─── Helper: collect codebase summary ───────────────────────────────────────
collect_codebase_summary() {
  local summary=""

  # Directory tree (top 3 levels, excluding node_modules/.git)
  summary+="### Directory Structure"$'\n'
  summary+=$(find "$PROJECT_DIR" -maxdepth 3 \
    -not -path '*/node_modules/*' \
    -not -path '*/.git/*' \
    -not -path '*/dist/*' \
    -not -path '*/.next/*' \
    -not -path '*/build/*' \
    -type f -name '*.ts' -o -name '*.tsx' -o -name '*.js' -o -name '*.jsx' \
    -o -name '*.py' -o -name '*.rs' -o -name '*.go' \
    -o -name '*.json' -o -name '*.yaml' -o -name '*.yml' \
    2>/dev/null | head -80 || echo "(no source files found)")
  summary+=$'\n\n'

  # Package.json / Cargo.toml / pyproject.toml (for tech stack info)
  for manifest in package.json Cargo.toml pyproject.toml go.mod; do
    if [[ -f "${PROJECT_DIR}/${manifest}" ]]; then
      summary+="### ${manifest}"$'\n'
      summary+=$(head -50 "${PROJECT_DIR}/${manifest}")
      summary+=$'\n\n'
    fi
  done

  # Key source files: first 100 lines of a few important files
  local src_count=0
  while IFS= read -r src_file; do
    [[ $src_count -ge 5 ]] && break
    summary+="### ${src_file#${PROJECT_DIR}/}"$'\n'
    summary+=$(head -100 "$src_file" 2>/dev/null || true)
    summary+=$'\n\n'
    ((src_count++))
  done < <(find "$PROJECT_DIR" -maxdepth 4 \
    -not -path '*/node_modules/*' \
    -not -path '*/.git/*' \
    -not -path '*/dist/*' \
    -type f \( -name 'index.ts' -o -name 'index.tsx' -o -name 'App.tsx' \
    -o -name 'main.ts' -o -name 'main.py' -o -name 'main.rs' \
    -o -name 'app.ts' -o -name 'server.ts' -o -name 'lib.rs' \) \
    2>/dev/null | head -5)

  echo "$summary"
}

# ─── Helper: run agent phase ────────────────────────────────────────────────
PHASE_COUNT=0
PHASE_ERRORS=0
START_TIME=$(date +%s)

run_phase() {
  local phase_num="$1"
  local agent_name="$2"
  local agent_role="$3"
  local model="$4"
  local template_file="$5"
  local output_file="$6"
  local prompt="$7"
  local extra_output="${8:-}"  # optional second output file

  PHASE_COUNT=$((PHASE_COUNT + 1))
  local phase_start=$(date +%s)

  log_phase "[Phase ${phase_num}/6] ${agent_name} -- ${agent_role}"
  log_info "Model: ${model}"
  log_info "Template: ${template_file}"
  log_info "Output: ${output_file}"

  # Read the generic persona template
  local persona
  persona=$(read_file "${AGENTS_DIR}/${template_file}")

  # Build the full prompt with persona context
  local full_prompt
  full_prompt=$(cat <<PROMPT_EOF
${persona}

---

# Sprint 0 Mission: Generate Project-Specific Persona

You are ${agent_name}, and you are joining a new project: **${PROJECT_NAME}** (${PROJECT_KEY}).

Your mission is to deeply analyze the provided context and generate your project-specific persona file. This file will be your reference for ALL future work on this project.

${prompt}

## Output Format

Write your output as a single Markdown file following this EXACT structure:

\`\`\`
# ${agent_name} -- ${agent_role} (${PROJECT_NAME})

## Personnalite & Caractere
[Copy your personality section EXACTLY from your generic template above — personality is constant across projects]

## Role
[Your generic role description + any project-specific additions based on what you learned]

## Contexte Projet
[THIS IS THE KEY SECTION — demonstrate deep understanding of the project]
[Domain knowledge, terminology, business rules, user flows, constraints]
[Be specific: names, numbers, patterns, not generic platitudes]

## Regles Specifiques
[Project-specific rules, patterns, constraints you identified]
[Code conventions, naming patterns, architecture decisions]

## Fichiers Cles
[Important file paths you identified in the project]
[Organized by category: source, config, docs, tests]
\`\`\`

Write ONLY the Markdown content. No code fences around the whole output. No preamble.
PROMPT_EOF
)

  # Call claude
  local result=""
  local exit_code=0

  log_info "Calling claude (${model})... this may take a few minutes."

  result=$(cd "$PROJECT_DIR" && claude --model "$model" --print "$full_prompt" 2>/dev/null) || exit_code=$?

  local phase_duration=$(( $(date +%s) - phase_start ))

  if [[ $exit_code -ne 0 ]] || [[ -z "$result" ]]; then
    log_error "${agent_name} FAILED (exit ${exit_code}, duration ${phase_duration}s)"
    PHASE_ERRORS=$((PHASE_ERRORS + 1))
    return 1
  fi

  # Save output
  echo "$result" > "${PROJECT_DIR}/${output_file}"
  log_success "Generated ${output_file} (${phase_duration}s)"

  # Handle optional extra output (extracted from main output)
  if [[ -n "$extra_output" ]]; then
    log_info "Extra output expected at: ${extra_output} (included in main output)"
  fi

  # Git commit this phase
  cd "$PROJECT_DIR"
  git add "${output_file}" 2>/dev/null || true
  [[ -n "$extra_output" ]] && git add "${extra_output}" 2>/dev/null || true
  git commit -m "sprint-0: phase ${phase_num} — ${agent_name} (${agent_role})" -q 2>/dev/null || {
    log_warn "Nothing to commit for phase ${phase_num} (no changes)"
  }

  log_success "Phase ${phase_num} complete: ${agent_name} (${phase_duration}s)"
  return 0
}

# =============================================================================
# PHASE 1: Layla — Product Strategist
# =============================================================================
CONTEXT_CONTENT=$(read_file "$CONTEXT_FILE")

run_phase 1 "Layla" "Product Strategist" "claude-opus-4-6" "product-marketing.md" "ai/product.md" \
"## Your Input

### Project Context (docs/project-context.md)
${CONTEXT_CONTENT}

### Project Config
$(read_file "$CONFIG_FILE")

## Your Task

Analyze this project deeply from a product strategy perspective:

1. **Brand Identity**: What is this product's personality? Its visual language? Its tone?
2. **Target Audience**: Who are the primary and secondary users? What are their habits, pain points, expectations?
3. **Competitive Landscape**: What are the direct/indirect competitors? What differentiates this product?
4. **Market Positioning**: Where does this product sit in the market? What is its unique value proposition?
5. **UX Principles**: Based on the audience and brand, what UX principles should guide every feature?
6. **User Journeys**: What are the critical user flows? First-time experience? Daily usage patterns?
7. **Growth Levers**: What features/experiences will drive adoption and retention?

Be SPECIFIC to this project. Use real names, real numbers, real competitor names. No generic advice."

# =============================================================================
# PHASE 2: Salma — Product Manager
# =============================================================================
PRODUCT_CONTENT=$(read_file "${PROJECT_DIR}/ai/product.md")

run_phase 2 "Salma" "Product Manager" "claude-opus-4-6" "pm.md" "ai/pm.md" \
"## Your Input

### Layla's Product Analysis (ai/product.md)
${PRODUCT_CONTENT}

### Project Context (docs/project-context.md)
${CONTEXT_CONTENT}

### Project Config
$(read_file "$CONFIG_FILE")

## Your Task

Based on Layla's product analysis and the project context, write your project-specific persona that includes:

1. **Project Brief**: Comprehensive summary — what, why, who, how
2. **Domain Glossary**: Key terms specific to this project's domain (minimum 15 terms)
3. **Feature Roadmap**: Prioritized phases (MVP, V1, V2) with concrete features
4. **Spec Template**: How specs should be written for this specific project (with domain-specific fields)
5. **Sprint Planning Rules**: How to size tickets, what constitutes a 1-day task for this project
6. **Cross-Agent Coordination**: What Youssef needs to know, what Nadia should test, what Rami should review
7. **Risk Register**: Known risks, dependencies, unknowns

Also generate a separate section titled '--- PROJECT BRIEF (docs/project-brief.md) ---' that contains a standalone project brief document. This will be extracted and saved separately.

Be SPECIFIC. Reference real features, real user flows, real technical constraints from the context." \
"docs/project-brief.md"

# Extract project-brief.md from Salma's output if it contains the separator
if [[ -f "${PROJECT_DIR}/ai/pm.md" ]]; then
  if grep -q "PROJECT BRIEF" "${PROJECT_DIR}/ai/pm.md" 2>/dev/null; then
    # Extract everything after the PROJECT BRIEF separator
    sed -n '/--- PROJECT BRIEF/,$ { /--- PROJECT BRIEF/d; p; }' "${PROJECT_DIR}/ai/pm.md" > "${PROJECT_DIR}/docs/project-brief.md" 2>/dev/null || true
    if [[ -s "${PROJECT_DIR}/docs/project-brief.md" ]]; then
      cd "$PROJECT_DIR"
      git add "docs/project-brief.md" 2>/dev/null || true
      git commit -m "sprint-0: extract project brief from Salma's output" -q 2>/dev/null || true
      log_success "Extracted docs/project-brief.md"
    fi
  else
    log_warn "Could not extract project-brief.md (no separator found in Salma's output)"
  fi
fi

# =============================================================================
# PHASE 3: Rami — Architect
# =============================================================================
PM_CONTENT=$(read_file "${PROJECT_DIR}/ai/pm.md")
BRIEF_CONTENT=$(read_file "${PROJECT_DIR}/docs/project-brief.md")
CODEBASE_SUMMARY=$(collect_codebase_summary)

run_phase 3 "Rami" "Technical Architect" "claude-opus-4-6" "architect.md" "ai/architect.md" \
"## Your Input

### Project Brief (docs/project-brief.md)
${BRIEF_CONTENT}

### Layla's Product Analysis (ai/product.md)
${PRODUCT_CONTENT}

### Project Config (.agent-config.json)
$(read_file "$CONFIG_FILE")

### Codebase Overview
${CODEBASE_SUMMARY}

## Your Task

Review the existing codebase and project context to design the technical architecture:

1. **Current State Assessment**: What exists today? What patterns are already in use? What tech debt is visible?
2. **Target Architecture**: Directory structure, module boundaries, data flow, state management
3. **Database Schema**: If applicable, design the data model with tables/collections, relationships, indexes
4. **API Design**: Key endpoints/interfaces, request/response shapes, error handling patterns
5. **Migration Plan**: How to get from current state to target state incrementally
6. **Technical Decisions**: Framework choices, library selections, with RATIONALE for each
7. **Performance Considerations**: Caching strategy, lazy loading, bundle optimization
8. **Security Patterns**: Auth flow, data validation, input sanitization

Also generate a separate section titled '--- ARCHITECTURE DOC (docs/architecture.md) ---' that contains a standalone architecture document.

Be SPECIFIC. Reference actual files you see in the codebase. Propose concrete file paths for new modules." \
"docs/architecture.md"

# Extract architecture.md from Rami's output
if [[ -f "${PROJECT_DIR}/ai/architect.md" ]]; then
  if grep -q "ARCHITECTURE DOC" "${PROJECT_DIR}/ai/architect.md" 2>/dev/null; then
    sed -n '/--- ARCHITECTURE DOC/,$ { /--- ARCHITECTURE DOC/d; p; }' "${PROJECT_DIR}/ai/architect.md" > "${PROJECT_DIR}/docs/architecture.md" 2>/dev/null || true
    if [[ -s "${PROJECT_DIR}/docs/architecture.md" ]]; then
      cd "$PROJECT_DIR"
      git add "docs/architecture.md" 2>/dev/null || true
      git commit -m "sprint-0: extract architecture doc from Rami's output" -q 2>/dev/null || true
      log_success "Extracted docs/architecture.md"
    fi
  else
    log_warn "Could not extract architecture.md (no separator found in Rami's output)"
  fi
fi

# =============================================================================
# PHASE 4: Youssef — Developer
# =============================================================================
ARCH_CONTENT=$(read_file "${PROJECT_DIR}/ai/architect.md")
ARCH_DOC_CONTENT=$(read_file "${PROJECT_DIR}/docs/architecture.md")

run_phase 4 "Youssef" "Developer" "claude-sonnet-4-20250514" "dev.md" "ai/dev.md" \
"## Your Input

### Layla's Product Analysis (ai/product.md)
${PRODUCT_CONTENT}

### Project Brief (docs/project-brief.md)
${BRIEF_CONTENT}

### Architecture (docs/architecture.md)
${ARCH_DOC_CONTENT}

### Rami's Architecture Notes (ai/architect.md)
${ARCH_CONTENT}

### Project Config
$(read_file "$CONFIG_FILE")

## Your Task

Based on all the context above, write your project-specific developer persona:

1. **Code Patterns**: Specific patterns to use in THIS project (naming conventions, file structure, component patterns)
2. **Domain Types**: Key TypeScript/Python types that model the business domain
3. **State Management**: How state flows in this specific app
4. **Error Handling**: Project-specific error patterns and user-facing messages
5. **Testing Strategy**: What to test, how to test, minimum coverage expectations
6. **PR Conventions**: Commit message format, branch naming, PR description template
7. **Common Pitfalls**: Things that will trip you up in this specific codebase
8. **Key Abstractions**: Reusable utilities, hooks, helpers that exist or should exist

Be PRACTICAL. Write rules you will actually follow in every PR, not aspirational ideals."

# =============================================================================
# PHASE 5: Nadia — QA Engineer
# =============================================================================
DEV_CONTENT=$(read_file "${PROJECT_DIR}/ai/dev.md")

run_phase 5 "Nadia" "QA Engineer" "claude-sonnet-4-20250514" "qa.md" "ai/qa.md" \
"## Your Input

### Layla's Product Analysis (ai/product.md)
${PRODUCT_CONTENT}

### Project Brief (docs/project-brief.md)
${BRIEF_CONTENT}

### Architecture (docs/architecture.md)
${ARCH_DOC_CONTENT}

### Youssef's Dev Rules (ai/dev.md)
${DEV_CONTENT}

### Salma's PM Notes (ai/pm.md)
${PM_CONTENT}

### Project Config
$(read_file "$CONFIG_FILE")

## Your Task

Write your project-specific QA persona that includes:

1. **QA Strategy**: How you will review PRs for THIS project (what to check first, what matters most)
2. **Test Plans**: Template test scenarios for the key user flows identified by Layla and Salma
3. **Edge Cases**: Domain-specific edge cases (based on the business rules and user types)
4. **Regression Risks**: What areas are most likely to break when changes are made
5. **Performance Benchmarks**: Acceptable load times, bundle sizes, API response times
6. **Accessibility Checklist**: Project-specific a11y requirements
7. **Cross-Agent Validation**: Verify consistency between Layla's product vision, Salma's specs, Rami's architecture, and Youssef's implementation patterns
8. **Review Rubric**: Concrete PASS/FAIL criteria for PRs in this project

Be STRICT but FAIR. Your review criteria should be concrete and measurable, not subjective."

# =============================================================================
# PHASE 6: Omar — Operations
# =============================================================================
run_phase 6 "Omar" "Operations" "claude-haiku-3-5-20241022" "ops.md" "ai/ops.md" \
"## Your Input

### Project Config (.agent-config.json)
$(read_file "$CONFIG_FILE")

### Architecture (docs/architecture.md)
$(read_file "${PROJECT_DIR}/docs/architecture.md")

### Project Brief (docs/project-brief.md)
${BRIEF_CONTENT}

## Your Task

Write your project-specific ops persona:

1. **Deployment Procedure**: Step-by-step deploy process for THIS project
2. **Health Checks**: What to monitor, expected response times, error thresholds
3. **Rollback Plan**: How to rollback a bad deploy
4. **Environment Config**: Required env vars, secrets, feature flags
5. **CI/CD Pipeline**: Build steps, test gates, deploy triggers
6. **Incident Response**: What to do when things break (runbook)
7. **Agent Pipeline Rules**: How to manage the agent pipeline for this project (scheduling, budgets, escalation)
8. **Monitoring Alerts**: What metrics to track, threshold values, notification channels

Be CONCISE. Ops docs should be scannable in an emergency."

# =============================================================================
# Summary
# =============================================================================
TOTAL_DURATION=$(( $(date +%s) - START_TIME ))
PHASES_OK=$(( PHASE_COUNT - PHASE_ERRORS ))

echo
log_phase "Sprint 0 Complete"
echo
echo -e "${BOLD}Project:${NC} ${PROJECT_NAME} (${PROJECT_KEY})"
echo -e "${BOLD}Branch:${NC}  sprint-0/onboarding"
echo -e "${BOLD}Duration:${NC} ${TOTAL_DURATION}s (~$(( TOTAL_DURATION / 60 )) minutes)"
echo -e "${BOLD}Phases:${NC}  ${PHASES_OK}/${PHASE_COUNT} succeeded"
[[ $PHASE_ERRORS -gt 0 ]] && echo -e "${RED}Errors:${NC}  ${PHASE_ERRORS} phase(s) failed"
echo

echo -e "${BOLD}Generated Files:${NC}"
for f in ai/product.md ai/pm.md ai/architect.md ai/dev.md ai/qa.md ai/ops.md docs/project-brief.md docs/architecture.md; do
  if [[ -f "${PROJECT_DIR}/${f}" ]]; then
    local_size=$(wc -c < "${PROJECT_DIR}/${f}" 2>/dev/null || echo 0)
    echo -e "  ${GREEN}+${NC} ${f} (${local_size} bytes)"
  else
    echo -e "  ${RED}-${NC} ${f} (not generated)"
  fi
done
echo

echo -e "${BOLD}Git Log:${NC}"
cd "$PROJECT_DIR"
git log --oneline "sprint-0/onboarding" --not "${BASE_BRANCH}" 2>/dev/null | head -10 || true
echo

echo -e "${BOLD}${GREEN}Next Steps:${NC}"
echo "  1. Review the generated files:"
echo "     cd ${PROJECT_DIR} && ls -la ai/ docs/"
echo "  2. Edit any persona that needs refinement"
echo "  3. Merge the sprint-0 branch:"
echo "     git checkout ${BASE_BRANCH} && git merge sprint-0/onboarding"
echo "  4. The agents are now ready to work on this project"
echo

# Restore stash if we stashed earlier
if [[ "${STASHED:-false}" == "true" ]]; then
  log_info "Restoring stashed changes..."
  git stash pop -q 2>/dev/null || log_warn "Could not restore stash (may need manual resolution)"
fi

log_success "Sprint 0 onboarding complete."
