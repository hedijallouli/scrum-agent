#!/bin/bash
set -euo pipefail

# ─── Layla Retro-Action Agent ──────────────────────────────────────────────
# Writes product/market perspective on retro-action tickets

AGENT_NAME="layla-retro"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/agent-common.sh"

TICKET_KEY="${1:?Usage: agent-layla-retro.sh TICKET_KEY}"
init_log "$AGENT_NAME" "$TICKET_KEY"
log_info "Layla retro-action starting for $TICKET_KEY"

# ─── Fetch ticket details ───────────────────────────────────────────────────
TICKET_JSON=$(jira_get_ticket "$TICKET_KEY")
SUMMARY=$(echo "$TICKET_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['fields']['summary'])" 2>/dev/null)
DESCRIPTION=$(jira_get_description_text "$TICKET_KEY")
COMMENTS=$(jira_get_comments "$TICKET_KEY")

log_info "Ticket: $SUMMARY"

# ─── Generate game/market perspective ────────────────────────────────────────
MARKET_ROLE=$(cat "${SCRIPT_DIR}/../ai/product-marketing.md" 2>/dev/null || echo "You are Layla, the Product & Market Strategist.")

CLAUDE_OUTPUT=$(claude -p --model haiku --max-turns 1  "
${MARKET_ROLE}

You are writing a PRODUCT/MARKET PERSPECTIVE comment for a retro-action ticket.
Read your persona file for full project context.

TICKET: $TICKET_KEY
SUMMARY: $SUMMARY
DESCRIPTION:
$DESCRIPTION

EXISTING COMMENTS:
${COMMENTS:-None}

Write a concise game/market perspective (max 300 words) covering:
1. **Player Experience**: How does this impact player engagement and fun?
2. **Market Positioning**: How does this compare to competitor implementations?
3. **Game Design**: Does this align with board game design principles?
4. **Cultural Relevance**: Tunisian/MENA market considerations
5. **Market Acceptance Criteria**: 2-3 bullet points

Format as a clean comment. Start with '🎯 **Game & Market Perspective**' header.
Do NOT include any VERDICT.
")

if [[ -z "$CLAUDE_OUTPUT" ]]; then
  log_error "Claude returned empty output"
  exit 1
fi

# ─── Post comment and route to Salma ─────────────────────────────────────────
jira_add_rich_comment "$TICKET_KEY" "$CLAUDE_OUTPUT" "layla"
log_info "Posted game/market perspective comment"

jira_update_labels "$TICKET_KEY" "agent:layla" "agent:salma"
log_info "Routed to Salma"

slack_notify "layla" "📋 Layla posted game/market perspective on $TICKET_KEY ($SUMMARY), routing to Salma"
log_activity "layla" "retro-perspective" "$TICKET_KEY" "Posted game/market perspective, routed to Salma"

log_success "Layla retro-action complete for $TICKET_KEY"
