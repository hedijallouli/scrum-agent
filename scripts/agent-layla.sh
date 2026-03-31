#!/usr/bin/env bash
# =============================================================================
# agent-layla.sh — Product Strategist: validates market feasibility before dev
# Sits between Salma (PM) and Rami (Architect) in the pipeline.
# Auto-skips simple tickets (bugs, config, docs).
# =============================================================================
AGENT_NAME="layla"
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/agent-common.sh"

TICKET_KEY="${1:?Usage: agent-layla.sh BISB-XX}"
MAX_RETRIES=2  # Validation gate — 2 tries max before escalating to human

init_log "$TICKET_KEY" "layla"
log_info "=== Layla (Product Strategist) starting feasibility review for ${TICKET_KEY} ==="
JIRA_URL="$(jira_link "$TICKET_KEY")"

# ─── 1. Check retry count + cooldown ────────────────────────────────────────
retry_count=$(get_retry_count "$TICKET_KEY" "layla")
if (( retry_count >= MAX_RETRIES )); then
  log_error "Max retries ($MAX_RETRIES) reached for ${TICKET_KEY}."
  jira_add_rich_comment "$TICKET_KEY" "layla" "BLOCKED" "## Feasibility Review Failed
Could not validate game feature feasibility after ${MAX_RETRIES} attempts. Needs human review."
  jira_add_label "$TICKET_KEY" "needs-human"
  jira_remove_label "$TICKET_KEY" "agent:layla"
  slack_notify "Blocked $(mm_ticket_link "${TICKET_KEY}") — product review failed, needs human" "pipeline" "danger"
  exit 1
fi

if ! check_cooldown "$TICKET_KEY" "layla"; then
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

# ─── Ideation detection ────────────────────────────────────────────────────────────
IS_IDEATION=false
if echo "$SUMMARY" | grep -qiE "propose|generate|brainstorm|concepts|ideas|ideation|rethink"; then
  IS_IDEATION=true
  log_info "Ideation ticket detected: $SUMMARY"
fi
# But skip ideation if ticket already has enriched label (concept was already picked by Salma)
if echo "$LABELS" | grep -q "enriched"; then
  IS_IDEATION=false
  log_info "Ticket already enriched — skipping ideation, doing feasibility review"
fi

# ─── 3. Auto-skip simple tickets ─────────────────────────────────────────────
# Bugs, config changes, docs, retro-actions don't need market feasibility checks
if echo "$LABELS $SUMMARY" | grep -qiE "bug|fix|typo|documentation|config|cleanup|retro-action"; then
  log_info "Simple ticket (label/title match) — auto-approving, forwarding to Rami"
  jira_add_rich_comment "$TICKET_KEY" "layla" "PASS" "## Auto-Approved (Product Review)
Simple ticket — no product review needed. Forwarding to architecture review."
  jira_update_labels "$TICKET_KEY" "agent:layla" "agent:rami"
  log_activity "layla" "$TICKET_KEY" "AUTO_APPROVED" "Simple ticket, forwarded to Rami"
  slack_notify "Auto-approved $(mm_ticket_link "${TICKET_KEY}") — forwarding to Rami for tech review" "pipeline"
  exit 0
fi

# ─── Ideation Mode ─────────────────────────────────────────────────────────────────
if [[ "$IS_IDEATION" == "true" ]]; then
  log_info "Entering ideation mode for $TICKET_KEY"
  
  # Select model for ideation
  MODEL=$(select_model_for_ticket "$LABELS" "$PRIORITY")
  MODEL=$(select_model_rate_aware "$MODEL" "layla" "ceremony")
  MODEL=$(activate_api_key_if_needed "$MODEL")
  if [[ "$MODEL" == "WAIT" ]]; then
    log_info "Sonnet rate-limited — layla skipping (non-critical, no API key)"
    exit 0
  fi
  log_info "Ideation model: ${MODEL}"

  # Build ideation prompt
  IDEATION_PROMPT="You are Layla, Product Strategist for Business is Business (BisB) — a Tunisian board game being digitized.

TICKET: $TICKET_KEY
SUMMARY: $SUMMARY

DESCRIPTION:
$DESCRIPTION

TASK: Propose exactly 10 distinct, creative concepts based on the ticket description above.

For each concept, provide:
1. **Name** — short, catchy name
2. **Tagline** — one sentence pitch
3. **Core Mechanic** — what makes it unique gameplay-wise
4. **How it changes**: economy, player interaction, game length
5. **Why it's fun** — reference BGA, Monopoly GO, competitive card games, or other modern games
6. **RICE Score** — Reach (1-10), Impact (1-10), Confidence (1-10), Effort (1-10 where 10=easy)

Consider: timed turns, draft mechanics, objectives, asymmetric starts, elimination rounds, resource scarcity, team play, auction-only mode, speed runs, handicaps, catch-up mechanics, etc.

Format each concept as:
## Concept N: [Name]
**Tagline:** ...
**Core Mechanic:** ...
**Economy/Interaction/Length:** ...
**Fun Factor:** ...
**RICE:** R=X I=X C=X E=X → Score: XX

End with:
VERDICT: IDEATION_COMPLETE"

  # Invoke Claude
  log_info "Invoking Claude for ideation ($MODEL)..."
  CLAUDE_OUTPUT=$(echo "$IDEATION_PROMPT" | claude --model "$MODEL" --max-turns 5 --allowedTools "WebSearch WebFetch" -p 2>&1) || {
    log_info "ERROR: Claude invocation failed for ideation"
    increment_retry "$TICKET_KEY" "layla"
    exit 1
  }
  
  log_info "Claude ideation output: ${#CLAUDE_OUTPUT} chars"
  
  # Post concepts as comment on ticket
  jira_add_rich_comment "$TICKET_KEY" "layla" "PASS" "$CLAUDE_OUTPUT"
  log_info "Posted 10 concepts as comment on $TICKET_KEY"
  
  # Label swap: agent:layla → agent:salma + add ideation-ready
  jira_update_labels "$TICKET_KEY" "agent:layla" "agent:salma"
  jira_add_label "$TICKET_KEY" "ideation-ready"
  log_info "Routed to Salma with ideation-ready label"
  
  # Slack notification
  slack_notify ":bulb: *Layla — Ideation Complete*\nTicket: $(mm_ticket_link "${TICKET_KEY}")\n10 concepts proposed, routing to Salma for selection" "pipeline"
  
  log_info "Ideation mode complete for $TICKET_KEY"
  exit 0
fi

# ─── 4. Select model ─────────────────────────────────────────────────────────
MODEL=$(select_model_for_ticket "$LABELS" "$PRIORITY")
# Override: always use Sonnet for investment/regulatory features
if echo "$SUMMARY $DESCRIPTION" | grep -qiE "multiplayer|lobby|matchmaking|AI.opponent|tournament|leaderboard|localization|mobile|PWA"; then
  MODEL="sonnet"
fi
MODEL=$(select_model_rate_aware "$MODEL" "layla" "general")
MODEL=$(activate_api_key_if_needed "$MODEL")
if [[ "$MODEL" == "WAIT" ]]; then
  log_info "Sonnet rate-limited — layla skipping feasibility review (no API key)"
  exit 0
fi
log_info "Model: ${MODEL}"

# ─── 5. Build sprint context ─────────────────────────────────────────────────
SPRINT_TICKETS=$(jira_search_keys_with_summaries "project = ${JIRA_PROJECT} AND labels = 'sprint-active' AND statusCategory != 'Done'" "15" 2>/dev/null || true)
SPRINT_CONTEXT=""
if [[ -n "$SPRINT_TICKETS" ]]; then
  SPRINT_CONTEXT="
CURRENT SPRINT TICKETS (for context):
${SPRINT_TICKETS}"
fi

# ─── 6. Invoke Claude for feasibility validation ─────────────────────────────
log_info "Invoking Claude (${MODEL}) for feasibility review..."

CLAUDE_PROMPT="You are Layla, the Product Strategist for BisB (Business is Business), a digital version of the popular Tunisian board game created by Zied Remadi.
Read the file ai/product-marketing.md for your complete rules and domain knowledge.

TICKET: ${TICKET_KEY}
TITLE: ${SUMMARY}
PRIORITY: ${PRIORITY}

SPECIFICATION (written by Salma):
${DESCRIPTION:-No description provided}

COMMENTS:
${COMMENTS:-None}
${SPRINT_CONTEXT}

YOUR TASK — FEASIBILITY VALIDATION:
1. Read ai/product-marketing.md for your role, RICE framework, and regulatory context
2. RESEARCH PHASE:
   - Use WebSearch to check for digital board game trends and best practices
   - Check if competitors (Board Game Arena, Tabletop Simulator, Monopoly GO, Catan Universe) have similar features
   - Research player experience patterns for digital board games
3. VALIDATE against these criteria:
   a) GAME FIDELITY: Does this feature accurately represent the physical board game rules?
   b) PLAYER EXPERIENCE: Is the UX intuitive for non-technical Tunisian families?
   c) MULTIPLAYER READINESS: Will this work for future online multiplayer?
   d) RICE SCORE: Calculate a quick RICE prioritization score
   e) AUDIENCE FIT: Does this serve the Tunisian diaspora and Arabic/French-speaking audience?

4. Produce a verdict in this EXACT format at the END of your output:

VERDICT: APPROVED
RICE_SCORE: [calculated score]
MARKET_NOTES: [brief market context]

or

VERDICT: NEEDS_REVISION
ISSUES:
- Issue 1: description and what to change
- Issue 2: description
SUGGESTED_CHANGES: [specific spec modifications for Salma]

or

VERDICT: PIVOT_SUGGESTED
REASON: [why current approach doesn't fit the game]
ALTERNATIVE: [what to build instead]
PLAYER_EVIDENCE: [data supporting the change]

CRITICAL: You MUST output exactly one VERDICT line. Start with your analysis, end with the verdict block."

PROMPT_FILE=$(mktemp /tmp/layla-prompt-XXXXXX.txt)
echo "$CLAUDE_PROMPT" > "$PROMPT_FILE"

CLAUDE_OUTPUT=$(cd "$PROJECT_DIR" && claude -p - \
  --allowedTools "Read Glob Grep WebSearch WebFetch" \
  --model "$MODEL" --max-turns 15 \
  < "$PROMPT_FILE" 2>/dev/null) || true
rm -f "$PROMPT_FILE"

log_info "Claude output:"
echo "$CLAUDE_OUTPUT" >> "$LOG_FILE"

# ─── 7. Parse verdict ────────────────────────────────────────────────────────
if [[ -z "$CLAUDE_OUTPUT" ]]; then
  log_error "Claude returned empty output"
  increment_retry "$TICKET_KEY" "layla"
  jira_add_rich_comment "$TICKET_KEY" "layla" "WARNING" "## Feasibility Review — Empty Response
Claude returned empty output. Will retry on next cycle."
  exit 1
fi

# Write output to temp file for reliable parsing (avoids echo|grep issues with large outputs)
LAYLA_TMPFILE=$(mktemp /tmp/${PROJECT_PREFIX}-layla-XXXXXX.txt)
printf '%s\n' "$CLAUDE_OUTPUT" > "$LAYLA_TMPFILE"
VERDICT=$(parse_verdict "$LAYLA_TMPFILE")
rm -f "$LAYLA_TMPFILE"
log_info "Parsed verdict: $VERDICT"

log_info "Verdict: ${VERDICT}"

# ─── 8. Route based on verdict ───────────────────────────────────────────────
case "$VERDICT" in
  APPROVED)
    # Extract RICE score if present
    RICE_SCORE=$(echo "$CLAUDE_OUTPUT" | grep -oP "RICE_SCORE:\s*\K.*" | head -1 || true)
    MARKET_NOTES=$(echo "$CLAUDE_OUTPUT" | grep -oP "MARKET_NOTES:\s*\K.*" | head -1 || true)

    jira_add_rich_comment "$TICKET_KEY" "layla" "PASS" "## Product Review: APPROVED
${RICE_SCORE:+RICE Score: ${RICE_SCORE}
}${MARKET_NOTES:+Market Notes: ${MARKET_NOTES}
}
Forwarding to Rami for architecture review."

    jira_update_labels "$TICKET_KEY" "agent:layla" "agent:rami"
    reset_retry "$TICKET_KEY" "layla"
    log_activity "layla" "$TICKET_KEY" "APPROVED" "Market feasibility approved, forwarded to Rami"
    slack_notify "Approved $(mm_ticket_link "${TICKET_KEY}") — product review passed, forwarding to Rami
${RICE_SCORE:+RICE: ${RICE_SCORE}}" "pipeline" "good"
    ;;

  NEEDS_REVISION)
    # Extract issues for feedback
    ISSUES=$(echo "$CLAUDE_OUTPUT" | sed -n '/ISSUES:/,/SUGGESTED_CHANGES:\|VERDICT:/p' | head -10 || true)
    SUGGESTED=$(echo "$CLAUDE_OUTPUT" | grep -oP "SUGGESTED_CHANGES:\s*\K.*" | head -1 || true)

    # Write feedback file for Salma
    FEEDBACK_DIR="/tmp/${PROJECT_PREFIX}-feedback"
    mkdir -p "$FEEDBACK_DIR"
    cat > "${FEEDBACK_DIR}/${TICKET_KEY}.txt" <<FEEDEOF
AGENT: layla
VERDICT: NEEDS_REVISION
TIMESTAMP: $(date -u +%Y-%m-%dT%H:%M:%S)
ISSUES:
${ISSUES}
SUGGESTED_CHANGES: ${SUGGESTED}
FEEDEOF

    jira_add_rich_comment "$TICKET_KEY" "layla" "FAIL" "## Product Review: NEEDS REVISION
${ISSUES}
${SUGGESTED:+Suggested changes: ${SUGGESTED}
}
Returning to Salma for spec revision."

    jira_update_labels "$TICKET_KEY" "agent:layla" "agent:salma"
    jira_remove_label "$TICKET_KEY" "enriched"
    increment_retry "$TICKET_KEY" "layla"
    log_activity "layla" "$TICKET_KEY" "NEEDS_REVISION" "Sent back to Salma for revision"
    slack_notify "Returned $(mm_ticket_link "${TICKET_KEY}") to Salma — needs product revision" "pipeline" "warning"
    ;;

  PIVOT_SUGGESTED)
    REASON=$(echo "$CLAUDE_OUTPUT" | grep -oP "REASON:\s*\K.*" | head -1 || true)
    ALTERNATIVE=$(echo "$CLAUDE_OUTPUT" | grep -oP "ALTERNATIVE:\s*\K.*" | head -1 || true)

    jira_add_rich_comment "$TICKET_KEY" "layla" "BLOCKED" "## PIVOT ALERT
${REASON:+Reason: ${REASON}
}${ALTERNATIVE:+Alternative approach: ${ALTERNATIVE}
}
This ticket's current approach may not fit the game's player experience goals.
Escalating to Hedi for a product decision."

    jira_add_label "$TICKET_KEY" "needs-human"
    jira_remove_label "$TICKET_KEY" "agent:layla"
    reset_retry "$TICKET_KEY" "layla"
    log_activity "layla" "$TICKET_KEY" "PIVOT_SUGGESTED" "Escalated to human — pivot recommended"
    slack_notify "PIVOT ALERT $(mm_ticket_link "${TICKET_KEY}")
${REASON:+${REASON}}
${ALTERNATIVE:+Alternative: ${ALTERNATIVE}}
Needs human decision." "pipeline" "danger"
    ;;

  UNKNOWN)
    # Don't burn retry on parsing failure
    log_info "Could not parse verdict — will retry next cycle"
    jira_add_rich_comment "$TICKET_KEY" "layla" "WARNING" "## Feasibility Review — Parse Error
Could not determine verdict. Will retry on next cycle."
    ;;
esac

log_info "=== Layla finished feasibility review for ${TICKET_KEY} (verdict: ${VERDICT}) ==="
