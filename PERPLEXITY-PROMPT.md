# Perplexity Prompt: Multi-Agent AI Pipeline Gap Analysis

> Copy-paste this entire prompt into Perplexity Pro for a deep architecture review.

---

## Context: Our System

We run a **6-agent AI team** that autonomously builds a digital board game (TypeScript monorepo). The philosophy is **"Human-in-the-loop supervisor"** — agents run autonomously, the human (Hedi) reviews key decisions via Mattermost DMs and Slack notifications.

### Agent Roster

| Agent | Role | Primary Model | Triggers |
|-------|------|---------------|----------|
| **Salma** | Product Manager | Sonnet (Opus for splits) | Todo/Backlog tickets needing spec |
| **Youssef** | Developer | Sonnet (feedback-aware) | Ready tickets with spec |
| **Nadia** | QA Engineer | Sonnet (Opus for sensitive) | In Review tickets with open PR |
| **Rami** | Architect | Sonnet + Haiku | Architecture-review label |
| **Omar** | Ops/Supervisor | Haiku | Always-on health checks |
| **Layla** | Product Strategist | Dynamic | New feature ideation |

### Orchestration Stack

- **Pure bash scripts** (~15 files, ~5000 LOC total) on a single VPS (Ubuntu, 4GB RAM)
- **Cron-based dispatch** every 15 minutes (`agent-cron.sh` — 942 lines)
- **No frameworks**: no LangChain, no CrewAI, no n8n workflows — everything is bash + Claude CLI
- **Tracker**: Self-hosted Plane (Jira alternative) with REST API
- **Communication**: Mattermost (primary, per-agent bot accounts) + Slack (mirror)
- **AI**: Anthropic Claude CLI (`claude -p "prompt" --model sonnet`)
- **VCS**: GitHub (PRs, branches per ticket)

### Dispatch Engine (9 phases per cycle)

1. Git fetch + branch cleanup
2. Sync Plane states with local tracking
3. Process Salma (PM): find tickets in Todo/Backlog without spec
4. Process Youssef (Dev): find Ready tickets, create worktree, implement
5. Process Nadia (QA): find In Review tickets with open PR, review code
6. Process Rami (Architect): find tickets with architecture-review label
7. Process Layla (Product): find tickets needing ideation
8. Process Omar (Ops): health checks, stale locks, stale PRs, alerts
9. Ceremony dispatch (standup, retro, planning — time-based triggers)

### Ticket Lifecycle

```
Backlog → Todo → Ready → In Progress → In Review → Done → Merged
                                    ↓              ↓
                                 Blocked ←──── (failures)
                                    ↓
                              Needs Human
```

### Retry & Escalation

- Per-ticket retry counter (file-based: `/tmp/bisb-retry-TICKET-AGENT`)
- Max 3 retries per agent per ticket
- On max retry: hand off to Omar + blacklist ticket for 1 hour
- Timeout: 1800s per agent run (kills with SIGTERM)
- Blacklist: file-based with TTL cooldown, prevents re-dispatch of failing tickets

### Budget Enforcement

- 3-tier: warning at 53%, throttle at 80%, hard stop at 100%
- Model selection: Haiku for simple tasks, Sonnet for main work, Opus for critical decisions
- Rate limit fallback: when Sonnet hits 429, non-critical agents fall back to Haiku, critical agents wait

### Quality Gates (before merge)

- PR diff < 350 lines
- No secrets (.env, API keys)
- No console.log in production code
- TypeScript typecheck passes
- Tests pass
- Auto-revert on merge failure

### Ceremony System

| Ceremony | Schedule | Agent | Output |
|----------|----------|-------|--------|
| Daily Standup | 08:00 | Omar | Slack summary of yesterday's work |
| Sprint Review | Friday 17:00 | Omar | Week retrospective |
| Sprint Retro | Friday 18:00 | Layla+Salma | Process improvement proposals |
| Sprint Planning | Monday 08:00 | Salma | Sprint backlog selection |
| Refinement | Wed 14:00 | Salma+Layla | Ticket grooming |
| Blocker Triage | Every 6h | Omar | Unblock stuck tickets |

### Communication

- Each agent has its own Mattermost bot account (DMs with Hedi)
- Slack notifications for pipeline events (PR opened, ticket moved, errors)
- Plane comments for ticket-level discussion (agents comment on tickets)
- DM poller: checks Mattermost DMs every 2 minutes, routes to agent handler

### Data Persistence

- All state is file-based: `/tmp/bisb-*` (locks, retries, blacklist, flags)
- No database, no Redis, no persistent queue
- Logs: `/var/log/bisb/` (per-agent, per-day rotation)
- Git worktrees for parallel development (Youssef)

---

## Questions for Gap Analysis

Please analyze our architecture against industry best practices for multi-agent AI systems. For each question, explain what we're missing, why it matters, and give concrete implementation suggestions that fit our bash+cron stack (we want to stay lightweight — no Kubernetes, no heavy frameworks).

### 1. Circuit Breaker & Failure Isolation

We currently use a file-based blacklist with 1-hour TTL to prevent re-dispatching failing tickets. When an agent fails 3 times, we hand off to Omar and blacklist the ticket.

**What circuit breaker patterns are we missing?** Specifically:
- Should we have per-agent circuit breakers (not just per-ticket)?
- What about cascading failure detection (e.g., if Plane API is down, all agents fail)?
- How do production multi-agent systems handle "poison pill" tasks that always fail?

### 2. Observability & Structured Logging

We log to flat files (`/var/log/bisb/`) with timestamps and grep for errors. Omar does a daily health check scanning for stale locks and idle agents.

**What observability gaps exist?** Specifically:
- Should we add structured logging (JSON) for machine parsing?
- What metrics should we track? (token usage per agent, success rate, latency percentiles)
- Is there a lightweight tracing solution for bash-based pipelines?
- How do we detect performance degradation before it becomes a failure?

### 3. Retry & Backoff Strategy

We use a flat 3-retry limit with immediate retry on next dispatch cycle (15 min). No exponential backoff, no jitter, no dead letter queue.

**What retry patterns should we adopt?** Specifically:
- Exponential backoff with jitter for API rate limits vs. logic errors?
- Dead letter queue for tickets that exhaust all retries?
- Should retry strategy differ by failure type (timeout vs. bad output vs. API error)?
- How do production systems distinguish between transient and permanent failures?

### 4. Cost Optimization & Token Tracking

We have 3-tier budget enforcement and model selection based on task complexity. When Sonnet hits rate limits, non-critical agents fall back to Haiku.

**What cost optimization patterns are we missing?** Specifically:
- Per-agent token tracking and budgets (currently only global)?
- Prompt caching strategies (we rebuild prompts from scratch each run)?
- Should we cache Claude responses for idempotent operations (e.g., same PR review twice)?
- Token-per-feature tracking to measure ROI?
- Model routing optimization (when is Haiku "good enough" vs. when Sonnet is essential)?

### 5. Inter-Agent Communication & Knowledge Sharing

Agents communicate indirectly through Plane comments, ticket state changes, and Mattermost. There's no shared memory, no pub/sub, no event bus.

**What communication patterns are we missing?** Specifically:
- Should agents share a knowledge base (e.g., "Youssef learned this codebase pattern")?
- Pub/sub for real-time events (e.g., "Nadia rejected PR" → Youssef gets notified immediately)?
- Persistent memory across sessions (currently only per-ticket brief files in `/tmp/`)?
- How do production multi-agent systems avoid duplicate work?

### 6. Security & Isolation

All agents run as the same Linux user, share the same git repo, and have access to all environment variables (API tokens for all services).

**What security gaps exist?** Specifically:
- Should each agent have its own API token scope?
- File system isolation between agents?
- Should we sandbox Claude CLI execution?
- How do we prevent one agent's failure from corrupting shared state (git repo)?

### 7. Scaling Decision: Bash+Cron vs. Workflow Engine

We chose bash+cron over n8n/Temporal/Prefect for simplicity. The system is ~5000 LOC of bash across 15 files.

**When should we migrate to a workflow engine?** Specifically:
- What complexity thresholds indicate bash is no longer appropriate?
- Is there a lightweight middle ground between bash scripts and full workflow engines?
- What would we gain from n8n/Temporal that bash can't provide (beyond visual debugging)?
- Can we add workflow-engine features (DAGs, dependency tracking) to bash incrementally?

### 8. Human-in-the-Loop Best Practices

Hedi reviews key decisions via Mattermost DMs. Agents can escalate to "Needs Human" state. There's no confidence scoring or approval workflow.

**What HITL patterns should we add?** Specifically:
- Confidence scoring: should agents output a confidence level and auto-escalate below threshold?
- Approval workflows: should certain actions (merge, deploy, delete) require explicit human approval?
- Feedback loops: how should human corrections improve future agent behavior?
- Attention management: how to prioritize which decisions need human attention most urgently?

### 9. Pipeline Self-Testing & Reliability

We have no tests for the pipeline itself. If a script change breaks dispatch logic, we discover it when agents stop working.

**How should we test the pipeline?** Specifically:
- Integration tests for the dispatch cycle (mock Plane API, mock Claude CLI)?
- Regression tests when modifying agent scripts?
- Canary deployments for script changes?
- Dry-run mode for the full pipeline?
- How do production multi-agent systems validate their orchestration layer?

### 10. Missing Architectural Patterns

Looking at our overall architecture, what patterns are we completely missing that production multi-agent systems use?

Consider:
- **Idempotency**: Our dispatch is not idempotent — running the same cycle twice can produce duplicate work
- **Event sourcing**: We don't have an event log of all agent actions
- **Self-reflection**: Agents don't evaluate their own output quality
- **Graceful degradation**: If one agent is down, the whole pipeline section stops
- **Versioning**: No way to A/B test different agent prompts
- **Rollback**: No way to undo an agent's changes beyond git revert
- **Rate limiting per agent**: Global rate limit, not per-agent quotas
- **Priority queues**: All tickets are processed in the order they appear, no urgency-based ordering
- **Dependency tracking**: No way to express "ticket B depends on ticket A being done first"

**What else are we missing? What are the most impactful patterns we should add first, given our constraint of staying lightweight (bash+cron, single VPS, no heavy infrastructure)?**

---

## Important Constraints

- **Stay lightweight**: We're a solo developer + AI agents. No DevOps team to maintain Kubernetes.
- **Single VPS**: 4GB RAM, shared with Plane + Mattermost + the app itself.
- **Bash preference**: We like the simplicity and debuggability of bash. Suggest bash-compatible solutions when possible.
- **Budget-conscious**: Every suggestion should consider token cost impact.
- **Pragmatic**: We want 80/20 improvements — the 20% effort that gives 80% benefit.

Please prioritize your recommendations by **impact vs. effort**, and for each suggestion, estimate whether it's a "quick win" (< 1 day), "medium effort" (1-3 days), or "major project" (1+ week).
