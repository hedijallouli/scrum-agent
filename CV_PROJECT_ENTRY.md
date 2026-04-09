# Scrum Agent — CV Project Entry

## Short Version (1 paragraph)

Built an autonomous AI development team framework that orchestrates 6 specialized AI agents (PM, Developer, QA, Architect, Strategist, Ops) running real Scrum ceremonies on any codebase. Entirely written in pure Bash (16,800+ lines) with zero frameworks — just shell scripts, the Claude API, and a cron job. Includes production-grade reliability (circuit breakers, crash recovery, event sourcing, graceful degradation, self-healing watchdog) and cost governance with per-agent budgets. Runs on a single VPS for ~$5/month.

---

## Full Version

**Scrum Agent** — Autonomous AI Development Team Framework
*Personal Project | Open Source (MIT)*

Designed and built an autonomous AI development team framework that orchestrates 6 specialized AI agents running real Scrum ceremonies on any codebase. The system is entirely built in pure Bash (16,800+ lines), with zero external frameworks — only shell scripts, the Claude API, and a cron job.

**Key highlights:**

- Architected a team of 6 AI agents (Product Manager, Developer, QA, Architect, Product Strategist, Ops), each with distinct personas, responsibilities, and domain expertise defined in Markdown
- Built a fully automated Scrum workflow: agents self-onboard (Sprint 0), pick up tickets, write specs, implement code, review PRs, make architecture decisions, and deploy — running autonomously every 15 minutes via cron
- Engineered production-grade reliability: circuit breakers, exponential backoff, idempotent crash recovery, event sourcing (append-only JSONL audit trail), 4-level graceful degradation, hourly self-healing watchdog, and SLO monitoring
- Implemented cost governance with per-agent budgets and 3-tier throttling (warning/throttle/hard-stop)
- Integrated with Plane (project tracking), Mattermost (team chat), and GitHub for end-to-end pipeline automation
- Runs on minimal infrastructure: a single VPS (~$5/month) with ~$3-5/day in API costs

**Tech:** Bash, Claude API (Anthropic), Git (worktrees), Python, Plane API, Mattermost API, cron

---

## Skills to Highlight

- AI/LLM orchestration and prompt engineering
- Systems architecture and distributed systems design
- Shell scripting and Unix systems programming
- DevOps, CI/CD, and infrastructure automation
- Agile/Scrum methodology
- API integration (REST APIs, webhooks)
- Reliability engineering (circuit breakers, graceful degradation, observability)
