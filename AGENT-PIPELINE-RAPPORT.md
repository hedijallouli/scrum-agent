# BISB AI Agent Pipeline - Architecture Rapport

> **Date**: 2026-03-12
> **Author**: Hedi Jallouli
> **Version**: 3.0 (event sourcing + idempotency + degradation + SLO)
> **Status**: Active development, pipeline optimized

---

## 1. Team Philosophy & Vision

### 1.1 Le Moto

> **"Human-in-the-loop supervisor"**

Un humain (Hedi) supervise une equipe de 6 agents IA autonomes. Les agents font le travail. L'humain fait les decisions.

Ce n'est pas de l'IA qui "aide" un developpeur. C'est un developpeur qui **supervise** une equipe IA. La difference est fondamentale : les agents sont les executants, l'humain est le decideur strategique.

### 1.2 Les Principes Fondamentaux

| Principe | Signification |
|----------|---------------|
| **Autonomie maximale** | Les agents tournent 24/7 sans intervention. Ils enrichissent les specs, codent, reviewent, mergent. |
| **Escalade intelligente** | Quand un agent ne sait pas, il escalade. Jamais il ne devine. `Needs Human` existe pour ca. |
| **Cout-efficacite** | Haiku pour les taches simples, Sonnet pour le travail, Opus pour les decisions critiques. Chaque token doit produire de la valeur. |
| **Transparence totale** | Chaque action est loguee, chaque decision est commentee dans Plane, chaque erreur est tracee. |
| **Resilience** | Le pipeline survit aux pannes : circuit breakers, backoff, watchdog, auto-healing. Un agent qui plante ne casse pas le systeme. |
| **Zero framework** | Bash + cron. Pas de LangChain, pas de CrewAI, pas de n8n. Simplicite, debuggabilite, controle total. |

### 1.3 L'Objectif

Construire un **systeme autonome de developpement logiciel** capable de :

1. **Transformer une idee en ticket enrichi** (Salma + Layla)
2. **Implementer le ticket** (Youssef — code, tests, PR)
3. **Valider la qualite** (Nadia — code review, tests, QA)
4. **Verifier l'architecture** (Rami — patterns, dette technique)
5. **Merger et deployer** (Rami — DevOps + merge)
6. **Monitorer et corriger** (Omar — sante, triage, ceremonies)

Le tout **sans que Hedi touche le code**, sauf pour les decisions strategiques.

### 1.4 Le Produit

**Business is Business (BisB)** — jeu de societe tunisien cree par Zied Remadi, en cours de digitalisation. TypeScript monorepo (engine + web), React + Vite + TailwindCSS + Zustand. 48 espaces, 25 proprietes, 16 actions, 25 cartes environnement, systeme de production complet.

---

## 2. Agent Roster

### 2.1 Vue d'Ensemble

```
 +-------+     +--------+     +-------+     +------+     +-------+     +------+
 | SALMA |     |YOUSSEF |     | NADIA |     | RAMI |     | LAYLA |     | OMAR |
 |  PM   |---->|  Dev   |---->|  QA   |---->| Arch |     | Prod  |     | Ops  |
 | Spec  |     | Code   |     |Review |     |Merge |     |Strat  |     |Guard |
 +-------+     +--------+     +-------+     +------+     +-------+     +------+
```

### 2.2 Fiches Detaillees

#### Salma — Product Manager / Product Owner

| Attribut | Valeur |
|----------|--------|
| **Role** | Enrichir les specs, prioriser le backlog, piloter les sprints |
| **Model** | Sonnet (feedback-aware), Opus pour decisions de split |
| **Trigger** | Tickets en Todo/Backlog sans spec enrichie |
| **Sortie** | Spec enrichie (acceptance criteria, edge cases, context technique) |
| **Handoff** | Ticket → Ready → Youssef |
| **Personnalite** | Organisee, directe, pragmatique. "Pas de flou dans les specs." |
| **Budget share** | 15% |
| **Modes speciaux** | Ideation picker (choisit parmi 10 concepts de Layla), Architecture spec (depuis reco Rami), Split/rewrite (Opus, apres echecs QA/Dev) |

#### Youssef — Software Engineer

| Attribut | Valeur |
|----------|--------|
| **Role** | Implementer les tickets : code, tests unitaires, PR |
| **Model** | Sonnet (50 max-turns, feedback-aware) |
| **Trigger** | Tickets en Ready avec spec enrichie |
| **Sortie** | Branche feature + PR GitHub |
| **Handoff** | PR → In Review → Nadia |
| **Personnalite** | Methodique, pragmatique. Cite toujours les fichiers modifies. |
| **Budget share** | 40% (le plus gros consommateur) |
| **Workspace** | Git worktree dedie par ticket (isolation complete) |
| **Guardrails** | Pre-PR: 8 checks (secrets, dangerous ops, typecheck, tests, etc.) |

#### Nadia — QA Engineer

| Attribut | Valeur |
|----------|--------|
| **Role** | Reviewer les PRs, verifier la qualite, valider les tests |
| **Model** | Sonnet (default), Opus pour fichiers sensibles, Haiku pour fast-paths |
| **Trigger** | Tickets en In Review avec PR ouverte |
| **Sortie** | Verdict PASS/FAIL + commentaires detailles |
| **Handoff** | PASS → Rami (merge), FAIL → Youssef (fix) |
| **Personnalite** | Rigoureuse, factuelle. "Zero tolerance sur les regressions." |
| **Budget share** | 20% |
| **Classification** | Analyse le diff : test-only → Haiku, docs-only → Haiku, sensitive files → Opus |
| **Verdicts** | PASS, FAIL, UNKNOWN (escalade) |

#### Rami — Technical Architect + DevOps

| Attribut | Valeur |
|----------|--------|
| **Role** | Review architecture, merge PRs, DevOps checks |
| **Model** | Sonnet pour architecture, Haiku pour retro-actions |
| **Trigger** | Tickets avec label architecture-review + PRs passees QA |
| **Sortie** | Recommandation archi / PR mergee |
| **Handoff** | Merge → Done, Reco archi → Salma |
| **Personnalite** | Sobre, technique, mentor. "L'architecture est stable." |
| **Budget share** | 10% |
| **DevOps checks** | Secrets scan, .env detection, console.log, diff size, dangerous ops |

#### Layla — Product Strategist

| Attribut | Valeur |
|----------|--------|
| **Role** | Ideation produit, validation feasibility, voix du joueur |
| **Model** | Dynamic (Sonnet pour features complexes) |
| **Trigger** | Tickets necessitant ideation + feasibility review |
| **Sortie** | 10 concepts (ideation) / Score RICE (feasibility) |
| **Handoff** | Concepts → Salma (picker), Validation → Rami |
| **Personnalite** | Creative, orientee joueur. "Est-ce que le joueur va adorer ca?" |
| **Budget share** | 10% |
| **Modes** | Ideation (10 propositions), Feasibility (game fidelity, UX, multiplayer, RICE) |

#### Omar — Ops / Scrum Master

| Attribut | Valeur |
|----------|--------|
| **Role** | Monitorer la sante du pipeline, faciliter les ceremonies, triager les blockers |
| **Model** | Aucun (pure bash) sauf ceremonies (Haiku) |
| **Trigger** | Chaque cycle dispatch + ceremonies planifiees |
| **Sortie** | Alertes Slack, triage, health reports |
| **Handoff** | Deblocage → equipe ou Hedi |
| **Personnalite** | Vigilant, factuel. "Pipeline operationnel." |
| **Budget share** | 5% |
| **Health checks** | Stale locks, agent idle >24h, stale PRs, Sonnet rate limit, circuit breaker status |

---

## 3. Infrastructure

### 3.1 Stack Technique

```
+------------------------------------------+
|           VPS 49.13.225.201              |
|           Ubuntu, 4 GB RAM               |
+------------------------------------------+
|                                          |
|  +-- Plane (port 8090) -------- Tracker  |
|  +-- Mattermost ------------ Chat/DMs    |
|  +-- Cron -------- Dispatch (*/15 min)   |
|  +-- /opt/bisb-scripts/ --- Agent code   |
|  +-- /var/log/bisb/ -------- Logs        |
|  +-- /var/lib/bisb/ -------- Data/State  |
|  +-- /tmp/bisb-* ----------- Runtime     |
|                                          |
+------------------------------------------+
     |           |            |
     v           v            v
  GitHub      Slack       Anthropic
  (code)    (mirror)    (Claude API)
```

### 3.2 Fichiers du Pipeline

| Fichier | Lignes | Role |
|---------|--------|------|
| `agent-common.sh` | ~2000 | Bibliotheque partagee : Plane API, Mattermost, retries, circuit breakers, logging, backoff, budgets, caching |
| `tracker-common.sh` | ~400 | Abstraction Plane/Jira : CRUD tickets, etats, labels, commentaires |
| `agent-cron.sh` | ~950 | Dispatcher principal : 9 phases par cycle |
| `run-agent.sh` | ~120 | Runner avec pre-flight checks, timeout, metrics |
| `agent-salma.sh` | ~600 | Agent PM : enrichissement spec, ideation picker, split |
| `agent-youssef.sh` | ~400 | Agent Dev : implementation dans worktree, PR |
| `agent-nadia.sh` | ~550 | Agent QA : classification diff, review, verdict |
| `agent-rami.sh` | ~250 | Agent Architecte : review archi, DevOps, merge |
| `agent-layla.sh` | ~250 | Agent Produit : ideation, feasibility, RICE |
| `agent-omar.sh` | ~300 | Agent Ops : health checks, triage, alertes |
| `ceremony-common.sh` | ~465 | Bibliotheque ceremonies : tours Haiku, cumulative, pause |
| `ceremony-standup.sh` | ~310 | Standup quotidien avec decisions actionnables |
| `ceremony-review.sh` | ~400 | Sprint Review avec conversations cumulatives |
| `ceremony-retro.sh` | ~350 | Sprint Retrospective avec action items |
| `ceremony-planning.sh` | ~450 | Sprint Planning avec votes |
| `ceremony-refinement.sh` | ~300 | Backlog Refinement |
| `ceremony-blocker-triage.sh` | ~350 | Triage multi-agent en 2 rounds |
| `ceremony-orchestrator.sh` | ~150 | Chainage Review → Retro |
| `agent-guardrails.sh` | ~180 | Pre-PR safety (8 checks) |
| `watchdog.sh` | ~200 | Self-healing hourly (11 checks) |
| `event-log.sh` | ~120 | Event sourcing lite : immutable JSONL event log |
| `idempotency-common.sh` | ~150 | Exactly-once execution : claim/journal/recover |
| `degrade.sh` | ~170 | Graceful degradation : 4 niveaux (NORMAL→EMERGENCY) |
| `pipeline-slo.sh` | ~210 | SLO monitoring : retry storms, success rate, canary |
| `agent-cron-loop.sh` | ~65 | Force-loop (deprecie, auto-expiry 48 cycles) |
| `agent-dm-poller.sh` | ~60 | DM Mattermost poller |
| **Total** | **~9150** | **Pure bash, zero framework** |

---

## 4. Ticket Lifecycle

### 4.1 Workflow States (Plane)

```
  Backlog ──> Todo ──> Ready ──> In Progress ──> In Review ──> Done ──> Merged
     |          |                     |              |
     |          |                     |              v
     |          |                     |          [FAIL] ──> Youssef retry
     |          |                     v                       (max 3x)
     |          |                  Blocked ──> Omar triage
     |          |                     |
     |          v                     v
     |      Needs Human ────> Hedi decides ──> back to flow
     v
  (archived)
```

### 4.2 Assignation Automatique

| Etat | Assignee | Logique |
|------|----------|---------|
| Todo / Backlog (sans spec) | Salma | Enrichir la spec |
| Ready (non assigne) | Youssef | Implementer |
| In Review (PR ouverte) | Nadia | Reviewer |
| Blocked | **Omar only** | Il triage et debloque |
| Needs Human | **Hedi only** | Decision strategique |
| Done (PR mergee) | (aucun) | Fin du cycle |

---

## 5. Dispatch Engine

### 5.1 Vue d'Ensemble

Le dispatcher (`agent-cron.sh`) tourne toutes les 15 minutes via cron avec `flock` pour empecher les chevauchements. Chaque cycle execute 9 phases :

### 5.2 Les 9 Phases

```
Phase 1: Git fetch + branch cleanup
         ↓
Phase 2: Sync Plane states → local tracking
         ↓
Phase 3: Salma (PM) — tickets Todo/Backlog sans spec
         ↓
Phase 4: Youssef (Dev) — tickets Ready, cree worktree, implemente
         ↓
Phase 5: Nadia (QA) — tickets In Review avec PR ouverte
         ↓
Phase 6: Rami (Architecte) — tickets avec architecture-review
         ↓
Phase 7: Layla (Produit) — tickets necessitant ideation
         ↓
Phase 8: Omar (Ops) — health checks, stale locks, alertes
         ↓
Phase 9: Ceremonies — standup, retro, planning (time-based triggers)
```

### 5.3 Pre-flight Checks (par ticket)

Avant de dispatcher un agent, `run-agent.sh` verifie :

1. **Circuit breaker** — L'agent n'est pas en lockout (5 failures → 15min cooldown)
2. **Dependency health** — Plane et Claude sont up (pas de flag `.down`)
3. **Backoff** — Le ticket n'est pas en periode de cooldown (exponential backoff)
4. **Budget** — L'agent n'a pas depasse sa part du budget quotidien
5. **Blacklist** — Le ticket n'est pas blackliste (3 echecs → 1h cooldown)
6. **Lock** — Pas d'autre instance de cet agent sur ce ticket

Si toutes les conditions passent, l'agent est lance avec un timeout de 1800s.

---

## 6. Reliability Layer

### 6.1 Circuit Breakers

```
Agent failure → cb_record_failure()
                    ↓
              count in 10min window?
                    ↓
              < 5 failures → continue
              ≥ 5 failures → BREAKER OPEN (15 min)
                    ↓
              Agent skips all work
                    ↓
              Cooldown expire → cb_reset() → back to normal
```

- **Fichier** : `/tmp/bisb-circuit-breakers/{agent}.state`
- **Format** : `count|last_failure_ts|open_until_ts`
- **Succes** : Reset automatique du compteur

### 6.2 Error Classification + Backoff

| Type | Detection | Backoff | Retry? |
|------|-----------|---------|--------|
| `TIMEOUT` | exit code 124 | 60s→240s→600s→1800s | Oui (max 3) |
| `RATE_LIMIT` | stderr contient "429" / "rate limit" | Backoff x2 + flag dep claude.down | Oui |
| `TRANSIENT` | stderr contient "5xx" / "connection refused" | Standard backoff | Oui |
| `PERMANENT` | stderr contient "401" / "404" / "forbidden" | Pas de retry | Non — escalade immediate |
| `BAD_OUTPUT` | stderr contient "validation" / "parse error" | Standard backoff | Oui (max 3) |

Backoff avec **jitter ±30%** pour eviter les thundering herds.

### 6.3 Poison Pill Detection

Si un ticket est blackliste **3+ fois en 24h** :
- Auto-escalade a `Needs Human` (Hedi)
- Commentaire Plane : "Poison pill detecte"
- Notification Slack

### 6.4 Dependency Health Flags

```
/tmp/bisb-dep-flags/
├── plane.down    # Plane API unreachable
├── claude.down   # Claude rate-limited
└── github.down   # GitHub API issues
```

- TTL : 5 minutes
- Si un flag existe, tous les agents qui dependent de ce service **skip** au lieu de thrash
- Mis automatiquement quand une erreur pertinente est detectee

### 6.5 Per-Agent Budgets

| Agent | Budget Share | Rationale |
|-------|-------------|-----------|
| Youssef | 40% | Plus gros consommateur : 50-turn implementation |
| Nadia | 20% | Code review detaillee, parfois Opus |
| Salma | 15% | Specs, ideation picking, splits |
| Rami | 10% | Architecture reviews ponctuelles |
| Layla | 10% | Ideation + feasibility |
| Omar | 5% | Surtout bash, Claude uniquement pour ceremonies |

Throttle a 150% du share. Si Youssef consomme 60% des calls (au lieu de 40%), ses prochains dispatches sont skipped.

### 6.6 Watchdog (Self-Healing)

Tourne toutes les heures. Verifie et auto-corrige (11 checks) :

| Check | Action si probleme |
|-------|--------------------|
| Git sur mauvaise branche | `git checkout master` |
| Disque > 90% | Supprime vieux logs + cache |
| Stale locks (> 30min) | Supprime le lock |
| Circuit breakers expires | Reset |
| Processus orphelins (> 40min) | Kill |
| Cron inactif > 20min | Alerte Slack |
| Memoire < 200MB | Kill processus parasites |
| Pipeline SLO | Retry storms, success rate, canary |
| Auto-degradation | Ajuste le niveau selon l'etat du systeme |
| Event log rotation | Garde 7 jours, supprime le reste |
| Idempotency cleanup | Supprime les claims > 48h |

### 6.7 Event Sourcing Lite

Chaque action significative est enregistree dans un log immutable JSONL :

```
/var/lib/bisb/events/events.jsonl

{"ts":"2026-03-12T10:05:32Z","epoch":1710237932,"ticket":"BISB-47","agent":"youssef","action":"agent_start","run_id":"1710237932-12345-youssef-BISB-47","data":{}}
{"ts":"2026-03-12T10:15:42Z","epoch":1710238542,"ticket":"BISB-47","agent":"youssef","action":"agent_success","run_id":"...","data":{"duration":610}}
{"ts":"2026-03-12T10:16:01Z","epoch":1710238561,"ticket":"BISB-47","agent":"nadia","action":"agent_start","run_id":"...","data":{}}
```

**Queries disponibles** :
- `ticket_history "BISB-47"` — toutes les actions sur un ticket
- `ticket_history "BISB-47" "2026-03-12T15:00" "2026-03-12T17:00"` — fenetre temporelle
- `run_timeline "RUN_ID"` — toutes les actions d'un run specifique
- `agent_events "youssef" 50` — dernieres 50 actions d'un agent
- `event_summary 24` — compteur par type d'action sur les dernières 24h

**Rotation** : 7 jours, cleanup par le watchdog.

### 6.8 Idempotency Layer

Garantit **exactly-once execution** par ticket+agent. Previent les PRs et commentaires dupliques.

```
Agent run:
  1. claim_run "BISB-47" "youssef"  ←── atomic mkdir, echoue si deja pris
  2. if ! has_step "create_branch"; then
       git checkout -b feat/BISB-47 && journal_step "create_branch"
     fi
  3. if ! has_step "create_pr"; then
       gh pr create ... && journal_step "create_pr" '{"url":"..."}'
     fi
  4. complete_run  ←── archive journal, release claim
```

- **Stale claims** : auto-cleanup apres 45 min (crash recovery)
- **Historique** : 5 derniers runs par ticket/agent
- **Journal format** : `timestamp|step_name|payload_json`

### 6.9 Graceful Degradation

4 niveaux de degradation automatique :

| Niveau | Nom | Qui tourne | Declencheur |
|--------|-----|------------|-------------|
| 0 | NORMAL | Tous les agents | Etat par defaut |
| 1 | DEGRADED | Sauf Layla, Karim | 3+ circuit breakers ouverts |
| 2 | MINIMAL | Youssef, Nadia, Omar seulement | Plane/Claude down, 5+ CB ouverts, memoire < 200MB |
| 3 | EMERGENCY | Aucun agent | Memoire < 100MB |

- **Auto-detection** : `auto_degrade_check()` dans le dispatcher et le watchdog
- **Auto-expiry** : retour a NORMAL si le fichier a > 1h
- **Fallback par agent** : chaque agent a un comportement de repli (`park`, `skip`, `reassign:omar`)
- **Historique** : transitions loguees dans `/var/lib/bisb/data/degrade-history.jsonl`

### 6.10 SLO Monitoring

5 checks proactifs qui detectent les problemes AVANT qu'ils deviennent des pannes :

| Check | Seuil | Severite |
|-------|-------|----------|
| Retry storm | > 10 retries en 15 min | HIGH |
| Circuit breaker flapping | > 3 events en 1h | WARN |
| Queue stuck | 5+ failures sur meme ticket en 6h | WARN |
| Success rate | < 50% sur les 20 derniers runs | HIGH |
| Synthetic canary | Claude API unreachable | CRITICAL |

- **Integration watchdog** : SLO checks tournes a chaque cycle watchdog
- **Auto-degradation** : 3+ alertes SLO → niveau 2 (MINIMAL), 1+ alerte → niveau 1 (DEGRADED)
- **Canary** : appel Haiku "Reply with CANARY_OK" — mesure latence, detecte 429/timeout
- **Rapport** : `slo_report 24` pour un resume des dernieres 24h

---

## 7. Ceremonies

### 7.1 Calendrier

| Ceremonie | Frequence | Heure | Agent Lead |
|-----------|-----------|-------|------------|
| **Daily Standup** | Lun-Ven | 08:00 UTC | Omar ouvre, Salma cloture |
| **Blocker Triage** | Toutes les 6h | Auto | Omar |
| **Backlog Refinement** | Mercredi | 13:00 UTC | Salma + equipe |
| **Sprint Review** | Vendredi | 15:00 UTC | Salma |
| **Sprint Retrospective** | Vendredi | 16:00 UTC | Omar |
| **Sprint Planning** | Lundi | 08:00 UTC | Salma |

### 7.2 Conversations Cumulatives

Porte de SI (SquareInvest) n8n. Chaque agent lit ce que les precedents ont dit :

```
Youssef parle (1er) → contexte sprint
     ↓
Nadia parle → lit Youssef, reagit a son travail
     ↓
Rami parle → lit Youssef + Nadia, propose aide si blocker
     ↓
Layla parle → lit tout le monde, perspective joueur
     ↓
Salma parle (derniere) → lit tout le monde, fait des DECISIONS
```

### 7.3 Standup Actionnable

Salma cloture le standup avec des blocs de decision structures :

```
DECISION: BISB-52 | RESET_RETRY | Le blocker API est resolu
DECISION: BISB-39 | ASSIGN_HUMAN | Necessite une decision UX de Hedi
DECISION: BISB-43 | DEPRIORITIZE | Pas dans le scope du sprint
```

Actions executees automatiquement :
- `ASSIGN_YOUSSEF` / `ASSIGN_RAMI` / `ASSIGN_HUMAN` — reassigne dans Plane
- `RESET_RETRY` — reinitialise retries + retire de la blacklist
- `DEPRIORITIZE` — retire du sprint actif
- `UNBLACKLIST` — retire de la blacklist de dispatch

### 7.4 Ceremony Orchestrator

Chaine les ceremonies du vendredi :

```
Omar notifie "Bloc Ceremony" → agents pauses
     ↓
Sprint Review (ceremony-review.sh)
     ↓
60s pause
     ↓
Sprint Retrospective (ceremony-retro.sh)
     ↓
Omar resume les agents
```

### 7.5 Agent Pause

Pendant les ceremonies, le flag `/tmp/bisb-agents-paused` est pose :
- Le dispatcher skip tous les agents
- La ceremony enleve le flag a la fin (seulement si c'est elle qui l'a pose)
- Idempotent : si deja pause par Hedi, la ceremony ne resume pas

---

## 8. Communication

### 8.1 Canaux

| Canal | Usage |
|-------|-------|
| **Mattermost DMs** | Communication agent ↔ Hedi (chaque agent a son bot) |
| **Mattermost #standup** | Ceremonies, standups |
| **Mattermost #sprint** | Sprint reviews |
| **Slack #pipeline** | Notifications pipeline (PR, erreurs, ceremonies) |
| **Plane comments** | Discussion ticket-level (agents commentent les tickets) |
| **GitHub PRs** | Code review, merge |

### 8.2 DM Poller

Toutes les 2 minutes, `agent-dm-poller.sh` verifie les DMs Mattermost non lus de Hedi et les route a l'agent concerne.

---

## 9. Pre-PR Safety (Guardrails)

8 checks avant qu'un agent puisse creer une PR :

| # | Check | Severite | Action si echec |
|---|-------|----------|-----------------|
| 1 | Secrets / credentials dans le diff | CRITICAL | PR bloquee |
| 2 | Operations dangereuses (`rm -rf`, `force push`) | HIGH | PR bloquee |
| 3 | Repertoires proteges modifies (`n8n/scripts/`, `.github/`, `ai/`) | HIGH | PR bloquee |
| 4 | Diff > 350 lignes | WARN | PR autorisee avec warning |
| 5 | TypeScript typecheck | HIGH | PR bloquee |
| 6 | Tests unitaires | HIGH | PR bloquee |
| 7 | `console.log` dans le code | WARN | PR autorisee avec warning |
| 8 | Git integrity (`git fsck`) | CRITICAL | PR bloquee |

---

## 10. Structured Logging & Metrics

### 10.1 Logs Structure (JSON)

Fichier : `/var/log/bisb/structured.log`

```json
{"ts":"2026-03-12T09:01:22Z","level":"INFO","agent":"youssef","ticket":"BISB-47","run_id":"1741770082-1234-youssef-BISB-47","msg":"agent_start"}
```

### 10.2 Metrics JSONL

Fichier : `/var/lib/bisb/data/metrics-agent-runs.jsonl`

```json
{"ts":"2026-03-12T09:31:22Z","agent":"youssef","ticket":"BISB-47","run_id":"...","success":true,"exit_code":0,"duration_ms":1800000,"model":"sonnet","error_type":"none","retry_count":0}
```

### 10.3 Per-Agent Cost Tracking

Fichier : `/var/lib/bisb/data/costs/agent-budgets-YYYY-MM-DD.json`

```json
{
  "youssef": {"calls": 12, "total_duration": 14400, "models": {"sonnet": 10, "haiku": 2}},
  "nadia": {"calls": 5, "total_duration": 3000, "models": {"sonnet": 3, "opus": 2}}
}
```

---

## 11. State Persistence

Tout l'etat est file-based. Pas de database.

| Type | Emplacement | TTL |
|------|-------------|-----|
| Agent locks | `/tmp/bisb-agent-*.lock` | Duree du run (auto-release) |
| Retry counters | `/tmp/bisb-retries/BISB-XX-agent` | Permanent (reset manuellement) |
| Backoff state | `/tmp/bisb-backoff/BISB-XX-agent` | Auto-expire |
| Dispatch blacklist | `/tmp/bisb-dispatch-blacklist` | 1h TTL |
| Circuit breakers | `/tmp/bisb-circuit-breakers/*.state` | 15min open |
| Dep health flags | `/tmp/bisb-dep-flags/*.down` | 5min |
| Poison pills | `/tmp/bisb-poison-pills` | 48h (watchdog cleanup) |
| Sonnet rate limit | `/tmp/bisb-sonnet-rate-limited` | 15min |
| Agent pause | `/tmp/bisb-agents-paused` | Manuel |
| Ticket briefs | `/tmp/bisb-notes/BISB-XX.md` | Permanent |
| Feedback files | `/tmp/bisb-feedback/BISB-XX.txt` | Permanent |
| Ceremony state | `/tmp/bisb-ceremony-state.json` | Per-run |
| Standup idempotency | `/tmp/bisb-standup-YYYY-MM-DD` | 1 jour |
| Response cache | `/var/lib/bisb/cache/` | 1h |
| Structured logs | `/var/log/bisb/structured.log` | Rotation 7j |
| Metrics | `/var/lib/bisb/data/metrics-agent-runs.jsonl` | Permanent |
| Cost budgets | `/var/lib/bisb/data/costs/` | Per-day |
| Ceremony decisions | `/var/lib/bisb/data/ceremony-decisions.jsonl` | Permanent |
| Agent activity | `/var/lib/bisb/data/agents/*/last-activity.json` | Updated per-run |
| Event log | `/var/lib/bisb/events/events.jsonl` | 7j (rotation auto) |
| Idempotency claims | `/var/lib/bisb/runs/{ticket}/{agent}/` | 48h (cleanup auto) |
| Degradation level | `/tmp/bisb-degrade-level` | 1h auto-expire |
| Degradation history | `/var/lib/bisb/data/degrade-history.jsonl` | Permanent |
| SLO history | `/var/lib/bisb/data/slo-history.jsonl` | Permanent |

---

## 12. Model Selection Strategy

### 12.1 Tiered Model Usage

```
                    +---------+
                    |  OPUS   |   Decisions critiques :
                    | (rare)  |   splits, fichiers sensibles
                    +----+----+
                         |
                    +----v----+
                    | SONNET  |   Travail principal :
                    | (main)  |   code, specs, QA, archi
                    +----+----+
                         |
                    +----v----+
                    | HAIKU   |   Taches simples :
                    | (cheap) |   ceremonies, fast-paths, fallback
                    +---------+
```

### 12.2 Rate Limit Fallback

Quand Sonnet hit 429 :
- **Non-critique** (Layla, Omar, ceremonies) → fallback Haiku
- **Critique** (Youssef dev, Nadia sensitive, Salma split) → WAIT (skip run)
- Flag auto-clear apres 15 minutes

---

## 13. Retry & Escalation Flow

```
Agent run
    ↓
EXIT 0 → SUCCESS → cb_reset() → log_metric()
    ↓
EXIT != 0 → classify_error()
    ↓
PERMANENT → escalade immediate (Omar + blacklist)
RATE_LIMIT → set dep flag + Haiku fallback
TIMEOUT → increment retry + backoff
TRANSIENT → backoff (60s→240s→600s→1800s ±30% jitter)
BAD_OUTPUT → backoff standard
    ↓
retry_count >= 3?
    ↓
YES → handoff Omar + blacklist 1h + poison pill check
NO  → wait for backoff expiry → retry next cycle
    ↓
poison pill (3+ blacklists in 24h)?
    ↓
YES → Needs Human (Hedi)
```

---

## 14. Cron Configuration (VPS)

```cron
# Dispatch — toutes les 15 min avec flock anti-chevauchement
*/15 * * * * flock -n /tmp/bisb-dispatch.lock /opt/bisb-scripts/agent-cron.sh

# DM Poller — toutes les 2 min
*/2 * * * * /opt/bisb-scripts/agent-dm-poller.sh

# Watchdog — toutes les heures
0 * * * * /opt/bisb-scripts/watchdog.sh

# Standup — lun-ven 08:00 UTC
0 8 * * 1-5 /opt/bisb-scripts/run-standup.sh

# Refinement — mercredi 13:00 UTC
0 13 * * 4 /opt/bisb-scripts/ceremony-refinement.sh

# Weekly reset
50 8 * * 1 reset-hedi-changes.sh
```

---

## 15. Comparaison avec SquareInvest (SI)

| Aspect | SI | BISB |
|--------|-----|------|
| **Orchestration** | n8n workflows (9 JSON) | Pure bash + cron |
| **Tracker** | Jira Cloud | Plane (self-hosted) |
| **Dispatch** | Labels (Jira) | Assignees + states (Plane) |
| **Ceremonies** | n8n Wait nodes + webhooks | Bash sequential + orchestrator |
| **Conversations** | Cumulative (n8n loop) | Cumulative (ported) |
| **Standup** | Actionnable (Salma decisions) | Actionnable (ported) |
| **Circuit breakers** | Label removal | File-based per-agent |
| **Cron interval** | 15 min | 15 min (was 5) |
| **Timeout** | No timeout | 1800s |
| **Force-loop** | None | Deprecie (48 cycle auto-expiry) |
| **Budget** | 3-tier | 3-tier + per-agent shares |
| **Guardrails** | In agent code | Dedicated script (8 checks) |
| **Watchdog** | None | Hourly self-healing |
| **Error classification** | None | 5 types + backoff |
| **RAM used** | ~2GB (n8n) | ~500MB (bash only) |

---

## 16. Known Limitations

1. ~~**Pas d'event sourcing**~~ ✅ Implemente (event-log.sh — JSONL immutable)
2. **Pas de priority queue** — tickets traites dans l'ordre d'apparition Plane
3. **Pas de dependency tracking** — pas de "B depend de A"
4. **Pas de A/B testing** — pas de versioning des prompts agent
5. **Pas de confidence scoring** — agents n'evaluent pas la qualite de leur output
6. **Pas de dry-run mode** — pas de simulation sans effets de bord
7. **Pas de tests du pipeline** — si un script casse, on decouvre au runtime
8. **Isolation limitee** — tous les agents partagent le meme user Linux et le meme repo
9. ~~**Pas de degradation gracieuse**~~ ✅ Implemente (degrade.sh — 4 niveaux)
10. ~~**Pas de SLO monitoring**~~ ✅ Implemente (pipeline-slo.sh — 5 checks)
11. ~~**Pas d'idempotency**~~ ✅ Implemente (idempotency-common.sh — exactly-once)

---

## 17. Roadmap Pipeline

### Court terme (1 semaine)
- [ ] Integrer guardrails dans agent-youssef.sh (appeler avant `gh pr create`)
- [ ] Ajouter circuit breaker check dans agent-cron.sh (dispatcher-level)
- [ ] Tester le watchdog en conditions reelles

### Moyen terme (2-4 semaines)
- [ ] Pipeline dry-run mode
- [ ] Agent confidence scoring
- [ ] Priority queue (tickets urgents d'abord)
- [ ] Structured logging dashboard (simple HTML page)

### Long terme (mois+)
- [ ] Event sourcing (immutable action log)
- [ ] Prompt versioning + A/B testing
- [ ] Pipeline integration tests
- [ ] Per-agent Linux users + file isolation
