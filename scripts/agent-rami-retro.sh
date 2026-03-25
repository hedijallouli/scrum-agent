#!/bin/bash
set -euo pipefail

# ─── BISB Rami Retro-Action Agent ──────────────────────────────────────────
# Writes architecture perspective on retro-action tickets

AGENT_NAME="rami-retro"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/agent-common.sh"

TICKET_KEY="${1:?Usage: agent-rami-retro.sh TICKET_KEY}"
init_log "$AGENT_NAME" "$TICKET_KEY"
log_info "Rami retro-action starting for $TICKET_KEY"

# ─── Fetch ticket details ───────────────────────────────────────────────────
TICKET_JSON=$(jira_get_ticket "$TICKET_KEY")
SUMMARY=$(echo "$TICKET_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['fields']['summary'])" 2>/dev/null)
DESCRIPTION=$(jira_get_description_text "$TICKET_KEY")
COMMENTS=$(jira_get_comments "$TICKET_KEY")

log_info "Ticket: $SUMMARY"

# ─── Generate architecture perspective ───────────────────────────────────────
ARCH_ROLE=$(cat "${SCRIPT_DIR}/../ai/architect.md" 2>/dev/null || echo "You are Rami, the Technical Architect.")

CLAUDE_OUTPUT=$(claude -p --model haiku --max-turns 1  "
${ARCH_ROLE}

You are writing an ARCHITECTURE PERSPECTIVE comment for a retro-action ticket.
This is a digital board game project (Business is Business - BISB) built with:
- TypeScript monorepo (packages/engine + packages/web)
- Game engine: framework-agnostic, command pattern, event sourcing
- Frontend: React 19 + Vite + TailwindCSS + Zustand
- Testing: Vitest

TICKET: $TICKET_KEY
SUMMARY: $SUMMARY
DESCRIPTION:
$DESCRIPTION

EXISTING COMMENTS:
${COMMENTS:-None}

Write a concise architecture perspective (max 300 words) covering:
1. **Codebase Impact**: Which packages/systems does this affect?
2. **Technical Debt**: Does this introduce or resolve technical debt?
3. **Design Patterns**: Recommended patterns (ECS, Command, Event Sourcing)
4. **Reusability**: Code reuse opportunities across engine/web packages
5. **Architecture Acceptance Criteria**: 2-3 bullet points

Format as a clean comment. Start with '🏗️ **Architecture Perspective**' header.
Do NOT include any VERDICT.
")

if [[ -z "$CLAUDE_OUTPUT" ]]; then
  log_error "Claude returned empty output"
  exit 1
fi

# ─── Post comment and route to Salma ─────────────────────────────────────────
jira_add_rich_comment "$TICKET_KEY" "$CLAUDE_OUTPUT" "rami"
log_info "Posted architecture perspective comment"

jira_update_labels "$TICKET_KEY" "agent:rami" "agent:salma"
log_info "Routed to Salma"

slack_notify "rami" "📋 Rami posted architecture perspective on $TICKET_KEY ($SUMMARY), routing to Salma"
log_activity "rami" "retro-perspective" "$TICKET_KEY" "Posted architecture perspective, routed to Salma"

log_success "Rami retro-action complete for $TICKET_KEY"
