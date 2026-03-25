#!/bin/bash
set -euo pipefail

# ─── BISB Omar Retro-Action Agent ──────────────────────────────────────────
# Writes ops/monitoring perspective on retro-action tickets
# Pattern: Haiku, 1 turn, no tools → comment → hand to Salma

AGENT_NAME="rami-retro"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/agent-common.sh"

TICKET_KEY="${1:?Usage: agent-omar-retro.sh TICKET_KEY}"
init_log "$AGENT_NAME" "$TICKET_KEY"
log_info "Omar retro-action starting for $TICKET_KEY"

# ─── Fetch ticket details ───────────────────────────────────────────────────
TICKET_JSON=$(jira_get_ticket "$TICKET_KEY")
SUMMARY=$(echo "$TICKET_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['fields']['summary'])" 2>/dev/null)
DESCRIPTION=$(jira_get_description_text "$TICKET_KEY")
COMMENTS=$(jira_get_comments "$TICKET_KEY")

log_info "Ticket: $SUMMARY"

# ─── Generate ops perspective ────────────────────────────────────────────────
OPS_ROLE=$(cat "${SCRIPT_DIR}/../ai/ops.md" 2>/dev/null || echo "You are Omar, the Ops & Monitoring specialist.")

CLAUDE_OUTPUT=$(claude -p --model haiku --max-turns 1  "
${OPS_ROLE}

You are writing an OPS/MONITORING PERSPECTIVE comment for a retro-action ticket.
This ticket was created during a sprint retrospective to capture an improvement area.

TICKET: $TICKET_KEY
SUMMARY: $SUMMARY
DESCRIPTION:
$DESCRIPTION

EXISTING COMMENTS:
${COMMENTS:-None}

Write a concise ops perspective (max 300 words) covering:
1. **Pipeline Impact**: How does this affect the CI/CD pipeline and monitoring?
2. **Observability**: What metrics, logs, or alerts should be added or improved?
3. **Automated Checks**: Should new health checks be added to the agent pipeline?
4. **Detection Criteria**: How would we detect regressions related to this issue?
5. **Ops Acceptance Criteria**: 2-3 bullet points for ops validation

Format as a clean comment. Start with '🔧 **Ops Perspective**' header.
Do NOT include any VERDICT.
")

if [[ -z "$CLAUDE_OUTPUT" ]]; then
  log_error "Claude returned empty output"
  exit 1
fi

# ─── Post comment and route to Salma ─────────────────────────────────────────
jira_add_rich_comment "$TICKET_KEY" "$CLAUDE_OUTPUT" "omar"
log_info "Posted ops perspective comment"

# Route to Salma for spec writing
jira_update_labels "$TICKET_KEY" "agent:omar" "agent:salma"
log_info "Routed to Salma"

# Notify
slack_notify "omar" "📋 Omar posted ops perspective on $TICKET_KEY ($SUMMARY), routing to Salma"
log_activity "omar" "retro-perspective" "$TICKET_KEY" "Posted ops perspective, routed to Salma"

log_success "Omar retro-action complete for $TICKET_KEY"
