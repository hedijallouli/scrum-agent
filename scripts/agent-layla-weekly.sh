#!/bin/bash
set -euo pipefail

# ─── BISB Layla Weekly Report ──────────────────────────────────────────────
# Runs every Monday — Sprint progress + Board game market intelligence
# Uses Sonnet with WebSearch/WebFetch for market research

AGENT_NAME="layla-weekly"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/agent-common.sh"
init_log "$AGENT_NAME" "weekly"

# ─── Dedup: once per week ───────────────────────────────────────────────────
WEEK_ID=$(date -u +%Y-W%V)
FLAG_FILE="/tmp/${PROJECT_PREFIX}-layla-weekly-${WEEK_ID}"
if [[ -f "$FLAG_FILE" ]]; then
  log_info "Weekly report already generated for $WEEK_ID"
  exit 0
fi

log_info "Generating weekly report for $WEEK_ID"

# ─── Gather sprint context ──────────────────────────────────────────────────
SPRINT_ID=$(jira_get_active_sprint_id 2>/dev/null || echo "")
SPRINT_CONTEXT=""

if [[ -n "$SPRINT_ID" ]]; then
  # Get sprint tickets status
  DONE_COUNT=$(jira_search_keys "project = ${JIRA_PROJECT} AND labels = 'sprint-active' AND statusCategory = 'Done'" "50" 2>/dev/null | wc -l || echo 0)
  TOTAL_COUNT=$(jira_search_keys "project = ${JIRA_PROJECT} AND labels = 'sprint-active'" "50" 2>/dev/null | wc -l || echo 0)
  BLOCKED_COUNT=$(jira_search_keys "project = ${JIRA_PROJECT} AND labels = 'sprint-active' AND labels IN ('blocked','needs-human-review')" "50" 2>/dev/null | wc -l || echo 0)
  IN_PROGRESS=$(jira_search_keys_with_summaries "project = ${JIRA_PROJECT} AND labels = 'sprint-active' AND statusCategory != 'Done'" "20" 2>/dev/null || echo "None")

  SPRINT_CONTEXT="Sprint Progress: ${DONE_COUNT}/${TOTAL_COUNT} tickets done, ${BLOCKED_COUNT} blocked.
In-progress tickets:
${IN_PROGRESS}"
fi

# ─── Get latest daily report for context ─────────────────────────────────────
LATEST_DAILY=$(cat /tmp/${PROJECT_PREFIX}-layla-latest-report.md 2>/dev/null || echo "No recent daily report available.")

# ─── Get Hedi's recent messages ─────────────────────────────────────────────
HEDI_MESSAGES=$(get_hedi_messages 2>/dev/null || echo "No recent messages from Hedi.")

# ─── Get recent activity logs ───────────────────────────────────────────────
RECENT_ACTIVITY=$(tail -50 /opt/bisb/n8n/logs/activity.log 2>/dev/null || echo "No activity logs.")

# ─── Generate weekly report ──────────────────────────────────────────────────
MARKET_ROLE=$(cat "${SCRIPT_DIR}/../ai/product-marketing.md" 2>/dev/null || echo "You are Layla, Product & Market Strategist for BISB.")

WEEKLY_REPORT=$(claude -p --model sonnet --max-turns 15 --allowedTools "WebSearch WebFetch" "
${MARKET_ROLE}

Generate a WEEKLY REPORT for the BISB (Business is Business) digital board game project.
Today is $(date -u +%Y-%m-%d), Week ${WEEK_ID}.

BISB is a digital implementation of a Tunisian board game by Zied Remadi, featuring:
- Property trading, stock market, auctions, production chains
- Casinos, football clubs, tombola, gangsters
- TypeScript monorepo with game engine + React frontend
- Currently in alpha testing phase

=== SPRINT CONTEXT ===
${SPRINT_CONTEXT:-No active sprint data.}

=== LATEST DAILY REPORT ===
${LATEST_DAILY}

=== HEDI'S MESSAGES ===
${HEDI_MESSAGES}

=== RECENT AGENT ACTIVITY ===
${RECENT_ACTIVITY}

Write a comprehensive weekly report with TWO sections:

## 📊 Sprint Progress Report
- Sprint velocity and completion rate
- Key features completed this week
- Blocked tickets and bottlenecks
- Test coverage improvements
- Agent pipeline health (errors, retries, stuck tickets)
- Recommendations for next week's priorities

## 🎮 Board Game Market Intelligence
Use WebSearch to research the LATEST trends (February 2026):
- Digital board game market trends and player preferences
- Competitor updates (Monopoly GO, Catan Universe, Board Game Arena, Tabletopia)
- Mobile gaming monetization strategies relevant to board games
- MENA/Tunisian gaming market developments
- Opportunities for BISB differentiation

End with 3 actionable recommendations combining progress insights and market intelligence.

Keep total length under 3500 characters for Slack formatting.
")

if [[ -z "$WEEKLY_REPORT" ]]; then
  log_error "Claude returned empty weekly report"
  exit 1
fi

# ─── Post to Slack ───────────────────────────────────────────────────────────
# Truncate if needed
TRUNCATED_REPORT="${WEEKLY_REPORT:0:3800}"
if [[ ${#WEEKLY_REPORT} -gt 3800 ]]; then
  TRUNCATED_REPORT+="\n\n_[Report truncated — full version saved]_"
fi

slack_notify "layla" "📊 *BISB Weekly Report — Week ${WEEK_ID}*\n\n${TRUNCATED_REPORT}"

# ─── Save report ─────────────────────────────────────────────────────────────
echo "$WEEKLY_REPORT" > /tmp/${PROJECT_PREFIX}-layla-weekly-report.md
touch "$FLAG_FILE"

log_success "Weekly report generated and posted for $WEEK_ID"
log_activity "layla" "weekly-report" "weekly" "Generated weekly report for $WEEK_ID"
