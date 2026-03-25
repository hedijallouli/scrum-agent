# BisB AI Agent Architecture Audit

**Date**: 2026-02-24
**Auditor**: Senior AI Agent Architect
**Scope**: Full agent pipeline audit — scripts, prompts, configs, workflows

---

## 1. Executive Summary

The BisB agent pipeline was cloned from the SquareInvest project and **has not been adapted for the game project**. The `ai/*.md` role files in the repo are correctly adapted, but the VPS agent scripts (which contain the actual prompts, build commands, and workflow logic) are still running SquareInvest's investment platform code verbatim.

**Severity: CRITICAL** — The pipeline is non-functional for BisB in its current state.

### Top 3 Blockers

| # | Issue | Impact |
|---|-------|--------|
| 1 | `agent-cron.sh` has no ticket dispatch loop | No agent ever runs on a ticket |
| 2 | `BASE_BRANCH` defaults to `test` | BisB uses `master` — all git ops target wrong branch |
| 3 | All Claude prompts say "SquareInvest" with Supabase/Zod/bun stack | Agents would generate wrong code if they ran |

---

## 2. Repository Inventory

### 2.1 Local Repo (`ai/*.md` — Role Definitions)

| File | Agent | Status |
|------|-------|--------|
| `ai/pm.md` | Salma (PM) | Adapted for BisB |
| `ai/dev.md` | Youssef (Dev) | Adapted for BisB |
| `ai/qa.md` | Nadia (QA) | Adapted for BisB |
| `ai/architect.md` | Rami (Architect) | Adapted for BisB |
| `ai/product-marketing.md` | Layla (Product) | Adapted for BisB |
| `ai/devops.md` | Karim (DevOps) | Adapted for BisB |
| `ai/ops.md` | Omar (Ops) | Adapted for BisB |

These are correct but **most agent scripts ignore them**. Nadia explicitly runs with `--disallowedTools "Read Write Edit Glob Grep Bash"` so she can never read `ai/qa.md`. Karim makes zero Claude calls (pure automated checks). Only Salma and Rami actually read their `ai/*.md` files via Claude.

### 2.2 VPS Scripts (`/opt/bisb/n8n/scripts/`)

| Script | Size | Claude? | Status |
|--------|------|---------|--------|
| `agent-common.sh` | 46KB | No | NOT adapted — SquareInvest everywhere |
| `agent-cron.sh` | ~30 lines | No | BROKEN — no ticket dispatch |
| `agent-salma.sh` | ~26KB | Yes (Sonnet/Opus) | NOT adapted — investment prompts |
| `agent-youssef.sh` | ~24KB | Yes (Sonnet) | NOT adapted — bun, Supabase, wrong paths |
| `agent-nadia.sh` | ~27KB | Yes (Sonnet, 1 turn) | NOT adapted — Zod, Supabase, shadcn QA rules |
| `agent-karim.sh` | ~18KB | No (automated) | Partially works — generic security checks |
| `agent-omar.sh` | ~15KB | No (automated) | Mostly works — generic health checks |
| `agent-rami.sh` | ~11KB | Yes (Sonnet) | NOT adapted — Supabase architecture rules |
| `agent-layla.sh` | ~10KB | Yes (Sonnet) | NOT adapted — Tunisian real estate market |
| `agent-layla-daily.sh` | ~5KB | Yes (Sonnet) | NOT adapted — investment market research |

### 2.3 Configuration

| Config | Value | Correct? |
|--------|-------|----------|
| `JIRA_PROJECT` | `BISB` | Yes |
| `GITHUB_REPO` | `hedijallouli/businessIsbusiness` | Yes |
| `PROJECT_DIR` | `/opt/bisb` | Yes |
| `BASE_BRANCH` | `test` (default in agent-common.sh) | NO — should be `master` |
| `SLACK_CHANNEL_PIPELINE` | `C0AGNEP7XGW` (bisb-pipeline) | Yes |
| `SLACK_CHANNEL_STANDUP` | `C0AHJQQHLSU` (bisb-daily) | Yes |
| Lock prefix | `squareinvest-agent-*` | NO — should be `bisb-agent-*` |
| Co-author email | `youssef@squareinvest.ai` | NO — should be `youssef@bisb.ai` |

---

## 3. Critical Issue: `agent-cron.sh` Is Broken

The cron orchestrator runs:
```bash
for agent in omar salma layla rami youssef nadia karim; do
  bash "$SCRIPT" >> "${LOG_DIR}/agent-${agent}.log" 2>&1
done
```

But every ticket-based agent requires `$1` (ticket key):
```bash
TICKET_KEY="${1:?Usage: agent-salma.sh SCRUM-XX}"
```

Running without an argument causes immediate exit with "Usage:" error. **Only Omar works** (he's a health watchdog, no ticket key needed).

### Fix Required

Replace the naive loop with a Jira query dispatch:

```bash
# Omar runs without ticket (health check)
bash "${SCRIPTS_DIR}/agent-omar.sh" >> "${LOG_DIR}/agent-omar.log" 2>&1

# Ticket-based agents: query Jira for assigned tickets
for agent in salma layla rami youssef nadia karim; do
  TICKETS=$(curl -s -X POST \
    -H "Authorization: Basic $(echo -n "${JIRA_EMAIL}:${JIRA_API_TOKEN}" | base64)" \
    -H "Content-Type: application/json" \
    "${JIRA_BASE_URL}/rest/api/3/search/jql" \
    -d "{\"jql\":\"project=${JIRA_PROJECT} AND labels='agent:${agent}' AND statusCategory != 'Done'\",\"fields\":[\"key\"],\"maxResults\":5}" \
    | python3 -c "import sys,json; [print(i['key']) for i in json.load(sys.stdin).get('issues',[])]" 2>/dev/null)

  for ticket in $TICKETS; do
    echo "[$(date)] Running agent-${agent} on ${ticket}..."
    bash "${SCRIPTS_DIR}/agent-${agent}.sh" "$ticket" >> "${LOG_DIR}/agent-${agent}.log" 2>&1
  done
done
```

---

## 4. Agent-by-Agent Fit Analysis

### 4.1 Salma (PM) — KEEP, ADAPT PROMPTS

**What works**: Spec enrichment, split handling, retry logic, model selection, story point estimation, Jira workflow.

**What's wrong**:
- Claude prompt says "You are Salma, the PM agent for **SquareInvest**"
- References: Supabase, Zod, CMF/BVMT regulations, KYC, securities law
- Test Cases template mentions "Supabase errors, RLS rejections"
- Complexity check references "shadcn/ui components, TanStack Query, React Hook Form"
- Reads `ai/pm.md` (which IS adapted) but the hardcoded prompt overrides it

**Required changes**:
1. Replace all "SquareInvest" with "BisB (Business is Business)"
2. Remove investment/regulatory prompt sections
3. Replace tech stack references: Supabase → Vitest, Zod → TypeScript strict, bun → npm
4. Add game-specific context: "Reference game rules from `BisB/Regle du jeu BISB.pdf`"
5. Test Cases template: replace "Supabase errors, RLS rejections" with "game state corruption, invalid moves, turn flow interruption"

### 4.2 Youssef (Dev) — KEEP, ADAPT BUILD COMMANDS + PROMPTS

**What works**: Implementation flow, PR creation, feedback loops, diff size gates, branch management, screenshot capture.

**What's wrong**:
- 14x `bun` references (should be `npm`)
- `bun.lock` in git staging (should be `package-lock.json`)
- `git add -A -- src/` — BisB structure is `packages/`
- `git add -A -- public/ supabase/` — no supabase directory
- Claude prompt: "use Zod for validation", "Use shadcn/ui, TanStack Query, React Hook Form, Supabase"
- Allowed tools: `Bash(bun:*)` — should be `Bash(npm:*)`
- Co-author: `youssef@squareinvest.ai`
- PR body links to `squareinvest.atlassian.net` (correct since BISB project is there)
- DevOps review flags check for "Supabase Auth, RLS, permissions"

**Required changes**:
1. Replace all `bun` commands with `npm` equivalents
2. Fix git staging: `packages/` instead of `src/`, remove `supabase/`
3. Add: `git add -A -- packages/ 2>/dev/null || true`
4. Fix allowed tools: `Bash(npm:*)` instead of `Bash(bun:*)`
5. Replace Claude prompt tech stack section entirely
6. Fix co-author email
7. Remove Supabase DevOps review flags, add game-relevant ones

### 4.3 Nadia (QA) — KEEP, REWRITE QA CHECKLIST

**What works**: PR review flow, verdict parsing, AC verification counting, retry limits, feedback writing, sprint context injection, NEEDS_HUMAN_INPUT mechanism.

**What's wrong**: The entire QA checklist is SquareInvest-specific:
- Rule 2 (Money Format): "ALL monetary fields MUST use z.number().int().positive()" — BisB uses plain TypeScript numbers, no Zod
- Rule 3 (Zod Validation): "ALL Supabase query responses MUST be validated with Zod" — no Supabase
- Rule 6 (Security): "RLS policies enforced on sensitive tables" — no database
- Rule 7: "Components use shadcn/ui" — BisB uses custom React + TailwindCSS
- Rule 8 (DevOps AC): "database changes lack RLS policies", "Supabase responses not validated" — irrelevant
- Rule 9 (Test Cases): "Supabase errors, RLS rejections" in failure modes
- CI Validation: "bun run build", "bun run lint" — should be npm

**Required changes — New QA checklist for BisB**:
1. **Game Rule Accuracy**: Do engine changes match `BisB/Regle du jeu BISB.pdf`? Casino odds, tombola rules, auction pricing V0-V5
2. **State Immutability**: Engine state should never be mutated directly (always return new state)
3. **Engine/Web Separation**: No game logic in React components, no React in engine
4. **TypeScript Strictness**: No `any` types, proper interfaces
5. **Test Coverage**: New engine code must have Vitest tests (target 85%+)
6. **Line Count**: Keep CODE diff under 300 lines
7. **No Debug Logging**: No console.log in production code
8. **Board Data Accuracy**: Board spaces, properties, stocks match official game data
9. **Turn Flow Integrity**: State transitions follow TURN_START → ROLL_DICE → MOVE_PAWN → RESOLVE_SQUARE
10. **Build tools**: `npm test`, `npm run typecheck`, `npm run build`

### 4.4 Karim (DevOps) — KEEP, MINOR ADAPTATION

**What works**: Auto-merge, security checks (secrets, .env files, console.log, dangerous ops), PR size gate, merge conflict handling.

**What's wrong**:
- Checks for `supabase/migrations` and `.sql` files — no database in BisB
- DevOps review flags reference "Supabase Auth, RLS, permissions"
- Retro-action prompt says "SquareInvest"
- Uses `bun` in retro-action context (though Karim makes no Claude calls normally)

**Required changes**:
1. Remove Supabase/SQL file detection
2. Update DevOps review flags for game project
3. Fix retro-action prompt to reference BisB
4. Add: Run `npm test --workspace=@bisb/engine` before merge (actual test execution)
5. Consider: Build verification (`npm run build --workspace=@bisb/web`)

### 4.5 Omar (Ops) — KEEP, MINOR FIXES

**What works**: Blocked ticket monitoring, stale lock cleanup, orphan detection with smart auto-assign, stale PR alerts, sprint completion detection, auto-triage for stuck tickets, agent health monitoring.

**What's wrong**:
- Lock file detection uses `squareinvest-agent-*` pattern
- n8n process check — BisB may not use n8n
- Agent names in stale lock sed pattern: `sed 's/squareinvest-agent-//'`

**Required changes**:
1. Update lock file pattern: `bisb-agent-*`
2. Fix sed pattern for agent name extraction
3. Remove n8n process check (or make it conditional)
4. All functional logic is generic and works well

### 4.6 Rami (Architect) — KEEP, ADAPT PROMPT

**What works**: Architecture review flow, auto-skip for simple tickets, verdict routing, tech debt scoring, Architecture-SignOff field.

**What's wrong**:
- Claude prompt says "SquareInvest"
- Reads `ai/architect.md` (which IS adapted) but hardcoded prompt may override
- Checks for "Supabase RLS policies, auth checks"
- References "src/components/", "src/hooks/", "src/integrations/supabase/" — wrong paths

**Required changes**:
1. Replace prompt references to SquareInvest
2. Fix paths: `packages/engine/src/`, `packages/web/src/components/`
3. Replace Supabase/auth checks with game-specific architecture rules:
   - Engine/web separation respected?
   - Game state immutability?
   - Zustand store patterns consistent?
   - Game rule compliance with physical game?

### 4.7 Layla (Product) — KEEP, COMPLETE REWRITE

**What works**: Feasibility gate flow, RICE scoring, auto-skip, verdict routing, daily report mechanism.

**What's wrong**: Entire domain context is wrong:
- "Tunisian real estate investment platform"
- "CMF/BVMT/BCT regulations"
- "EstateGuru, Crowdestate, Afrikwity, SmartCrowd" competitors
- "crowdfunding", "tokenization", "PropTech" trends
- "investment law", "SPV structures"

**Required changes — New Layla prompt for BisB**:
- Validate game feature fidelity (does it match the physical board game rules?)
- Assess player experience (is the UI intuitive for non-technical Tunisian families?)
- Check multiplayer readiness considerations
- Competitor analysis: Board Game Arena, Tabletop Simulator, Monopoly GO, Catan Universe
- Market context: Tunisian gaming audience, Arabic/French localization needs
- Monetization considerations: free-to-play vs premium, ad-supported

**Daily report should cover**:
- Digital board game market trends
- Competitor app updates (Board Game Arena new games, etc.)
- Mobile gaming trends in MENA region
- Localization requirements for Tunisian market

---

## 5. Workflow Pipeline Analysis

### 5.1 Current Pipeline Flow

```
Ticket Created
    ↓
agent:salma → Spec enrichment
    ↓
  [domain-complex?]─Yes→ agent:layla → Feasibility
    ↓ No                      ↓
    ↓                   agent:rami → Architecture
    ↓                         ↓
agent:youssef → Implementation + PR
    ↓
agent:nadia → QA Review
    ↓
agent:karim → DevOps checks + Auto-merge
    ↓
Done
```

### 5.2 Pipeline Verdict

The pipeline architecture is **excellent**. The label-based routing, retry counters with escalation, feedback files, cooldown timers, and lock management are all production-grade. The workflow handles:

- Retry loops (Youssef ↔ Nadia ping-pong, max 2-3 retries)
- Ticket splitting when scope is too large
- Sprint completion detection with ceremony chains
- Orphan recovery (tickets without agent labels)
- Auto-unblocking stuck tickets after max retries
- Human escalation paths (needs-human label)

**No structural changes needed** — only content adaptation.

### 5.3 Overkill for BisB?

| Gate | SquareInvest Need | BisB Need | Verdict |
|------|-------------------|-----------|---------|
| Salma (PM) | Regulatory specs | Game feature specs | KEEP — simpler prompts |
| Layla (Feasibility) | CMF compliance check | Game rule check | KEEP — rewrite domain |
| Rami (Architecture) | Supabase/auth design | Engine/web separation | KEEP — lighter checks |
| Youssef (Dev) | Full-stack + DB | Engine + React | KEEP — simpler stack |
| Nadia (QA) | Security + compliance | Game accuracy + tests | KEEP — rewrite checklist |
| Karim (DevOps) | Infra + merge | Tests + merge | KEEP — add test run |
| Omar (Ops) | Pipeline health | Pipeline health | KEEP — as-is |

**Recommendation**: Keep all 7 agents. The pipeline overhead is worth it — BisB has complex game rules where automated QA and architecture review prevent regressions.

---

## 6. Humanization Audit

### 6.1 Current State

Slack messages have good personality basics:
- Agent avatars and emojis (from `AGENT_SLACK_EMOJI` array)
- Job title in footer (from `AGENT_SLACK_JOBTITLE` array)
- Color-coded messages (good/warning/danger)

Jira comments use structured ADF with color-coded panels (blue=INFO, green=PASS, red=FAIL).

### 6.2 Issues

1. **All prompts start with "You are X, the PM agent for SquareInvest"** — should be "You are X, part of the BisB development team working on the Business is Business digital board game"
2. **Job titles reference SquareInvest** — should reference BisB/game dev roles
3. **No game-specific personality** — agents should occasionally reference game mechanics they know (e.g., Nadia could say "This casino logic doesn't match the 1-in-6 odds from the physical game")
4. **Slack identity arrays need updating** in agent-common.sh

### 6.3 Recommended Slack Identities

```bash
AGENT_SLACK_USERNAME[salma]="Salma"
AGENT_SLACK_JOBTITLE[salma]="PM — BisB Game"
AGENT_SLACK_EMOJI[salma]=":clipboard:"

AGENT_SLACK_USERNAME[youssef]="Youssef"
AGENT_SLACK_JOBTITLE[youssef]="Game Developer — BisB"
AGENT_SLACK_EMOJI[youssef]=":hammer_and_wrench:"

AGENT_SLACK_USERNAME[nadia]="Nadia"
AGENT_SLACK_JOBTITLE[nadia]="QA Engineer — BisB"
AGENT_SLACK_EMOJI[nadia]=":mag:"

AGENT_SLACK_USERNAME[karim]="Karim"
AGENT_SLACK_JOBTITLE[karim]="DevOps — BisB"
AGENT_SLACK_EMOJI[karim]=":rocket:"

AGENT_SLACK_USERNAME[omar]="Omar"
AGENT_SLACK_JOBTITLE[omar]="Ops Watchdog — BisB"
AGENT_SLACK_EMOJI[omar]=":eyes:"

AGENT_SLACK_USERNAME[rami]="Rami"
AGENT_SLACK_JOBTITLE[rami]="Architect — BisB"
AGENT_SLACK_EMOJI[rami]=":classical_building:"

AGENT_SLACK_USERNAME[layla]="Layla"
AGENT_SLACK_JOBTITLE[layla]="Product Strategist — BisB"
AGENT_SLACK_EMOJI[layla]=":dart:"
```

---

## 7. Exact Files to Edit (Priority Order)

### P0 — Pipeline Won't Work Without These

| # | File | Change | Est. Effort |
|---|------|--------|-------------|
| 1 | `n8n/scripts/agent-cron.sh` | Add Jira query dispatch loop for ticket-based agents | 30 min |
| 2 | `n8n/scripts/agent-common.sh` line 576 | `BASE_BRANCH="${BASE_BRANCH:-master}"` | 1 min |
| 3 | `.env.agents` | Add `BASE_BRANCH=master` | 1 min |

### P1 — Agents Generate Wrong Code

| # | File | Change | Est. Effort |
|---|------|--------|-------------|
| 4 | `n8n/scripts/agent-youssef.sh` | Replace all `bun` with `npm`, fix staging paths, update prompt | 45 min |
| 5 | `n8n/scripts/agent-nadia.sh` | Complete QA checklist rewrite (see Section 4.3) | 1 hour |
| 6 | `n8n/scripts/agent-salma.sh` | Replace SquareInvest prompts, remove investment references | 45 min |
| 7 | `n8n/scripts/agent-rami.sh` | Replace SquareInvest architecture rules with game patterns | 30 min |
| 8 | `n8n/scripts/agent-common.sh` | Replace all `squareinvest` references, update Slack identities, fix lock naming | 30 min |

### P2 — Domain Mismatch (Works But Wrong Context)

| # | File | Change | Est. Effort |
|---|------|--------|-------------|
| 9 | `n8n/scripts/agent-layla.sh` | Complete prompt rewrite for game product validation | 45 min |
| 10 | `n8n/scripts/agent-layla-daily.sh` | Rewrite for digital board game market research | 30 min |
| 11 | `n8n/scripts/agent-karim.sh` | Remove Supabase checks, add npm test execution | 20 min |
| 12 | `n8n/scripts/agent-omar.sh` | Fix lock patterns from `squareinvest-agent-*` to `bisb-agent-*` | 10 min |

### P3 — Polish

| # | File | Change | Est. Effort |
|---|------|--------|-------------|
| 13 | `n8n/scripts/agent-common.sh` | Update Slack identity arrays (job titles, emojis) | 10 min |
| 14 | All agent scripts | Update co-author emails from `@squareinvest.ai` to `@bisb.ai` | 5 min |

**Total estimated effort: ~6 hours**

---

## 8. Detailed Change Specifications

### 8.1 agent-cron.sh — Full Rewrite

```bash
#!/bin/bash
# BisB Agent Cron — runs every 15 min weekdays 8-20 UTC
set -euo pipefail

ENV_FILE="/opt/bisb/.env.agents"
LOG_DIR="/opt/bisb/n8n/logs"
SCRIPTS_DIR="/opt/bisb/n8n/scripts"
PAUSE_FILE="/tmp/bisb-agents-paused"
source "$ENV_FILE"

if [ -f "$PAUSE_FILE" ]; then
  echo "[$(date)] BisB agents paused, skipping run"
  exit 0
fi

echo "[$(date)] === BisB agent cron starting ==="

cd /opt/bisb && git pull origin master --rebase 2>&1 | tail -3

# Daily Layla report (first run of the day only)
LAYLA_DAILY_FLAG="/tmp/bisb-layla-daily-$(date +%Y-%m-%d)"
if [ ! -f "$LAYLA_DAILY_FLAG" ]; then
  echo "[$(date)] Running Layla daily report..."
  bash "${SCRIPTS_DIR}/agent-layla-daily.sh" >> "${LOG_DIR}/agent-layla.log" 2>&1 || true
fi

# Omar runs without ticket (ops watchdog)
echo "[$(date)] Running Omar (ops)..."
bash "${SCRIPTS_DIR}/agent-omar.sh" >> "${LOG_DIR}/agent-omar.log" 2>&1 || true

# Jira auth
JIRA_AUTH=$(echo -n "${JIRA_EMAIL}:${JIRA_API_TOKEN}" | base64)

# Ticket-based agents: query Jira for assigned tickets
for agent in salma layla rami youssef nadia karim; do
  TICKETS=$(curl -s -X POST \
    -H "Authorization: Basic ${JIRA_AUTH}" \
    -H "Content-Type: application/json" \
    "${JIRA_BASE_URL}/rest/api/3/search/jql" \
    -d "{\"jql\":\"project=${JIRA_PROJECT} AND labels='agent:${agent}' AND statusCategory != 'Done'\",\"fields\":[\"key\"],\"maxResults\":5}" \
    | python3 -c "import sys,json; [print(i['key']) for i in json.load(sys.stdin).get('issues',[])]" 2>/dev/null || true)

  if [ -z "$TICKETS" ]; then
    continue
  fi

  for ticket in $TICKETS; do
    echo "[$(date)] Running agent-${agent} on ${ticket}..."
    timeout 600 bash "${SCRIPTS_DIR}/agent-${agent}.sh" "$ticket" \
      >> "${LOG_DIR}/agent-${agent}.log" 2>&1 || {
      echo "[$(date)] agent-${agent} failed/timed out on ${ticket}"
    }
  done
done

echo "[$(date)] === BisB agent cron complete ==="
```

### 8.2 agent-common.sh — Key Replacements

```bash
# Line 3: Header
# OLD: # agent-common.sh — Shared utilities for SquareInvest AI agent pipeline
# NEW: # agent-common.sh — Shared utilities for BisB AI agent pipeline

# Line 576: Base branch
# OLD: BASE_BRANCH="${BASE_BRANCH:-test}"
# NEW: BASE_BRANCH="${BASE_BRANCH:-master}"

# Lock file naming (grep for "squareinvest-agent" and replace with "bisb-agent")
# This affects acquire_lock, release_lock, and Omar's stale lock detection
```

### 8.3 agent-youssef.sh — Build Commands

Replace every `bun` with `npm`:
```bash
# Quality checks
TYPECHECK_OUT=$(npm run typecheck 2>&1) || CHECKS_PASSED=false
LINT_OUT=$(npm run lint 2>&1) || CHECKS_PASSED=false
BUILD_OUT=$(npm run build 2>&1) || CHECKS_PASSED=false

# Claude prompt
"3. Run: npm run lint (fix any errors)
4. Run: npm run build (fix any errors)"

# Allowed tools
--allowedTools "Read Write Edit Glob Grep Bash(npm:*) Bash(git add:*) Bash(git rm:*) Bash(git status:*) Bash(git diff:*)"

# Git staging paths
git add -A -- packages/ 2>/dev/null || true
git add -A -- .gitignore package.json package-lock.json 2>/dev/null || true
git add -A -- tsconfig*.json vite.config.* tailwind.config.* eslint.config.* 2>/dev/null || true
git add -A -- index.html 2>/dev/null || true
git add -A -- .github/ 2>/dev/null || true
```

### 8.4 agent-nadia.sh — New QA Checklist (Replace lines 223-380)

```
QA CHECKLIST — BisB Game Engine & UI

1. GAME RULE ACCURACY (highest priority)
   - Engine changes must match BisB/Regle du jeu BISB.pdf
   - Casino: forced 100k bet, pick 1-6, 1-in-6 win odds
   - Tombola: pick 3 numbers, 500k jackpot
   - Auction pricing: V0-V5 scale for stocks and properties
   - Football: dice duel (win=0, draw=30k, loss=100k)
   - Telecom: dice roll * 30k payment
   - Gangsters: escalating cost 100k to 550k, blocks 3 properties
   - FAIL if game mechanics don't match official rules

2. STATE IMMUTABILITY
   - Engine functions must not mutate state directly
   - Return new state objects, not modified originals
   - Check for direct array/object mutations (.push, .splice, delete)
   - FAIL if state mutation found in engine code

3. ENGINE/WEB SEPARATION
   - No React, DOM, or UI imports in packages/engine/
   - No game logic (calculations, validations) in packages/web/
   - Zustand store is the bridge between engine and UI
   - FAIL if separation violated

4. TYPESCRIPT STRICTNESS
   - No 'any' types in new code
   - Proper interfaces for game objects
   - ESM imports with .js extension
   - FAIL if 'any' types found

5. TEST COVERAGE
   - New engine code must have Vitest tests
   - Tests in packages/engine/tests/
   - Target 85%+ coverage on game logic
   - PASS_WITH_WARNINGS if coverage is below target

6. LINE COUNT (code files only: .ts/.tsx/.js/.jsx/.css)
   - MAX 300 lines of code changes per PR
   - Documentation and config files are exempt
   - FAIL if code diff exceeds 300 lines

7. NO DEBUG LOGGING
   - Zero console.log/warn/info in production code
   - Only console.error in error boundaries
   - FAIL if debug logging found

8. BOARD DATA ACCURACY
   - 48 board spaces, 25 properties, 16 stocks, 25 environment cards
   - Property types must match (HOTEL_CHAIN, CASINO, FACTORY, etc.)
   - Stock sectors: Petroleum, Banking, Industry, Insurance
   - FAIL if game data is incorrect

9. TURN FLOW INTEGRITY
   - TURN_START -> OPTIONAL_AUCTION -> ROLL_DICE -> MOVE_PAWN -> RESOLVE_SQUARE
   - Modals must not skip or duplicate phases
   - Player rotation must be correct
   - PASS_WITH_WARNINGS if turn flow has edge cases
```

### 8.5 agent-layla.sh — New Prompt Focus

Replace investment domain with:
```
You are Layla, the Product Strategist for BisB (Business is Business),
a digital version of the popular Tunisian board game.

VALIDATE against these criteria:
a) GAME FIDELITY: Does this feature accurately represent the physical board game?
b) PLAYER EXPERIENCE: Is the UI intuitive for non-technical Tunisian families?
c) MULTIPLAYER READINESS: Does this work for future online multiplayer?
d) AUDIENCE FIT: Tunisian diaspora, Arabic/French language needs
e) MONETIZATION: Free-to-play vs premium considerations

Competitors to track: Board Game Arena, Tabletop Simulator,
Monopoly GO, Catan Universe, Ludo King
```

### 8.6 agent-layla-daily.sh — New Research Focus

```
Research:
a) Digital board game market trends (mobile + web)
b) Board Game Arena new game launches
c) Tabletop Simulator community activity
d) Mobile board game monetization models
e) MENA region gaming audience trends
f) Arabic/French game localization best practices
```

---

## 9. New/Updated Agent Suggestions

### 9.1 No New Agents Needed

The 7-agent pipeline is well-balanced for BisB. Adding more would create unnecessary overhead for a game project.

### 9.2 Consider Removing Layla from Critical Path

For a board game project, market feasibility checks are less critical than for a fintech platform. Consider making Layla **advisory-only**:

- Keep daily reports (interesting for market awareness)
- Remove from ticket pipeline (Salma → Rami → Youssef directly)
- Layla can still be invoked by Salma for complex feature validation

This would speed up the pipeline by removing one gate. But keeping her is fine too — the auto-skip for simple tickets means she barely adds latency.

### 9.3 Karim Enhancement: Add Test Execution

Currently Karim only does diff-based security checks. For a game engine, he should also:
```bash
# Before merge, actually run the test suite
npm test --workspace=@bisb/engine 2>&1
npm run build --workspace=@bisb/web 2>&1
```
This catches regressions that Youssef's branch may not have (e.g., merge conflicts breaking tests).

---

## 10. Messaging Improvements

### 10.1 Slack Message Templates

Current messages are functional but could be more game-aware:

**Instead of**: "Enriched BISB-42: Add casino modal"
**Use**: "Enriched BISB-42: Casino modal (1-in-6 dice game). Spec references Regle du jeu Section 3.2. Forwarding to Youssef."

**Instead of**: "QA FAIL: Issue 1: missing error handling"
**Use**: "QA FAIL: Casino dice roll doesn't handle tie scenario. The physical game rules say re-roll on ties."

### 10.2 Jira Comment Style

Add game context to structured comments:
```
## QA Review: PASS
Game rules verified against BisB/Regle du jeu BISB.pdf
- Casino odds: correct (1/6)
- Tombola numbers: validated
- No state mutations detected
```

---

## 11. Next Steps Checklist

### Immediate (Day 1) — Get Pipeline Running

- [ ] Fix `agent-cron.sh` with Jira query dispatch loop
- [ ] Set `BASE_BRANCH=master` in `.env.agents`
- [ ] Fix `BASE_BRANCH` default in `agent-common.sh` line 576
- [ ] Replace `squareinvest-agent-*` lock prefix with `bisb-agent-*` in agent-common.sh
- [ ] Test cron with a single ticket: create BISB-1 with `agent:salma` label

### Day 2 — Fix Build Pipeline

- [ ] Replace all `bun` with `npm` in agent-youssef.sh (14 occurrences)
- [ ] Fix git staging paths in agent-youssef.sh (`packages/` not `src/`)
- [ ] Fix allowed tools: `Bash(npm:*)` not `Bash(bun:*)`
- [ ] Replace `bun.lock` with `package-lock.json` in staging
- [ ] Remove `supabase/` from staging
- [ ] Fix co-author email

### Day 3 — Adapt Prompts

- [ ] Replace all "SquareInvest" references in agent-common.sh (~5 occurrences)
- [ ] Rewrite agent-salma.sh prompt (remove investment context, add game context)
- [ ] Rewrite agent-nadia.sh QA checklist (see Section 8.4)
- [ ] Rewrite agent-rami.sh architecture rules (see Section 4.6)
- [ ] Update Slack identity arrays in agent-common.sh

### Day 4 — Adapt Domain Agents

- [ ] Rewrite agent-layla.sh prompt for game product validation
- [ ] Rewrite agent-layla-daily.sh for board game market research
- [ ] Update agent-karim.sh: remove Supabase checks, add npm test execution
- [ ] Fix agent-omar.sh lock file patterns

### Day 5 — Verify End-to-End

- [ ] Create test ticket BISB-X with `agent:salma` label
- [ ] Verify Salma enriches with game-relevant spec
- [ ] Verify Youssef implements with correct build commands
- [ ] Verify Nadia QA reviews with game-specific checklist
- [ ] Verify Karim merges successfully
- [ ] Verify Omar detects orphaned tickets

---

## 12. Risks

| Risk | Likelihood | Mitigation |
|------|------------|------------|
| Agents generate SquareInvest code if prompts not fully cleaned | High | Search-and-replace audit after changes |
| npm commands fail on VPS (missing node_modules) | Medium | Run `npm install` in /opt/bisb after clone |
| Game rule prompts too vague for Claude | Medium | Include specific rule excerpts in prompts |
| Agents overwhelm with tickets if backlog is large | Low | Max 5 tickets per agent per cron cycle |
| Lock file collision during migration | Low | Clear all /tmp/bisb-* locks before first run |

---

## 13. Summary

The agent infrastructure is **excellent quality** but **completely unadapted** for BisB. It's like having a Formula 1 pit crew that's been told they're servicing a fishing boat — the skills are there, but every tool reference is wrong.

**Priority actions**:
1. Fix `agent-cron.sh` dispatch (without this, nothing runs)
2. Fix `BASE_BRANCH` to `master` (without this, all git ops fail)
3. Replace `bun` with `npm` in Youssef (without this, builds fail)
4. Rewrite Nadia's QA checklist (without this, QA checks are meaningless)
5. Replace SquareInvest prompts across all agents

The pipeline architecture, retry logic, escalation paths, and Jira/Slack integration are production-grade and need zero structural changes. It's purely a content adaptation job.
