# ChatGPT Prompt: Agent Reliability Layer Deep-Dive

> Paste this into ChatGPT (o3 or 4o) for a production-grade reliability review.
> Focus: the "Agent Reliability Layer" — the ~700 lines of bash that make the system 10x more stable.

---

## Context

I run a 6-agent AI team (Anthropic Claude CLI) that autonomously builds a digital board game. Pure bash + cron on a single VPS (4GB RAM). No frameworks.

### What We Already Have (just implemented)

We already built a reliability layer. **Don't re-suggest things we have.** Tell us what's STILL missing.

#### Already Done:
1. **Per-agent circuit breakers** — 5 failures in 10min → 15min lockout. File-based: `/tmp/bisb-circuit-breakers/{agent}.state`
2. **Dependency health flags** — `/tmp/bisb-dep-flags/{plane,claude,github}.down` with 5min TTL. All agents skip when a dep is down.
3. **Error classification** — 5 types: RATE_LIMIT, TRANSIENT, TIMEOUT, PERMANENT, BAD_OUTPUT. Each gets different handling.
4. **Exponential backoff with jitter** — 60s→240s→600s→1800s with ±30% randomness. PERMANENT errors never retry.
5. **Poison pill detection** — Ticket blacklisted 3+ times in 24h → auto-escalate to human.
6. **Structured logging (JSONL)** — `/var/log/bisb/structured.log` with run IDs, agent names, error types.
7. **Metrics JSONL** — Per-run: agent, ticket, duration, model, error_type, retry_count, success.
8. **Per-agent cost budgets** — Youssef 40%, Nadia 20%, Salma 15%, Rami 10%, Layla 10%, Omar 5%. Throttle at 150% share.
9. **Response caching** — 1h TTL for idempotent Claude calls. Cache keyed by agent+ticket+input_hash.
10. **Pre-PR guardrails** — 8 checks: secrets, dangerous ops, protected dirs, typecheck, tests, console.log, diff size, git fsck.
11. **Self-healing watchdog** — Hourly: stale locks, orphan processes, disk, memory, cron health. Auto-removes/kills/alerts.
12. **flock on dispatcher** — Prevents overlapping cron runs.
13. **Ceremony orchestrator** — Chains Review→Retro with state machine + agent pause.
14. **Cumulative ceremony conversations** — Each agent reads what prior speakers said (ported from our other project's n8n workflows).
15. **Actionable standup** — PM speaks last, outputs structured DECISION: blocks that execute ticket changes.
16. **Sonnet rate limit → Haiku fallback** — Non-critical agents fall back, critical agents wait.
17. **Dispatch blacklist** — 1h TTL cooldown prevents re-dispatching failing tickets.

### Architecture Snapshot

```
Cron (*/15 min) → flock → agent-cron.sh (dispatcher, 950 lines)
                                ↓
            Pre-flight checks per ticket:
            cb_is_open? → dep_is_down? → can_retry_now? → is_agent_over_budget?
                                ↓
            run-agent.sh → timeout 1800s → agent-{name}.sh
                                ↓
            On failure: classify_error() → record_failure_with_backoff()
                        → cb_record_failure() → log_metric() → log_json()
                                ↓
            3 failures: blacklist + handoff to Omar
            3 blacklists/24h: poison pill → Needs Human (Hedi)
```

**Stack**: Bash (~8500 LOC across 22 files), Claude CLI, Plane REST API, Mattermost, GitHub, Slack.
**State**: All file-based (`/tmp/bisb-*`, `/var/lib/bisb/`). No database, no Redis.
**VPS**: Ubuntu, 4GB RAM, single machine running everything.

---

## Questions — What Are We STILL Missing?

### Q1: Agent Self-Evaluation & Confidence Scoring

Our agents output code/specs/reviews but never evaluate their own confidence. Youssef doesn't know if his implementation is "90% correct" or "50% guess". Nadia doesn't know if her PASS verdict is "high confidence" or "borderline".

**Design a bash-compatible confidence scoring system** that:
- Lets agents output a confidence score (0-100) with their work
- Routes low-confidence work to additional review
- Tracks confidence vs actual outcomes to calibrate over time
- Stays lightweight (file-based, no ML training loops)

### Q2: Idempotency & Exactly-Once Execution

Our dispatch is NOT idempotent. If cron fires twice rapidly (flock should prevent this, but...), or if an agent crashes mid-work and the retry picks up the same ticket, we get duplicate PRs, duplicate comments, duplicate state changes.

**Design an idempotency layer** that:
- Guarantees exactly-once execution per ticket-agent-cycle
- Handles partial failures (agent created branch but didn't create PR)
- Recovers gracefully from mid-execution crashes
- Uses only file-based state

### Q3: Event Sourcing Lite

We log metrics and structured events, but we don't have an immutable action log. If we want to answer "what happened to BISB-47 between 3pm and 5pm yesterday?", we'd have to grep multiple log files.

**Design a lightweight event sourcing system** for bash that:
- Records every meaningful action as an immutable event
- Supports replay/query of ticket history
- Enables "what happened" debugging
- Stays under 100 lines of bash

### Q4: Priority Queue with Dependency Tracking

All tickets are dispatched in Plane API order. There's no concept of "BISB-47 is urgent" or "BISB-52 depends on BISB-47".

**Design a priority/dependency system** that:
- Supports priority levels (urgent, normal, low)
- Blocks dispatch of dependent tickets until prerequisites are done
- Handles circular dependency detection
- Uses file-based state

### Q5: Prompt Versioning & A/B Testing

We can't test if a new prompt version produces better results. If Salma's enrichment prompt is updated, we have no way to compare old vs new output quality.

**Design a prompt versioning system** that:
- Versions agent prompts (v1, v2, v3...)
- Runs A/B tests (50% traffic to each version)
- Measures output quality (QA pass rate, human satisfaction)
- Rolls back automatically if new version is worse
- Works within our bash + file-based architecture

### Q6: Graceful Degradation Hierarchy

Currently, if one agent is broken, its entire phase stops. If Youssef's circuit breaker opens, no Ready tickets get processed.

**Design a degradation hierarchy** that:
- Defines fallback behaviors per agent (e.g., if Youssef down → park ticket for next cycle vs. assign to Rami)
- Handles "cascade failure" scenarios (Plane down → all agents skip)
- Provides different degradation levels (reduced capacity vs. full stop)
- Alerts at each degradation level

### Q7: The "Agent Reliability Layer" (700 lines)

You mentioned knowing how to design a ~700 line bash architecture that makes autonomous AI systems 10x more stable. We've already built about half of it (see "Already Done" above).

**What are the remaining components we're missing?** Specifically:
- What reliability patterns do production autonomous AI teams use that we haven't implemented?
- What failure modes will emerge at scale (100+ tickets, 10+ concurrent agents) that our current system doesn't handle?
- What monitoring/alerting patterns should we add before something goes wrong?

### Q8: Security Isolation Without Containers

All our agents run as root, share the same git repo, and can access all API tokens. One rogue Claude output could theoretically `rm -rf /` or exfiltrate tokens.

**Design a security isolation strategy** that:
- Limits each agent's filesystem access
- Scopes API tokens per agent (not all tokens available to all agents)
- Sandboxes Claude CLI execution
- Prevents git corruption from concurrent agent work
- Doesn't require Docker/Kubernetes (we want to stay lightweight)

---

## Constraints

- **Must work in bash** — no Python frameworks, no Node.js orchestrators
- **File-based state only** — no database, no Redis, no message queue
- **Single VPS, 4GB RAM** — shared with Plane, Mattermost, and the app
- **Budget-conscious** — every token counts
- **Pragmatic** — 80/20 solutions. Quick wins over perfect architectures.

For each answer:
1. Show the **bash implementation** (actual code, not pseudocode)
2. Estimate **lines of code** and **complexity**
3. Rate **impact vs effort** (1-5 scale each)
4. Flag any **gotchas or edge cases** specific to our architecture
