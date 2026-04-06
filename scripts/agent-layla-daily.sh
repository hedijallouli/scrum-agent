#!/usr/bin/env bash
# =============================================================================
# agent-layla-daily.sh — Daily market intelligence report
# Runs once per day (first cron cycle). No ticket — independent research.
# =============================================================================
AGENT_NAME="layla"
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/agent-common.sh"

init_log "daily-report" "layla"
log_info "=== Layla (Product Strategist) starting daily market intelligence ==="

DAILY_FLAG="/tmp/${PROJECT_PREFIX}-layla-daily-$(date +%Y-%m-%d)"

# Already ran today
if [[ -f "$DAILY_FLAG" ]]; then
  log_info "Daily report already generated today. Skipping."
  exit 0
fi

# ─── 1. Gather sprint context ────────────────────────────────────────────────
if [[ "${TRACKER_BACKEND:-jira}" == "plane" ]]; then
  _cycle_id=$(plane_get_current_cycle_id 2>/dev/null || echo "")
  if [[ -n "$_cycle_id" ]]; then
    SPRINT_TICKETS=$(plane_get_cycle_issues "$_cycle_id" 2>/dev/null || true)
  else
    SPRINT_TICKETS=""
  fi
else
  SPRINT_TICKETS=$(jira_search_keys_with_summaries "project = ${JIRA_PROJECT} AND labels = 'sprint-active' AND statusCategory != 'Done'" "20" 2>/dev/null || true)
fi

SPRINT_CONTEXT=""
if [[ -n "$SPRINT_TICKETS" ]]; then
  SPRINT_CONTEXT="CURRENT SPRINT TICKETS:
${SPRINT_TICKETS}"
fi

# ─── 1b. Rotating daily focus ─────────────────────────────────────────────────
# Project-specific focus topics via env vars (LAYLA_FOCUS_1..5).
# Falls back to BISB/gaming defaults if not set.
DOW=$(date +%u)  # 1=Mon ... 7=Sun
case "$DOW" in
  1) DAY_FOCUS="${LAYLA_FOCUS_1:-Competitors deep-dive (BGA, Monopoly GO, Tabletop Sim updates)}" ;;
  2) DAY_FOCUS="${LAYLA_FOCUS_2:-UX/UI trends (onboarding, mobile-first, accessibility)}" ;;
  3) DAY_FOCUS="${LAYLA_FOCUS_3:-Monetization models (freemium, cosmetics, battle passes, regional pricing)}" ;;
  4) DAY_FOCUS="${LAYLA_FOCUS_4:-Tunisian/MENA gaming market (local trends, Arabic localization, regional launches)}" ;;
  5) DAY_FOCUS="${LAYLA_FOCUS_5:-Tech & multiplayer (WebSocket patterns, matchmaking, cross-platform play)}" ;;
  6) DAY_FOCUS="${LAYLA_FOCUS_6:-Weekend: player community trends and social features}" ;;
  7) DAY_FOCUS="${LAYLA_FOCUS_7:-Weekend: product roadmap review and backlog refinement}" ;;
  *) DAY_FOCUS="General market scan" ;;
esac
log_info "Today's focus: $DAY_FOCUS"

# ─── 1c. Load previous reports to avoid repetition ───────────────────────────
PREV_REPORTS=""
if [[ -f /tmp/${PROJECT_PREFIX}-layla-latest-report.md ]]; then
  PREV_DATE=$(cat /tmp/${PROJECT_PREFIX}-layla-latest-report-date.txt 2>/dev/null || echo "unknown")
  PREV_SUMMARY=$(head -30 /tmp/${PROJECT_PREFIX}-layla-latest-report.md 2>/dev/null | grep "^##" || true)
  PREV_REPORTS="YOUR PREVIOUS REPORT (${PREV_DATE}) COVERED:
${PREV_SUMMARY}

IMPORTANT: Do NOT repeat the same insights. Find NEW information today."
fi

# ─── 2. Generate market intelligence report ──────────────────────────────────
log_info "Invoking Claude (sonnet) for market intelligence..."

# Persona file: project-specific override or default
PERSONA_FILE="${LAYLA_PERSONA_FILE:-ai/product-marketing.md}"

# Research areas: load from file if present, else env var, else BISB/gaming default
RESEARCH_AREAS_FILE="${PROJECT_DIR}/ai/layla-daily-research.md"
if [[ -f "$RESEARCH_AREAS_FILE" ]]; then
  RESEARCH_AREAS=$(cat "$RESEARCH_AREAS_FILE")
else
  RESEARCH_AREAS="${LAYLA_RESEARCH_AREAS:-a) Digital board game market trends (mobile + web platforms)
   b) Competitor updates (Board Game Arena new games, Tabletop Simulator community, Monopoly GO updates)
   c) Mobile board game monetization models (free-to-play, premium, ad-supported)
   d) MENA region gaming audience trends and Arabic/French game localization
   e) Board game digitization best practices and player engagement patterns
   f) Tunisian gaming market and local developer ecosystem
   g) Hybrid board/digital game innovations (companion apps, AR/NFC interaction)
   h) Mobile-first board game UX patterns (touch gestures, offline play, quick sessions)
   i) Multiplayer matchmaking trends (skill-based, casual, async turn-based)}"
fi

# Report sections: load from file if present, else BISB/gaming default
REPORT_SECTIONS_FILE="${PROJECT_DIR}/ai/layla-daily-sections.md"
if [[ -f "$REPORT_SECTIONS_FILE" ]]; then
  REPORT_SECTIONS=$(cat "$REPORT_SECTIONS_FILE")
else
  REPORT_SECTIONS="## Digital Board Game Trends
[New launches, market shifts, or nothing notable]

## Competitor Watch
[Board Game Arena, Tabletop Simulator, Monopoly GO, Catan Universe, Ludo King — any updates]

## Player Experience Insights
[UX patterns, onboarding best practices, mobile optimization trends]

## Monetization & Distribution
[App store trends, pricing models, Tunisian market considerations]"
fi

REPORT_PROMPT="You are Layla, the Product Strategist for ${PROJECT_NAME} (${PROJECT_KEY}).
Read your persona file (${PERSONA_FILE}) for full project context.
Today is $(date +%Y-%m-%d).

YOUR TASK — DAILY PRODUCT INTELLIGENCE REPORT:
1. Use WebSearch to research:
   ${RESEARCH_AREAS}

2. Produce a concise daily report:

## Daily Focus: ${DAY_FOCUS}
[Deep dive into today's rotating topic]

${REPORT_SECTIONS}

## Recommendations for Sprint
[Any features the team should prioritize or de-prioritize based on today's findings]

${SPRINT_CONTEXT}

TODAY'S ROTATING FOCUS: ${DAY_FOCUS}
Spend extra research effort on today's focus topic. Provide deeper insights in the Daily Focus section.

${PREV_REPORTS}

If your research reveals that any current sprint tickets are heading in the wrong direction,
add a ## SPRINT CONCERNS section listing the affected ticket keys and WHY.

Keep the report concise (300-500 words). Focus on ACTIONABLE intelligence.
Output ONLY the report — no preamble."

PROMPT_FILE=$(mktemp /tmp/layla-daily-XXXXXX.txt)
echo "$REPORT_PROMPT" > "$PROMPT_FILE"

REPORT_OUTPUT=$(cd "$PROJECT_DIR" && claude -p - \
  --allowedTools "WebSearch WebFetch" \
  --model sonnet --max-turns 10 \
  < "$PROMPT_FILE" 2>/dev/null) || true
rm -f "$PROMPT_FILE"

log_info "Report output:"
echo "$REPORT_OUTPUT" >> "$LOG_FILE"

# ─── 3. Post to Slack ────────────────────────────────────────────────────────
if [[ -n "$REPORT_OUTPUT" && ${#REPORT_OUTPUT} -gt 50 ]]; then
  # Truncate for Slack (4000 char limit)
  REPORT_SLACK="${REPORT_OUTPUT:0:3800}"

  # Check for sprint concerns — post with danger color if found
  if echo "$REPORT_OUTPUT" | grep -qi "SPRINT CONCERNS\|PIVOT"; then
    slack_notify "Daily Market Intelligence ($(date +%Y-%m-%d))

${REPORT_SLACK}" "pipeline" "danger"
    log_info "Report posted with SPRINT CONCERNS flag"
  else
    slack_notify "Daily Market Intelligence ($(date +%Y-%m-%d))

${REPORT_SLACK}" "pipeline" "good"
    log_info "Report posted to Slack"
  fi

  # Save report to file for other agents to consume
  echo "$REPORT_OUTPUT" > /tmp/${PROJECT_PREFIX}-layla-latest-report.md
  echo "$(date -u +%Y-%m-%d)" > /tmp/${PROJECT_PREFIX}-layla-latest-report-date.txt
  log_info "Report saved to /tmp/${PROJECT_PREFIX}-layla-latest-report.md"

  touch "$DAILY_FLAG"
  log_activity "layla" "DAILY" "REPORT" "Daily market intelligence posted"
  log_success "=== Layla daily report complete ==="
else
  log_error "Report output too short or empty — skipping"
  # Don't touch flag — will retry on next cron cycle
fi
