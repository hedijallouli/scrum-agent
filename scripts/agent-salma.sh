#!/usr/bin/env bash
# =============================================================================
# agent-salma.sh — PM Agent: Enriches tickets with specs & acceptance criteria
# =============================================================================
AGENT_NAME="salma"
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/agent-common.sh"

TICKET_KEY="${1:?Usage: agent-salma.sh ${PROJECT_KEY:-TICKET}-XX}"
MAX_RETRIES=3  # Allow retries for complex specs before blocking

init_log "$TICKET_KEY" "salma"
log_info "=== Salma (PM) starting spec enrichment for ${TICKET_KEY} ==="
JIRA_URL="$(jira_link "$TICKET_KEY")"

# ─── 1. Check retry count + cooldown ────────────────────────────────────────
retry_count=$(get_retry_count "$TICKET_KEY" "salma")
if (( retry_count >= MAX_RETRIES )); then
  log_error "Max retries ($MAX_RETRIES) reached for ${TICKET_KEY}. Handing off to Omar."
  jira_add_rich_comment "$TICKET_KEY" "salma" "BLOCKED" "## Spec Enrichment Failed — Handoff to Omar
Impossible d'enrichir le ticket après ${MAX_RETRIES} tentatives. Je me déassigne et transmets à Omar pour triage."
  # Unassign Salma → assign Omar + mark blocked (needs-human since specs failed)
  plane_set_assignee "$TICKET_KEY" "omar" 2>/dev/null || true
  jira_add_label "$TICKET_KEY" "blocked"
  jira_add_label "$TICKET_KEY" "needs-human"
  slack_notify "salma" "$(mm_ticket_link "${TICKET_KEY}") — specs échouées ${MAX_RETRIES} fois. Transféré à @omar-ai pour triage humain. 🔴" "pipeline" "danger" 2>/dev/null || true
  log_activity "salma" "$TICKET_KEY" "HANDOFF_OMAR" "Hit ${MAX_RETRIES} retries, unassigned → Omar"
  exit 1
fi

if ! check_cooldown "$TICKET_KEY" "salma"; then
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

DESCRIPTION=$(jira_get_description_text "$TICKET_KEY")
COMMENTS=$(jira_get_comments "$TICKET_KEY")
PRIORITY=$(jira_get_ticket_field "$TICKET_KEY" "priority")
LABELS=$(jira_get_ticket_field "$TICKET_KEY" "labels")

# ─── 2b. Select model based on labels/priority ──────────────────────────────
MODEL=$(select_model_with_feedback "$LABELS" "$PRIORITY" "$TICKET_KEY" "salma")
MODEL=$(select_model_rate_aware "$MODEL" "salma" "simple-spec")
MODEL=$(activate_api_key_if_needed "$MODEL")
if [[ "$MODEL" == "WAIT" ]]; then
  log_info "Sonnet rate-limited — salma must wait (spec work, no API key)"
  exit 0
fi

# --- 2c. Ideation Concept Picker ---------------------------------------------
# If Layla posted 10 concepts (ideation-ready label), pick the best one
if printf "%s\n" "$LABELS" | grep -q "ideation-ready"; then
  log_info "Ideation-ready ticket detected -- entering concept-picker mode"

  # Use Sonnet for concept selection (important decision, good reasoning)
  PICKER_MODEL="claude-sonnet-4-20250514"

  # Fetch latest comments to get Layla's concepts
  LATEST_COMMENTS=$(jira_get_comments "$TICKET_KEY" 2>/dev/null || echo "")

  PICKER_PROMPT="You are Salma, the Product Manager for ${PROJECT_NAME} (${PROJECT_KEY}).
Read your persona file (ai/pm.md) for full project context.

TICKET: $TICKET_KEY
SUMMARY: $SUMMARY
DESCRIPTION:
$DESCRIPTION

LAYLA'S PROPOSED CONCEPTS:
$LATEST_COMMENTS

TASK: Layla (Product Strategist) has proposed 10 concepts above. Your job is to:

1. EVALUATE each concept against these criteria:
   - Alignment with the project's core identity and goals
   - Player engagement and fun factor
   - Implementation feasibility (we have a React/TypeScript codebase)
   - Uniqueness vs existing game modes
   - RICE score validity

2. PICK THE BEST CONCEPT and explain why (2-3 sentences)

3. WRITE A FULL IMPLEMENTATION SPEC for the chosen concept:

## Summary
[One paragraph describing the chosen concept and why it was selected]

## Acceptance Criteria
- [ ] [Specific, testable criterion 1]
- [ ] [Specific, testable criterion 2]
- [ ] ... (aim for 8-15 criteria)

## Definition of Ready
- [ ] All acceptance criteria are clear and testable
- [ ] Technical approach identified
- [ ] Dependencies identified
- [ ] Estimated complexity: [S/M/L/XL]

## Technical Notes
[Implementation guidance, key files to modify, architectural considerations]

## Test Cases
- [ ] [Test case 1]
- [ ] [Test case 2]
- [ ] ... (aim for 5-10 test cases)

## Chosen Concept
**Name:** [concept name]
**RICE Score:** R=X I=X C=X E=X
**Reason for selection:** [why this concept won]

## Rejected Concepts (Brief)
[One-line reason for rejecting each of the other 9]

VERDICT: CONCEPT_SELECTED"

  log_info "Invoking Claude for concept selection ($PICKER_MODEL)..."
  CLAUDE_OUTPUT=$(echo "$PICKER_PROMPT" | claude --model "$PICKER_MODEL" --max-turns 10 --allowedTools "Read Glob Grep WebSearch WebFetch" -p 2>&1) || {
    log_info "ERROR: Claude invocation failed for concept selection"
    increment_retry "$TICKET_KEY" "salma"
    exit 1
  }

  log_info "Concept selection output: ${#CLAUDE_OUTPUT} chars"

  # Update ticket description with the spec
  jira_set_spec "$TICKET_KEY" "salma" "$CLAUDE_OUTPUT"
  log_info "Updated ticket description with selected concept spec"

  # Post comment with selection rationale
  jira_add_rich_comment "$TICKET_KEY" "salma" "PASS" "## Concept Selected
$CLAUDE_OUTPUT"

  # Remove ideation-ready, add enriched, route to Layla for feasibility
  jira_remove_label "$TICKET_KEY" "ideation-ready"
  jira_add_label "$TICKET_KEY" "enriched"
  jira_update_labels "$TICKET_KEY" "agent:salma" "agent:layla"
  reset_retry "$TICKET_KEY" "salma"
  log_info "Routed to Layla for feasibility review (enriched)"

  # Slack notification
  SPEC_SHORT=$(echo "$SUMMARY" | head -c 80)
  slack_notify "$(mm_ticket_link "${TICKET_KEY}") — j'ai sélectionné le meilleur concept parmi les propositions. Layla, je te transmets pour la validation produit. On avance bien !" "pipeline" "good"

  log_activity "salma" "$TICKET_KEY" "CONCEPT_SELECTED" "Picked concept for: ${SPEC_SHORT}"
  log_success "=== Salma concept-picker complete for ${TICKET_KEY} ==="
  exit 0
fi

# ─── Step 2d: Architecture Spec Writer ───────────────────────────────────────
# If Rami posted an architecture recommendation (architecture-ready label), write the impl spec
if printf '%s\n' "$LABELS" | grep -q "architecture-ready"; then
  log_info "Architecture-ready ticket detected — entering architecture spec writer mode"
  
  # Use good model for spec writing
  SPEC_MODEL="claude-sonnet-4-20250514"
  
  # Fetch latest comments to get Rami's architecture recommendation
  LATEST_COMMENTS=$(jira_get_comments "$TICKET_KEY" 2>/dev/null || echo "")
  
  SPEC_PROMPT="You are Salma, the Product Manager for ${PROJECT_NAME} (${PROJECT_KEY}).
Read your persona file (ai/pm.md) for full project context.

TICKET: $TICKET_KEY
SUMMARY: $SUMMARY
DESCRIPTION:
$DESCRIPTION

RAMI'S ARCHITECTURE RECOMMENDATION:
$LATEST_COMMENTS

TASK: Rami (Technical Architect) has evaluated the architectural options and made a recommendation above. Your job is to write a full implementation spec based on his chosen approach.

Write a complete implementation spec following this structure:

## Summary
[One paragraph describing what will be implemented and which architecture was chosen by Rami]

## Architecture Decision
[Reference Rami's recommendation — which option was chosen and why]

## Acceptance Criteria
- [ ] [Specific, testable criterion 1]
- [ ] [Specific, testable criterion 2]
- [ ] ... (aim for 10-15 criteria covering the full implementation)

## Definition of Ready
- [ ] All acceptance criteria are clear and testable
- [ ] Technical approach identified (per Rami's recommendation)
- [ ] Dependencies identified
- [ ] Estimated complexity: [S/M/L/XL]

## Technical Notes
[Detailed implementation guidance based on Rami's architecture:
- Key files to create/modify
- Dependencies to install
- Configuration needed
- Integration points with existing code]

## Test Cases
- [ ] [Test case 1]
- [ ] [Test case 2]
- [ ] ... (aim for 8-12 test cases)

## Implementation Steps
1. [Step 1 — with specific files/functions]
2. [Step 2]
...

VERDICT: SPEC_WRITTEN"

  log_info "Invoking Claude for architecture spec writing ($SPEC_MODEL)..."
  CLAUDE_OUTPUT=$(echo "$SPEC_PROMPT" | claude --model "$SPEC_MODEL" --max-turns 10 --allowedTools "Read Glob Grep WebSearch WebFetch" -p 2>&1) || {
    log_info "ERROR: Claude invocation failed for architecture spec"
    increment_retry "$TICKET_KEY" "salma"
    exit 1
  }
  
  log_info "Architecture spec output: ${#CLAUDE_OUTPUT} chars"
  
  # Update ticket description with the spec
  jira_set_spec "$TICKET_KEY" "$CLAUDE_OUTPUT"
  log_info "Updated ticket description with architecture-based spec"
  
  # Post comment with spec summary
  jira_add_rich_comment "$TICKET_KEY" "Salma" "Product Manager" "success" "SPEC_WRITTEN" ":memo:" "1f4dd" <<< "$CLAUDE_OUTPUT"
  
  # Remove architecture-ready, add enriched, route to Layla for feasibility
  jira_remove_label "$TICKET_KEY" "architecture-ready"
  jira_add_label "$TICKET_KEY" "enriched"
  jira_update_labels "$TICKET_KEY" "agent:salma" "agent:layla"
  log_info "Routed to Layla for feasibility review (enriched)"
  
  # Slack notification
  slack_notify ":memo: *Salma — Architecture Spec Written*\nTicket: $(mm_ticket_link "${TICKET_KEY}")\nWrote implementation spec based on Rami's architecture recommendation, routing to Layla for feasibility review"
  
  log_info "Architecture spec writer mode complete for $TICKET_KEY"
  exit 0
fi

# ─── 3. Handle needs-split escalation (from Nadia/Youssef/Rami) ─────────────
# Check needs-split BEFORE enriched — a ticket can be both enriched AND needs-split
# when it failed QA/Dev after implementation. needs-split takes priority.
if printf "%s\n" "$LABELS" | grep -qE "needs-split|needs-refinement-split"; then
  # Guard: if already split (split-parent label present), just clean up labels and exit
  if printf "%s\n" "$LABELS" | grep -q "split-parent"; then
    log_info "Ticket already has split-parent label — split was already done. Cleaning up needs-split label."
    jira_remove_label "$TICKET_KEY" "needs-split"
    jira_remove_label "$TICKET_KEY" "needs-refinement-split"
    log_success "=== Salma skipped duplicate split for ${TICKET_KEY} (already done) ==="
    exit 0
  fi
  MODEL="opus"
  log_info "Ticket has needs-split label — entering split/rewrite mode (using Opus)"

  FAILURE_HISTORY=$(jira_get_comments "$TICKET_KEY" | { grep -A5 "Nadia\|Youssef\|FAIL\|BLOCKED\|ESCALAT" || true; } | tail -60 || true)
  FEEDBACK_ISSUES=$(cat "${FEEDBACK_DIR}/${TICKET_KEY}.txt" 2>/dev/null || echo "No feedback file")

  SPLIT_PROMPT="You are Salma, the PM agent for ${PROJECT_NAME} (${PROJECT_KEY}).
Read the file ai/pm.md for your PM rules.

TICKET: ${TICKET_KEY}
TITLE: ${SUMMARY}
PRIORITY: ${PRIORITY}

ORIGINAL SPEC:
${DESCRIPTION:-No description}

QA/DEV FAILURE HISTORY:
${FAILURE_HISTORY}

STRUCTURED FEEDBACK:
${FEEDBACK_ISSUES}

This ticket was escalated because it failed QA/Dev multiple times. You must decide ONE action:

OPTION A — SPLIT: The ticket is too large or has too many concerns. Create 2-3 smaller tickets.
For each sub-ticket, provide:
  SPLIT_TICKET_1_TITLE: <title>
  SPLIT_TICKET_1_SPEC: <full spec with acceptance criteria>
  SPLIT_TICKET_2_TITLE: <title>
  SPLIT_TICKET_2_SPEC: <full spec>
  (optionally SPLIT_TICKET_3_TITLE / SPLIT_TICKET_3_SPEC)

OPTION B — REWRITE: The spec is unclear or wrong. Rewrite it with better criteria.
  REWRITE_SPEC: <full rewritten spec starting with ## Summary>

OPTION C — FLAG: You cannot solve this — the requirements are contradictory or need human input.
  FLAG_REASON: <explanation of why a human needs to intervene>

Output your decision as the FIRST line:
DECISION: SPLIT
or
DECISION: REWRITE
or
DECISION: FLAG

Then provide the corresponding data below."

  SPLIT_OUTPUT=$(cd "$PROJECT_DIR" && claude -p "$SPLIT_PROMPT" \
    --allowedTools "Read Glob Grep" \
    --model $MODEL --max-turns 20 2>/dev/null) || true

  echo "$SPLIT_OUTPUT" >> "$LOG_FILE"

  SPLIT_DECISION="UNKNOWN"
  if echo "$SPLIT_OUTPUT" | grep -q "DECISION: SPLIT"; then
    SPLIT_DECISION="SPLIT"
  elif echo "$SPLIT_OUTPUT" | grep -q "DECISION: REWRITE"; then
    SPLIT_DECISION="REWRITE"
  elif echo "$SPLIT_OUTPUT" | grep -q "DECISION: FLAG"; then
    SPLIT_DECISION="FLAG"
  fi

  log_info "Split decision: ${SPLIT_DECISION}"

  if [[ "$SPLIT_DECISION" == "SPLIT" ]]; then
    # ─── Create new tickets from split ──────────────────────────────────────
    log_info "Splitting ticket into smaller tickets..."

    # Get active sprint so new tickets land in the current sprint
    ACTIVE_SPRINT_ID=$(jira_get_active_sprint_id)
    log_info "Active sprint ID: ${ACTIVE_SPRINT_ID:-none}"

    CREATED_TICKETS=""
    # Extract titles and specs using Python for reliable multi-line parsing
    SPLIT_JSON=$(echo "$SPLIT_OUTPUT" | python3 -c "
import sys, json, re
text = sys.stdin.read()
tickets = []
for i in range(1, 4):
    title_match = re.search(rf'SPLIT_TICKET_{i}_TITLE:\s*(.+)', text)
    if not title_match:
        continue
    title = title_match.group(1).strip()
    # Find spec: from SPLIT_TICKET_N_SPEC: to next SPLIT_TICKET or end
    spec_pattern = rf'SPLIT_TICKET_{i}_SPEC:\s*\n(.*?)(?=SPLIT_TICKET_\d+_TITLE:|$)'
    spec_match = re.search(spec_pattern, text, re.DOTALL)
    spec = spec_match.group(1).strip()[:4000] if spec_match else ''
    tickets.append({'title': title, 'spec': spec})
print(json.dumps(tickets))
" 2>/dev/null) || SPLIT_JSON="[]"

    for i in $(echo "$SPLIT_JSON" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null); do
      : # just need the count
    done
    TICKET_COUNT=$(echo "$SPLIT_JSON" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null)

    for idx in $(seq 0 $((TICKET_COUNT - 1))); do
      TITLE=$(echo "$SPLIT_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)[$idx]['title'])" 2>/dev/null)
      SPEC=$(echo "$SPLIT_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)[$idx]['spec'])" 2>/dev/null)

      if [[ -n "$TITLE" && -n "$SPEC" ]]; then
        NEW_KEY=$(jira_create_ticket "$TITLE" "$SPEC" "$TICKET_KEY")
        if [[ -n "$NEW_KEY" ]]; then
          jira_add_label "$NEW_KEY" "enriched"
          jira_add_label "$NEW_KEY" "agent:youssef"
          # Move new ticket into the current active sprint
          if [[ -n "$ACTIVE_SPRINT_ID" ]]; then
            jira_move_to_sprint "$NEW_KEY" "$ACTIVE_SPRINT_ID"
          fi
          # Default estimate for split tickets: 0.3 PD (small by definition)
          save_estimate "$NEW_KEY" "0.3" "2" "S" "salma"
          CREATED_TICKETS="${CREATED_TICKETS} ${NEW_KEY}"
          log_info "Created split ticket: ${NEW_KEY} — ${TITLE}"
        else
          log_error "Failed to create split ticket: ${TITLE}"
        fi
      fi
    done

    # Hand parent to Youssef to close PR, then he'll mark it Done
    jira_add_rich_comment "$TICKET_KEY" "salma" "INFO" "## Ticket Split
Split into:${CREATED_TICKETS}

Handing to Youssef to close the PR, then this ticket will be marked Done."
    jira_add_label "$TICKET_KEY" "split-parent"
    jira_remove_label "$TICKET_KEY" "needs-split"
    jira_remove_label "$TICKET_KEY" "needs-refinement-split"
    jira_update_labels "$TICKET_KEY" "agent:salma" "agent:youssef"
    reset_retry "$TICKET_KEY" "salma"
    reset_retry "$TICKET_KEY" "youssef"

    slack_notify "Split $(mm_ticket_link "${TICKET_KEY}") into:${CREATED_TICKETS}
Youssef will close PR then mark original Done. New tickets in current sprint." "pipeline" "warning"
    log_activity "salma" "$TICKET_KEY" "SPLIT" "Split into:${CREATED_TICKETS}"

  elif [[ "$SPLIT_DECISION" == "REWRITE" ]]; then
    # ─── Rewrite spec and send back to Youssef ──────────────────────────────
    log_info "Rewriting spec..."

    NEW_SPEC=$(echo "$SPLIT_OUTPUT" | sed -n '/REWRITE_SPEC:/,$ p' | tail -n +2)

    jira_update_description "$TICKET_KEY" "$NEW_SPEC"
    jira_add_rich_comment "$TICKET_KEY" "salma" "INFO" "## Spec Rewritten
Rewrote spec after ${TICKET_KEY} failed QA/Dev multiple times. Sending back to Youssef with clearer criteria."
    jira_remove_label "$TICKET_KEY" "needs-split"
    jira_remove_label "$TICKET_KEY" "needs-refinement-split"
    jira_update_labels "$TICKET_KEY" "agent:salma" "agent:youssef"
    reset_retry "$TICKET_KEY" "salma"
    reset_retry "$TICKET_KEY" "youssef"
    reset_retry "$TICKET_KEY" "nadia"
    clear_feedback "$TICKET_KEY"

    slack_notify "Rewrote spec for $(mm_ticket_link "${TICKET_KEY}"): ${SUMMARY}
Retries cleared, sending back to Youssef." "pipeline" "warning"
    log_activity "salma" "$TICKET_KEY" "REWRITE" "Rewrote spec: ${SUMMARY}"

  elif [[ "$SPLIT_DECISION" == "FLAG" ]]; then
    # ─── Cannot solve — flag for human ──────────────────────────────────────
    log_info "Flagging for human intervention..."

    FLAG_REASON=$(echo "$SPLIT_OUTPUT" | { grep "FLAG_REASON:" || true; } | head -1 | sed 's/FLAG_REASON: *//')

    jira_add_rich_comment "$TICKET_KEY" "salma" "BLOCKED" "## Flagged for Human Intervention
Cannot resolve this ticket automatically.

Reason: ${FLAG_REASON:-Could not determine a viable split or rewrite}

Removing all agent labels. Human intervention needed."
    jira_remove_label "$TICKET_KEY" "needs-split"
    jira_remove_label "$TICKET_KEY" "needs-refinement-split"
    jira_remove_label "$TICKET_KEY" "agent:salma"
    jira_add_label "$TICKET_KEY" "needs-human"
    reset_retry "$TICKET_KEY" "salma"

    _flag_default="je ne peux pas trouver une façon de découper ou réécrire ce ticket."
    slack_notify "$(mm_ticket_link "${TICKET_KEY}") — j'ai besoin d'un avis humain. ${FLAG_REASON:-$_flag_default} Hedi, ton input serait précieux ici." "pipeline" "danger"
    log_activity "salma" "$TICKET_KEY" "FLAG" "Needs human: ${FLAG_REASON:-unknown}"

  else
    # ─── UNKNOWN decision — don't burn retry ────────────────────────────────
    log_error "Could not parse split decision from Claude output"
    jira_add_rich_comment "$TICKET_KEY" "salma" "WARNING" "Split analysis inconclusive (parsing issue). Will retry next cycle."
    slack_notify "Split analysis inconclusive for $(mm_ticket_link "${TICKET_KEY}"), will retry next cycle"
  fi

  log_info "=== Salma finished split handling for ${TICKET_KEY} ==="
  exit 0
fi

# ─── 3b. Check if already enriched ───────────────────────────────────────────
if printf "%s\n" "$LABELS" | grep -q "enriched"; then
  log_info "Ticket already enriched — forwarding to Youssef"
  jira_update_labels "$TICKET_KEY" "agent:salma" "agent:youssef"
  slack_notify "Forwarded $(mm_ticket_link "${TICKET_KEY}") to Youssef (already enriched)"
  log_success "=== Salma forwarded ${TICKET_KEY} (already enriched) ==="
  exit 0
fi

# ─── 4. Gather additional context ──────────────────────────────────────────

# Get Layla's latest market intelligence (useful for domain-complex tickets)
LAYLA_CONTEXT=""
LAYLA_REPORT=$(get_layla_report 2>/dev/null || true)
if [[ -n "$LAYLA_REPORT" ]]; then
  LAYLA_CONTEXT="

MARKET INTELLIGENCE (from Layla's daily report):
${LAYLA_REPORT}

Consider this market intelligence when writing acceptance criteria.
If the report mentions regulatory concerns relevant to this ticket, add them to the Risks section."
  log_info "Injected Layla's market report into Salma's prompt"
fi

# Get any messages from Hedi
HEDI_CONTEXT=""
HEDI_MESSAGES=$(get_hedi_messages "salma" 2>/dev/null || true)
if [[ -n "$HEDI_MESSAGES" ]]; then
  HEDI_CONTEXT="

MESSAGES FROM HEDI (human lead):
${HEDI_MESSAGES}

Incorporate Hedi's input into your spec. His feedback takes priority over automated analysis."
  log_info "Injected Hedi's messages into Salma's prompt"
fi

# Check for standup round-table decisions
STANDUP_CONTEXT=""
STANDUP_DECISION_FILE="/tmp/${PROJECT_PREFIX}-standup-decisions/${TICKET_KEY}.md"
if [[ -f "$STANDUP_DECISION_FILE" ]] && printf "%s\n" "$LABELS" | grep -q "was-discussed-in-standup" 2>/dev/null; then
  STANDUP_DECISION=$(cat "$STANDUP_DECISION_FILE")
  STANDUP_CONTEXT="

STANDUP ROUND-TABLE DECISION:
The team discussed this ticket in standup and decided:
${STANDUP_DECISION}

Incorporate this feedback into your spec."
  log_info "Injected standup decision for ${TICKET_KEY}"
fi

# ─── 5. Invoke Claude Code for spec writing ──────────────────────────────────
log_info "Invoking Claude Code (${MODEL}) for spec enrichment..."

CLAUDE_PROMPT="You are Salma, the PM agent for ${PROJECT_NAME} (${PROJECT_KEY}).
Read the file ai/pm.md for your complete rules and output format.

TICKET: ${TICKET_KEY}
TITLE: ${SUMMARY}
PRIORITY: ${PRIORITY}
DESCRIPTION:
${DESCRIPTION:-No description provided}

EXISTING COMMENTS:
${COMMENTS:-None}

YOUR TASK:
1. Read ai/pm.md for your PM rules and output format
2. Read ai/STORY_POINTS.md for story point estimation guidelines and reference examples
3. Read the existing codebase to understand the project context:
   - Check src/ directory structure
   - Look at existing patterns in similar files
4. RESEARCH PHASE — Use WebSearch and WebFetch to gather context:
   - If the ticket involves specific domain rules or mechanics, research the relevant domain context
   - If the ticket involves a specific API or library, research documentation and best practices
   - If the ticket involves a UI pattern, research common implementations
   - Summarize key findings in the Notes section of your spec
   - Always cite sources when referencing external information
5. PRODUCT MARKETING CONSULTATION (OPTIONAL):
   - Read ai/product-marketing.md to understand Layla's role
   - If the ticket requires game feature validation, player experience assessment, multiplayer readiness check, or feature prioritization (RICE scoring), you MAY invoke Layla as an advisory consultant
   - Layla provides expertise on: board game design best practices, player experience, digital board game market trends, and RICE prioritization framework
   - To invoke Layla: Include her analysis inline as you write your spec (e.g., 'Layla validated game rule compliance for casino mechanics...')
   - Layla's input is ADVISORY — you (Salma) make the final spec decisions
   - Do NOT invoke Layla for simple tickets (bug fixes, minor UI changes) — use her for domain-complex features only
6. Write a complete spec for this ticket following the EXACT format from ai/pm.md:
   - Summary (one sentence)
   - User Story (As a..., I want..., so that...)
   - Acceptance Criteria (Given/When/Then format, MUST use markdown checkboxes: \`- [ ]\`)
   - Definition of Ready (monetary rules, line-limit rules, infrastructure changes, security requirements, technical readiness — copy template from ai/pm.md)
   - Scope (In scope / Out of scope)
   - Dependencies
   - Risks
   - Notes (include relevant file paths from the codebase AND research findings)
   - **Story Points (REQUIRED)**: Estimate using Fibonacci scale (1, 2, 3, 5, 8, 13) based on effort + complexity + uncertainty
6. Estimate complexity: S (< 50 lines), M (50-150 lines), L (150-300 lines)

CRITICAL ACCEPTANCE CRITERIA REQUIREMENTS:
- ALL acceptance criteria MUST use markdown checkbox format: \`- [ ] Given..., when..., then...\`
- For monetary fields: Include explicit money-in-cents validation criteria (e.g., \"value stored as integer cents\")
- For all feature implementations: Include line-limit criteria (e.g., \"no file > 200 lines, PR < 250 lines\")
- For database/auth/config changes: Include explicit DevOps review flag (e.g., \"DevOps approval required\")
- These checkboxes will be used by Nadia (QA) for test verification and by automated pre-commit hooks

MANDATORY TEST CASES SECTION (REQUIRED — spec will be REJECTED without it):
Every spec MUST include a '## Test Cases' section placed after '## Acceptance Criteria', with ALL FOUR subsections populated with ticket-specific content (no placeholder text):
### Happy Path — describe the primary success flow for this specific ticket
### Edge Cases — boundary values, empty states, concurrent writes relevant to this feature
### Permission Boundaries — unauthenticated vs. authenticated vs. role-specific access for this feature
### Failure Modes — game state corruption, invalid moves, turn flow interruption, edge cases for this feature
Do NOT copy generic examples. Each subsection must contain scenario-specific items for this ticket.

IMPORTANT:
- Be specific and actionable — Youssef (Dev) will implement directly from your spec
- Reference actual file paths in the codebase
- Keep scope tight — prefer small, vertical slices
- Include technical notes that help the developer
- Include research findings when relevant to the domain (investment law, regulations, etc.)
- **ALL tickets MUST have a story point estimate** (see ai/STORY_POINTS.md for reference examples)
- Compare to reference examples when estimating (e.g., typo fix = 1 pt, new API endpoint = 5 pts)
- Do NOT write code — only write the specification
- Do NOT invent domain rules — always reference the project's domain documentation
${LAYLA_CONTEXT}${HEDI_CONTEXT}${STANDUP_CONTEXT}
$(if printf "%s\n" "$LABELS" | grep -q "retro-action" 2>/dev/null; then echo "
RETRO ACTION ITEM — INTEGRATION POINTS REQUIRED:
This is a retrospective action item. The spec MUST include a '## Integration Points' section listing:
1. Which agent scripts (n8n/scripts/agent-*.sh) must be modified and HOW
2. What the integration looks like (e.g., 'Add check in agent-nadia.sh after verdict parsing')
CRITICAL ARCHITECTURE CONSTRAINTS:
- Nadia (QA) has NO file access — her rules must be inlined in agent-nadia.sh prompt
- Rami (Architect+DevOps) runs architecture review AND automated diff checks — he does NOT read PR body or template files
- Pre-commit hooks must be auto-installed via package.json prepare script
- Templates/checklists that no agent script reads are USELESS — they MUST be wired in
- Creating a markdown template without modifying agent scripts is NOT an acceptable solution

TEAM PERSPECTIVE COMMENTS:
The team members (Youssef/Dev, Nadia/QA, Rami/Architect+DevOps, Omar/Ops) may have already written
perspective comments on this ticket. READ THE EXISTING COMMENTS carefully — they contain
valuable input about implementation approach, QA criteria, DevOps constraints, and monitoring
needs. Incorporate their insights into your spec. Their comments are labeled as
'Dev Perspective', 'QA Perspective', 'DevOps Perspective', or 'Ops Perspective'."; fi)

Output ONLY the spec text, no preamble. Start with ## Summary"

CLAUDE_OUTPUT=$(cd "$PROJECT_DIR" && claude -p "$CLAUDE_PROMPT" \
  --allowedTools "Read Glob Grep WebSearch WebFetch" \
  --model $MODEL --max-turns 25 2>/dev/null) || true

log_info "Claude PM output:"
echo "$CLAUDE_OUTPUT" >> "$LOG_FILE"

# ─── 6. Validate output ──────────────────────────────────────────────────────
log_info "Validating spec..."

if [[ -z "$CLAUDE_OUTPUT" ]]; then
  log_error "Claude returned empty output"
  increment_retry "$TICKET_KEY" "salma"
  exit 1
fi

# Check for key sections — write to temp file to avoid pipe/quoting issues
SPEC_TMPFILE=$(mktemp /tmp/${PROJECT_PREFIX}-spec-XXXXXX.txt)
printf '%s\n' "$CLAUDE_OUTPUT" > "$SPEC_TMPFILE"
log_info "Output length: ${#CLAUDE_OUTPUT} chars, $(wc -l < "$SPEC_TMPFILE") lines"
HAS_SUMMARY=false
HAS_CRITERIA=false
HAS_DOR=false
HAS_CHECKBOXES=false
if grep -qi "## Summary" "$SPEC_TMPFILE"; then
  HAS_SUMMARY=true
fi
if grep -qi "Acceptance Criteria" "$SPEC_TMPFILE"; then
  HAS_CRITERIA=true
fi
if grep -qi "Definition of Ready" "$SPEC_TMPFILE"; then
  HAS_DOR=true
fi
# Validate checkbox format exists in acceptance criteria
if grep -q "\- \[ \]" "$SPEC_TMPFILE"; then
  HAS_CHECKBOXES=true
fi
rm -f "$SPEC_TMPFILE"
log_info "Validation: Summary=${HAS_SUMMARY} Criteria=${HAS_CRITERIA} DOR=${HAS_DOR} Checkboxes=${HAS_CHECKBOXES} TestCases=pending"

if [[ "$HAS_SUMMARY" == "false" ]] || [[ "$HAS_CRITERIA" == "false" ]]; then
  log_error "Spec missing required sections (Summary: ${HAS_SUMMARY}, Criteria: ${HAS_CRITERIA})"
  increment_retry "$TICKET_KEY" "salma"
  jira_add_rich_comment "$TICKET_KEY" "salma" "WARNING" "Spec generation failed — missing required sections. Will retry."
  exit 1
fi

# Hard gate: Definition of Ready is required
if [[ "$HAS_DOR" == "false" ]]; then
  log_error "Spec missing required Definition of Ready section"
  increment_retry "$TICKET_KEY" "salma"
  jira_add_rich_comment "$TICKET_KEY" "salma" "WARNING" "Spec generation failed — missing Definition of Ready checklist. Must include explicit constraints (monetary rules, line limits, infrastructure changes). Will retry."
  exit 1
fi

if [[ "$HAS_CHECKBOXES" == "false" ]]; then
  log_info "WARNING: Spec missing checkbox format in acceptance criteria (non-blocking)"
fi

# Hard gate: Test Cases section is required
HAS_TEST_CASES=false
SPEC_TMPFILE2=$(mktemp /tmp/${PROJECT_PREFIX}-spec-XXXXXX.txt)
printf '%s\n' "$CLAUDE_OUTPUT" > "$SPEC_TMPFILE2"
if grep -qi "## Test Cases" "$SPEC_TMPFILE2"; then
  HAS_TEST_CASES=true
fi
if [[ "$HAS_TEST_CASES" == "false" ]]; then
  log_error "Spec missing required Test Cases section"
  increment_retry "$TICKET_KEY" "salma"
  jira_add_rich_comment "$TICKET_KEY" "salma" "WARNING" "Spec generation failed — missing '## Test Cases' section. Must include ### Happy Path, ### Edge Cases, ### Permission Boundaries, and ### Failure Modes subsections. Will retry."
  exit 1
fi
log_info "Test Cases section found"

# Validate Integration Points section for retro-action tickets
if printf "%s\n" "$LABELS" | grep -q "retro-action" 2>/dev/null; then
  if ! grep -qi "Integration Points" "$SPEC_TMPFILE2"; then
    log_error "Retro-action spec missing required Integration Points section"
    increment_retry "$TICKET_KEY" "salma"
    jira_add_rich_comment "$TICKET_KEY" "salma" "WARNING" "Retro-action spec must include '## Integration Points' listing which agent scripts to modify. Will retry."
    exit 1
  fi
  log_info "Integration Points section found for retro-action ticket"
fi
rm -f "$SPEC_TMPFILE2"

log_info "Spec validation passed"

# ─── 7. Post spec to Jira ────────────────────────────────────────────────────
log_info "Posting spec to Jira..."

# Truncate if too long (Jira comment limit)
SPEC_TEXT="$CLAUDE_OUTPUT"
if [[ ${#SPEC_TEXT} -gt 10000 ]]; then
  SPEC_TEXT="${SPEC_TEXT:0:10000}

[Spec truncated — see full version in agent logs]"
fi

# Write spec as rich ADF description (blue panel) instead of plain comment
jira_set_spec "$TICKET_KEY" "salma" "$SPEC_TEXT"

# ─── 7b. Extract and write story points to Jira ──────────────────────────────
log_info "Extracting story points from spec..."

# Extract story points from spec (look for "**Estimate:** X points" or "Estimate: X points")
STORY_POINTS=$(printf "%s\n" "$SPEC_TEXT" | { grep -oP '(?<=\*\*Estimate:\*\* )\d+(?= point)' || grep -oP '(?<=Estimate: )\d+(?= point)' || echo ""; } | head -1)

if [[ -n "$STORY_POINTS" ]] && [[ "$STORY_POINTS" =~ ^(1|2|3|5|8|13)$ ]]; then
  log_info "Found story points: ${STORY_POINTS}"
  jira_update_field "$TICKET_KEY" "customfield_10016" "$STORY_POINTS"
  log_info "Story points written to Jira: ${STORY_POINTS}"
else
  log_info "No valid story points found in spec (expected Fibonacci: 1, 2, 3, 5, 8, 13)"
fi

# ─── 7c. Estimate person-days (for billing) ──────────────────────────────
# Extract complexity from spec (S/M/L/XL) and convert SP → person-days
COMPLEXITY=$(printf "%s\n" "$SPEC_TEXT" | { grep -oP '(?<=Estimated complexity: )\S+' || grep -oP '(?<=complexity: )\S+' || echo "M"; } | head -1)
COMPLEXITY=$(echo "$COMPLEXITY" | tr -d '[]()' | head -c 2)  # clean up

if [[ -n "$STORY_POINTS" ]] && [[ "$STORY_POINTS" =~ ^(1|2|3|5|8|13)$ ]]; then
  PERSON_DAYS=$(story_points_to_person_days "$STORY_POINTS")
else
  # Fallback: estimate from complexity alone
  case "$COMPLEXITY" in
    S)  PERSON_DAYS="0.15" ; STORY_POINTS="1" ;;
    M)  PERSON_DAYS="0.5"  ; STORY_POINTS="3" ;;
    L)  PERSON_DAYS="1.0"  ; STORY_POINTS="5" ;;
    XL) PERSON_DAYS="2.5"  ; STORY_POINTS="13" ;;
    *)  PERSON_DAYS="0.5"  ; STORY_POINTS="3" ;;
  esac
fi

save_estimate "$TICKET_KEY" "$PERSON_DAYS" "$STORY_POINTS" "$COMPLEXITY" "salma"

# Also add a short comment for visibility in Jira activity stream
SPEC_COMMENT="## Spec Ready
Spec written to ticket description. Acceptance criteria ready for Youssef."

if [[ -n "$STORY_POINTS" ]] && [[ "$STORY_POINTS" =~ ^(1|2|3|5|8|13)$ ]]; then
  SPEC_COMMENT="${SPEC_COMMENT}

Story points: **${STORY_POINTS}** | Person-days: **${PERSON_DAYS}** | Complexity: **${COMPLEXITY}**"
fi

jira_add_rich_comment "$TICKET_KEY" "salma" "PASS" "$SPEC_COMMENT"

# ─── 8. Update ticket and hand off ───────────────────────────────────────────
jira_add_label "$TICKET_KEY" "enriched"
reset_retry "$TICKET_KEY" "salma"

# Determine handoff: domain-complex tickets → Layla (market gate), simple → Youssef directly
NEEDS_FEASIBILITY=false
if printf "%s\n" "$SPEC_TEXT $SUMMARY" | grep -qiE "multiplayer|lobby|matchmaking|AI.opponent|tournament|leaderboard|localization|mobile|PWA|save.system|replay"; then
  NEEDS_FEASIBILITY=true
fi
# Simple tickets skip both Layla and Rami gates
if printf "%s\n" "$LABELS" | grep -qiE "bug|fix|typo|documentation|config|cleanup|retro-action"; then
  NEEDS_FEASIBILITY=false
fi

SPEC_PREVIEW=$(printf "%s\n" "$SPEC_TEXT" | head -10 | head -c 200)
SPEC_SHORT=$(echo "$SUMMARY" | head -c 80)

if [[ "$NEEDS_FEASIBILITY" == "true" ]]; then
  log_info "Domain-complex ticket — routing to Layla for feasibility check"
  jira_update_labels "$TICKET_KEY" "agent:salma" "agent:layla"
  slack_notify "$(mm_ticket_link "${TICKET_KEY}") — spec enrichie et prête ! C'est un ticket complexe côté produit, je passe à Layla pour validation de faisabilité avant qu'on démarre le dev." "pipeline" "good"
  log_activity "salma" "$TICKET_KEY" "ENRICHED" "Wrote spec: ${SPEC_SHORT} → Layla"
  log_success "=== Salma enriched ${TICKET_KEY} — routed to Layla ==="
else
  log_info "Simple ticket — forwarding directly to Youssef"
  jira_update_labels "$TICKET_KEY" "agent:salma" "agent:youssef"
  slack_notify "$(mm_ticket_link "${TICKET_KEY}") — spec rédigée, critères d'acceptation définis. Youssef, c'est à toi ! Les fichiers à modifier sont référencés dans le ticket." "pipeline" "good"
  log_activity "salma" "$TICKET_KEY" "ENRICHED" "Wrote spec: ${SPEC_SHORT} → Youssef"
  log_success "=== Salma enriched ${TICKET_KEY} — handed off to Youssef ==="
fi
