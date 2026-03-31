# Scrum Agent

> Hire a team of 6 AI agents. They onboard themselves.

An autonomous AI development team that runs real Scrum on your project. Pure Bash, zero frameworks, no orchestration platform -- just shell scripts, `claude`, and a cron job. Point it at any codebase and the agents will research your project, write their own domain context, and start shipping tickets.

Battle-tested: **16,800+ lines of Bash**, used on production projects.

---

## The Team

| Agent | Role | Personality | What they do |
|-------|------|-------------|--------------|
| **Salma** | Product Manager | Organized, empathetic | Writes specs, grooms backlog, decomposes tickets |
| **Youssef** | Developer | Perfectionist, humble | Implements features, creates PRs (max 300 lines) |
| **Nadia** | QA Engineer | Meticulous, direct | Reviews PRs, PASS/FAIL verdicts, regression testing |
| **Rami** | Architect | Pragmatic, mentor | Architecture reviews, schema design, tech decisions |
| **Layla** | Product Strategist | Visionary, user-centered | Brand research, UX principles, competitive analysis |
| **Omar** | Operations | Vigilant, methodical | Watchdog, deploys, unblocks, incident response |

Each agent has a distinct personality, communication style, and domain expertise -- defined in Markdown persona files under `agents/`.

---

## How It Works

### 1. Setup (5 minutes)

Run the interactive wizard. It creates your Plane project, Mattermost channels, and config files.

```bash
./scripts/init-project.sh
```

What gets created:
- Plane project with 11 workflow states (Backlog through Cancelled)
- 4 Mattermost channels (pipeline, standup, dev, escalation)
- `.agent-config.json` -- project configuration
- `.env.agents` -- secrets and IDs for VPS deployment
- `docs/project-context.md` -- you fill this with domain knowledge

### 2. Sprint 0 -- The team learns your project

```bash
./scripts/sprint-zero.sh
```

Each agent researches your codebase and writes their own project-specific persona. They run sequentially because each builds on the previous agent's output:

```
Layla (Opus)    -- brand, audience, competitors     --> ai/product.md
    |
Salma (Opus)    -- brief, glossary, roadmap         --> ai/pm.md
    |
Rami  (Opus)    -- architecture, schema, patterns   --> ai/architect.md
    |
Youssef (Sonnet) -- dev rules, code conventions     --> ai/dev.md
    |
Nadia (Sonnet)  -- QA strategy, test plans          --> ai/qa.md
    |
Omar  (Haiku)   -- monitoring, deploy procedures    --> ai/ops.md
```

Output: a `sprint-0/onboarding` branch with 6+ commits. Review, merge, and the team is ready.

Expected runtime: 10-20 minutes.

### 3. Sprint 1+ -- They build

A cron job runs `agent-cron.sh` every 15 minutes. The dispatcher:

```
cron (every 15 min)
  |
  +-- Check messages from human (Slack/Mattermost)
  +-- Enforce daily cost budget
  +-- Escalate "Needs Human" tickets
  |
  +-- Dispatch agents in parallel:
  |     Salma  --> picks up unassigned Todo tickets, writes specs
  |     Youssef --> picks up Ready tickets, creates branches + PRs
  |     Nadia  --> picks up In Review tickets, reviews PRs
  |     Rami   --> architecture reviews, merge decisions
  |     Omar   --> blocked tickets, health checks, deploys
  |     Layla  --> product feedback, weekly reports
  |
  +-- Wait for all agents to finish
  +-- Run ceremony checks (standup, retro, planning)
```

Each agent works independently with its own lock file. Youssef uses git worktrees for parallel ticket work (WIP limit: 2).

---

## Architecture

```
scrum-agent/
  |
  +-- agents/              # Generic persona templates (role definitions)
  |     pm.md, dev.md, qa.md, architect.md, product-marketing.md, ops.md
  |
  +-- scripts/
        +-- init-project.sh          # One-time project setup wizard
        +-- sprint-zero.sh           # Agent onboarding (generates ai/*.md)
        +-- agent-cron.sh            # Main dispatcher (runs every 15 min)
        +-- run-agent.sh             # Single agent runner with full reliability
        |
        +-- agent-salma.sh           # PM: spec writing, backlog grooming
        +-- agent-youssef.sh         # Dev: implementation, PRs
        +-- agent-nadia.sh           # QA: PR review, verdicts
        +-- agent-rami.sh            # Architect: reviews, merges
        +-- agent-layla.sh           # Product: UX, weekly reports
        +-- agent-omar.sh            # Ops: deploys, unblocking
        |
        +-- agent-common.sh          # Shared utilities (2,750 lines)
        +-- tracker-common.sh        # Plane/Jira API abstraction
        +-- ceremony-*.sh            # Standup, planning, retro, review
        |
        +-- event-log.sh             # Event sourcing (append-only JSONL)
        +-- idempotency-common.sh    # Exactly-once execution
        +-- degrade.sh               # Graceful degradation (4 levels)
        +-- pipeline-slo.sh          # SLO monitoring + synthetic canary
        +-- watchdog.sh              # Self-healing hourly watchdog
```

Your project gets an `ai/` directory with project-specific persona files (generated by Sprint 0) and a `.agent-config.json` with all the wiring.

---

## Reliability

This is production infrastructure, not a demo. Every failure mode we hit is handled.

| Mechanism | What it does |
|-----------|-------------|
| **Circuit breakers** | Per-agent. 3 consecutive failures = open. Auto-resets after cooldown. |
| **Exponential backoff** | Failed tickets get increasing retry delays. No retry storms. |
| **Idempotency** | Run journal with step tracking. Crash mid-PR? Resumes from last step. |
| **Event sourcing** | Every action logged to append-only JSONL. Full audit trail per ticket. |
| **Graceful degradation** | 4 levels: Normal, Degraded (non-critical paused), Minimal (only dev+QA), Emergency (all stop). |
| **Watchdog** | Hourly self-healing: stale locks, orphan processes, disk space, memory pressure. |
| **SLO monitoring** | Retry storms, circuit breaker flapping, queue age, success rate, API canary. |
| **Cost budgets** | Daily call limits with warning/throttle/hard-stop thresholds per agent. |
| **Poison pill detection** | Tickets that fail 3x get blacklisted with cooldown. |
| **Work-hours enforcement** | Agents only run Mon-Fri 09:00-21:00 (configurable timezone). |

---

## Quick Start

```bash
# 1. Add as a submodule to your project
cd your-project
git submodule add <scrum-agent-repo-url> scrum-agent

# 2. Run the setup wizard
./scrum-agent/scripts/init-project.sh

# 3. Fill in your domain knowledge
$EDITOR docs/project-context.md

# 4. Run Sprint 0 (agents onboard themselves)
./scrum-agent/scripts/sprint-zero.sh

# 5. Review and merge the onboarding branch
git checkout main && git merge sprint-0/onboarding

# 6. Deploy to VPS and set up cron
scp .env.agents root@your-server:/etc/bisb/.env.agents
# On server: crontab -e
# */15 9-21 * * 1-5  /path/to/scripts/agent-cron.sh >> /var/log/bisb/cron.log 2>&1
# 0 * * * *          /path/to/scripts/watchdog.sh >> /var/log/bisb/watchdog.log 2>&1
```

---

## Requirements

| Dependency | Version | Notes |
|------------|---------|-------|
| Bash | 4.0+ | Uses associative arrays, `set -euo pipefail` |
| Claude Code CLI | latest | `npm install -g @anthropic-ai/claude-code` |
| Plane | self-hosted | Project tracker. Free, open source. |
| Mattermost | self-hosted | Team chat. Free, open source. |
| Git | 2.20+ | Worktrees for parallel dev work |
| curl, jq, python3 | any recent | API calls, JSON parsing |
| VPS | 2+ GB RAM | Runs agents, Plane, Mattermost |

---

## Cost

| Component | Cost |
|-----------|------|
| Plane | Free (self-hosted) |
| Mattermost | Free (self-hosted) |
| VPS (Hetzner, etc.) | ~$5/month |
| Claude API | ~$3-5/day (budget-controlled) |

Daily API spend is capped by `cost_budget_daily_calls` in your config. The system enforces three thresholds: warning (53%), throttle (80%, only merge + ops agents run), and hard stop (100%, only health checks).

---

## Scrum Ceremonies

All ceremonies are automated and run on schedule:

| Ceremony | Trigger | What happens |
|----------|---------|-------------|
| **Daily Standup** | Cron, morning | Each agent posts status to standup channel |
| **Sprint Planning** | After retro | Salma selects tickets, assigns agents, sets sprint goals |
| **Sprint Review** | Friday 15:00 UTC | Summarizes completed work, demos to channel |
| **Sprint Retro** | After review | Agents reflect on what worked, create improvement tickets |
| **Blocker Triage** | Auto (5+ blocked) | Omar convenes round-table to unblock or escalate |
| **Refinement** | Mid-sprint | Salma decomposes upcoming tickets with Rami |

---

## License

MIT
