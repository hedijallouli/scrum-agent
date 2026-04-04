#!/usr/bin/env bash
# =============================================================================
# ceremony-review.sh — Sprint Review "Demo Day"
# Triggered: at sprint completion (called from agent-cron.sh or manually)
# Usage: ceremony-review.sh [SPRINT_NUM]
#
# Flow:
#   1. Gather data: Done tickets, PRs, QA metrics from decisions.jsonl
#   2. Salma opens in #sprint channel
#   3. Tour de table: Youssef → Nadia → Rami → Layla → Omar
#   4. Salma closes
#   5. Add "livré en Sprint X" comment to each Done ticket
# =============================================================================
set -euo pipefail

export PATH="$HOME/.local/bin:/usr/local/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENT_NAME="salma"
source "${SCRIPT_DIR}/agent-common.sh"
load_env
source "${SCRIPT_DIR}/tracker-common.sh"
source "${SCRIPT_DIR}/ceremony-common.sh"

LOG_FILE="${LOG_DIR}/ceremony-review.log"
mkdir -p ${LOG_DIR}

log_info "=== Sprint Review Ceremony Starting ==="

# Pause agents during ceremony (idempotent — no-ops if already paused)
ceremony_pause_agents
trap 'ceremony_resume_agents' EXIT

# Cumulative conversation context
CONVERSATION=""

# ── Sprint number (arg or autodetect) ────────────────────────────────────────
SPRINT_NUM="${1:-}"
if [[ -z "$SPRINT_NUM" ]]; then
  SPRINT_NUM_FILE="${DATA_DIR}/sprints/current-sprint-num.txt"
  SPRINT_NUM=$(cat "$SPRINT_NUM_FILE" 2>/dev/null || echo "?")
fi

log_info "Sprint number: $SPRINT_NUM"

# ── Gather Done tickets this sprint ──────────────────────────────────────────
log_info "Fetching Done tickets..."

DONE_TICKETS_RAW=$(jira_search_keys_with_summaries \
  "project = ${PROJECT_KEY} AND statusCategory = 'Done' AND labels = 'sprint-active'" \
  "50" 2>/dev/null || echo "")

# If sprint-active label not in use, fall back to all Done tickets
if [[ -z "$DONE_TICKETS_RAW" ]]; then
  DONE_TICKETS_RAW=$(jira_search_keys_with_summaries \
    "project = ${PROJECT_KEY} AND statusCategory = 'Done'" \
    "30" 2>/dev/null || echo "")
fi

DONE_COUNT=$(echo "$DONE_TICKETS_RAW" | grep -c '|' 2>/dev/null || echo "0")
log_info "Done tickets: $DONE_COUNT"

# Build a readable list (BISB-X: Summary)
DONE_TICKET_LIST=$(echo "$DONE_TICKETS_RAW" | python3 -c "
import sys
lines = [l.strip() for l in sys.stdin if l.strip()]
out = []
for line in lines:
    parts = line.split('|', 1)
    key = parts[0].strip()
    summary = parts[1].strip() if len(parts) > 1 else ''
    out.append(f'  - {key}: {summary[:60]}')
print('\n'.join(out) if out else '  (aucun ticket terminé trouvé)')
" 2>/dev/null || echo "  (impossible de récupérer les tickets)")

# ── Gather PR metrics ─────────────────────────────────────────────────────────
log_info "Fetching merged PRs..."

MERGED_PRS=$(cd "${PROJECT_DIR}" && gh pr list --state merged --limit 10 \
  --json number,title,mergedAt \
  --jq '.[] | "#\(.number) \(.title[:55])"' 2>/dev/null || echo "")

MERGED_PR_COUNT=$(echo "$MERGED_PRS" | grep -c '#' 2>/dev/null || echo "0")

PR_LIST=$(echo "$MERGED_PRS" | python3 -c "
import sys
lines = [l.strip() for l in sys.stdin if l.strip()]
out = ['  - PR ' + l for l in lines[:8]]
print('\n'.join(out) if out else '  (aucune PR mergée trouvée)')
" 2>/dev/null || echo "  (impossible de récupérer les PRs)")

# ── Gather QA metrics from decisions.jsonl ───────────────────────────────────
log_info "Computing QA metrics..."

DECISIONS_FILE="${DATA_DIR}/context/projects/${PROJECT_KEY,,}/decisions.jsonl"
PASS_COUNT=0
FAIL_COUNT=0
PASS_FIRST_TRY=0

if [[ -f "$DECISIONS_FILE" ]]; then
  PASS_COUNT=$(grep -c '"decision":"PASS"' "$DECISIONS_FILE" 2>/dev/null || echo "0")
  FAIL_COUNT=$(grep -c '"decision":"FAIL"' "$DECISIONS_FILE" 2>/dev/null || echo "0")

  # First-pass rate: tickets that had PASS without any prior FAIL
  PASS_FIRST_TRY=$(python3 -c "
import json, collections

decisions = []
with open('${DECISIONS_FILE}') as f:
    for line in f:
        line = line.strip()
        if not line: continue
        try:
            decisions.append(json.loads(line))
        except:
            pass

# Group by ticket
ticket_decisions = collections.defaultdict(list)
for d in decisions:
    t = d.get('ticket', '')
    if t:
        ticket_decisions[t].append(d.get('decision', ''))

# First-pass = ticket where first QA decision was PASS
first_pass = 0
for ticket, decs in ticket_decisions.items():
    if decs and decs[0] == 'PASS':
        first_pass += 1

print(first_pass)
" 2>/dev/null || echo "0")
fi

PASS_COUNT=$(echo "$PASS_COUNT" | tr -dc '0-9'); PASS_COUNT=${PASS_COUNT:-0}
FAIL_COUNT=$(echo "$FAIL_COUNT" | tr -dc '0-9'); FAIL_COUNT=${FAIL_COUNT:-0}
PASS_FIRST_TRY=$(echo "$PASS_FIRST_TRY" | tr -dc '0-9'); PASS_FIRST_TRY=${PASS_FIRST_TRY:-0}
TOTAL_REVIEWS=$(( PASS_COUNT + FAIL_COUNT ))
if [[ "$TOTAL_REVIEWS" -gt 0 ]]; then
  QA_PERCENT=$(python3 -c "print(round($PASS_FIRST_TRY * 100 / $TOTAL_REVIEWS))" 2>/dev/null || echo "0")
else
  QA_PERCENT=0
fi

log_info "QA: ${PASS_COUNT} PASS / ${FAIL_COUNT} FAIL (first-pass rate: ${QA_PERCENT}%)"

# ── Sprint velocity & person-days ────────────────────────────────────────────
SPRINT_PD=$(sum_sprint_person_days 2>/dev/null || echo "0")
TEAM_VELOCITY=$(get_velocity 2>/dev/null || echo "N/A")
BUDGET_SUMMARY=$(get_budget_status 2>/dev/null || echo "Pas de données de coût")

# ── Agent-level ticket breakdown (for Youssef's turn) ────────────────────────
# Map tickets to agents via label_detail (best effort)
YOUSSEF_TICKETS=$(echo "$DONE_TICKETS_RAW" | python3 -c "
import sys
# Without label data in this summary, we can only list all done tickets
# Youssef will present all implementation tickets
lines = [l.strip() for l in sys.stdin if l.strip()]
keys = [l.split('|')[0].strip() for l in lines]
print(', '.join(keys[:8]) if keys else 'N/A')
" 2>/dev/null || echo "N/A")

# ── Build shared data context for Haiku prompts ───────────────────────────────
SPRINT_CONTEXT="Sprint ${SPRINT_NUM} — Projet ${PROJECT_KEY} (${PROJECT_NAME:-projet})

TICKETS TERMINÉS (${DONE_COUNT} total):
${DONE_TICKET_LIST}

PULL REQUESTS MERGÉES (${MERGED_PR_COUNT}):
${PR_LIST}

MÉTRIQUES QA:
- Tickets passés au premier essai : ${PASS_FIRST_TRY}/${TOTAL_REVIEWS} (${QA_PERCENT}%)
- Total PASS : ${PASS_COUNT} | Total FAIL : ${FAIL_COUNT}

VÉLOCITÉ & BUDGET:
- Person-days livrés : ${SPRINT_PD}
- Vélocité équipe : ${TEAM_VELOCITY}
- Budget IA utilisé : ${BUDGET_SUMMARY}"

# ─── CEREMONY START ──────────────────────────────────────────────────────────

# Open a thread root for the ceremony
CEREMONY_CHANNEL="sprint"
CEREMONY_ROOT_ID=""

# ── 1. Salma opens ────────────────────────────────────────────────────────────
log_info "Salma opens the Sprint Review..."

SALMA_OPEN="🏁 **Sprint Review — Sprint ${SPRINT_NUM} terminé !** Voici ce que l'équipe a livré :

Nous avons complété **${DONE_COUNT} tickets** ce sprint avec **${MERGED_PR_COUNT} PRs mergées**.

*Tour de table — chaque agent présente son travail. 👇*"

AGENT_NAME="salma"
if [[ "${CHAT_BACKEND:-slack}" == "mattermost" ]]; then
  CEREMONY_ROOT_ID=$(mm_post "$SALMA_OPEN" "$CEREMONY_CHANNEL" "" "" "return_id" 2>/dev/null || echo "")
else
  slack_notify "$SALMA_OPEN" "$CEREMONY_CHANNEL"
fi
sleep 30

# ── 2. Youssef: implementation review ────────────────────────────────────────
log_info "Youssef presents his work..."

YOUSSEF_PROMPT="Tu présentes ton travail lors du Sprint Review. Tu es Youssef, le Software Engineer.

Liste les tickets que tu as implémentés ce sprint. Mentionne les PRs si tu en connais.
Dis comment ça s'est passé techniquement — difficultés, solutions, qualité du code.
Format: 'J'ai livré ${PROJECT_KEY}-X et ${PROJECT_KEY}-Y. PR#N est mergé. [commentaire technique]...'
Sois concret, pas vague."

YOUSSEF_MSG=$(ceremony_haiku_turn \
  "youssef" \
  "${SCRIPT_DIR}/../ai/dev.md" \
  "$SPRINT_CONTEXT" \
  "$YOUSSEF_PROMPT")

CONVERSATION="**Youssef (Dev)** : ${YOUSSEF_MSG}"

AGENT_NAME="youssef"
if [[ "${CHAT_BACKEND:-slack}" == "mattermost" && -n "$CEREMONY_ROOT_ID" ]]; then
  mm_post "🔨 **Youssef** (Software Engineer) :\n\n${YOUSSEF_MSG}" "$CEREMONY_CHANNEL" "" "$CEREMONY_ROOT_ID"
else
  slack_notify "🔨 *Youssef (Software Engineer)* :\n\n${YOUSSEF_MSG}" "$CEREMONY_CHANNEL"
fi
sleep 30

# ── 3. Nadia: QA report ──────────────────────────────────────────────────────
log_info "Nadia presents QA report..."

NADIA_PROMPT="Tu présentes le rapport QA lors du Sprint Review. Tu es Nadia, la QA Engineer.

Données QA réelles:
- Tickets passés au 1er essai: ${PASS_FIRST_TRY}/${TOTAL_REVIEWS} (${QA_PERCENT}%)
- Total PASS: ${PASS_COUNT} | Total FAIL: ${FAIL_COUNT}

Format imposé:
'QA Report: X/Y tickets ont passé au premier essai (Z%). Points d'amélioration : [liste]. Globalement, la qualité est [évaluation honnête basée sur les données].'

Sois précise et factuelle. Si le taux est bas, dis-le clairement."

NADIA_MSG=$(ceremony_haiku_turn_cumulative \
  "nadia" \
  "${SCRIPT_DIR}/../ai/qa.md" \
  "$SPRINT_CONTEXT" \
  "$NADIA_PROMPT" \
  "$CONVERSATION")

CONVERSATION="${CONVERSATION}

**Nadia (QA)** : ${NADIA_MSG}"

AGENT_NAME="nadia"
if [[ "${CHAT_BACKEND:-slack}" == "mattermost" && -n "$CEREMONY_ROOT_ID" ]]; then
  mm_post "🔍 **Nadia** (QA Engineer) :\n\n${NADIA_MSG}" "$CEREMONY_CHANNEL" "" "$CEREMONY_ROOT_ID"
else
  slack_notify "🔍 *Nadia (QA Engineer)* :\n\n${NADIA_MSG}" "$CEREMONY_CHANNEL"
fi
sleep 30

# ── 4. Rami: architecture review ─────────────────────────────────────────────
log_info "Rami presents architecture review..."

RAMI_PROMPT="Tu présentes la perspective architecture lors du Sprint Review. Tu es Rami, l'Architecte Technique.

Évalue les changements de ce sprint: sont-ils propres architecturalement?
La dette technique a-t-elle augmenté ou diminué?
Y a-t-il un point d'attention spécifique pour le prochain sprint?

Format: 'Côté architecture : les changements sont [évaluation]. La dette tech a [augmenté/diminué/stable]. Un point d'attention : [point concret et actionnable].'
Reste pragmatique et précis."

RAMI_MSG=$(ceremony_haiku_turn_cumulative \
  "rami" \
  "${SCRIPT_DIR}/../ai/architect.md" \
  "$SPRINT_CONTEXT" \
  "$RAMI_PROMPT" \
  "$CONVERSATION")

CONVERSATION="${CONVERSATION}

**Rami (Architecte)** : ${RAMI_MSG}"

AGENT_NAME="rami"
if [[ "${CHAT_BACKEND:-slack}" == "mattermost" && -n "$CEREMONY_ROOT_ID" ]]; then
  mm_post "🏗️ **Rami** (Architecte Technique) :\n\n${RAMI_MSG}" "$CEREMONY_CHANNEL" "" "$CEREMONY_ROOT_ID"
else
  slack_notify "🏗️ *Rami (Architecte Technique)* :\n\n${RAMI_MSG}" "$CEREMONY_CHANNEL"
fi
sleep 30

# ── 5. Layla: player UX / product perspective ────────────────────────────────
log_info "Layla presents player UX perspective..."

LAYLA_PROMPT="Tu présentes la perspective utilisateur lors du Sprint Review. Tu es Layla, la Product Strategist.

Évalue ce sprint du point de vue de l'utilisateur final du projet ${PROJECT_KEY} (${PROJECT_NAME:-le projet}).
Quelle feature de ce sprint va le plus améliorer l'expérience utilisateur?
Y a-t-il une observation sur l'UX?

Format: 'Du point de vue utilisateur, ce sprint [évaluation globale]. La feature [meilleure feature] va vraiment améliorer l'expérience. [Observation UX spécifique].'
Base-toi sur le contexte du projet dans ton fichier persona."

LAYLA_MSG=$(ceremony_haiku_turn_cumulative \
  "layla" \
  "${SCRIPT_DIR}/../ai/product-marketing.md" \
  "$SPRINT_CONTEXT" \
  "$LAYLA_PROMPT" \
  "$CONVERSATION")

CONVERSATION="${CONVERSATION}

**Layla (Product)** : ${LAYLA_MSG}"

AGENT_NAME="layla"
if [[ "${CHAT_BACKEND:-slack}" == "mattermost" && -n "$CEREMONY_ROOT_ID" ]]; then
  mm_post "📊 **Layla** (Product Strategist) :\n\n${LAYLA_MSG}" "$CEREMONY_CHANNEL" "" "$CEREMONY_ROOT_ID"
else
  slack_notify "📊 *Layla (Product Strategist)* :\n\n${LAYLA_MSG}" "$CEREMONY_CHANNEL"
fi
sleep 30

# ── 6. Omar: sprint metrics summary ──────────────────────────────────────────
log_info "Omar posts sprint metrics..."

# Determine health indicator
if [[ "$QA_PERCENT" -ge 70 && "$FAIL_COUNT" -le 3 ]]; then
  HEALTH_ICON="🟢"
  HEALTH_STATUS="Sprint sain"
elif [[ "$QA_PERCENT" -ge 50 ]]; then
  HEALTH_ICON="🟡"
  HEALTH_STATUS="Quelques points à améliorer"
else
  HEALTH_ICON="🔴"
  HEALTH_STATUS="Attention à la qualité QA"
fi

OMAR_METRICS="${HEALTH_ICON} **Omar** (Scrum Master) — Métriques Sprint ${SPRINT_NUM} :

| Indicateur | Valeur |
|---|---|
| Tickets terminés | ${DONE_COUNT} |
| PRs mergées | ${MERGED_PR_COUNT} |
| Person-days livrés | ${SPRINT_PD} |
| Vélocité équipe | ${TEAM_VELOCITY} |
| QA 1er essai | ${PASS_FIRST_TRY}/${TOTAL_REVIEWS} (${QA_PERCENT}%) |
| PASS / FAIL QA | ${PASS_COUNT} / ${FAIL_COUNT} |
| Santé du sprint | ${HEALTH_ICON} ${HEALTH_STATUS} |

_Budget IA : ${BUDGET_SUMMARY}_"

AGENT_NAME="omar"
if [[ "${CHAT_BACKEND:-slack}" == "mattermost" && -n "$CEREMONY_ROOT_ID" ]]; then
  mm_post "$OMAR_METRICS" "$CEREMONY_CHANNEL" "" "$CEREMONY_ROOT_ID"
else
  slack_notify "$OMAR_METRICS" "$CEREMONY_CHANNEL"
fi
sleep 30

# ── 7. Salma closes ───────────────────────────────────────────────────────────
log_info "Salma closes the Sprint Review..."

DEPLOY_LINK=""
if [[ -n "${PROJECT_DEPLOY_URL:-}" ]]; then
  DEPLOY_LINK="

:link: **Lien de vérification** : ${PROJECT_DEPLOY_URL}
_Hedi, tu peux vérifier le résultat du sprint ici._"
fi

SALMA_CLOSE_PROMPT="Tu conclus le Sprint Review en tant que PM/PO. Tu es Salma.

Basé sur ce sprint, donne 2-3 points clés à retenir pour le backlog du prochain sprint.
Mentionne la rétro qui suit.

Format: 'Excellent sprint ! Voici les points à retenir pour le backlog : [liste concise]. On se retrouve pour la rétro !'
Reste motivante mais honnête."

SALMA_CLOSE=$(ceremony_haiku_turn_cumulative \
  "salma" \
  "${SCRIPT_DIR}/../ai/pm.md" \
  "$SPRINT_CONTEXT" \
  "$SALMA_CLOSE_PROMPT" \
  "$CONVERSATION")

AGENT_NAME="salma"
if [[ "${CHAT_BACKEND:-slack}" == "mattermost" && -n "$CEREMONY_ROOT_ID" ]]; then
  mm_post "📋 **Salma** (PM) — Clôture :\n\n${SALMA_CLOSE}${DEPLOY_LINK}" "$CEREMONY_CHANNEL" "" "$CEREMONY_ROOT_ID"
else
  slack_notify "📋 *Salma (PM) — Clôture* :\n\n${SALMA_CLOSE}${DEPLOY_LINK}" "$CEREMONY_CHANNEL"
fi

log_info "Ceremony messages posted. Now adding comments to Done tickets..."

# ── 8. Add "livré en Sprint X" comment to each Done ticket ───────────────────
COMMENT_ADDED=0
while IFS='|' read -r ticket_key ticket_summary; do
  ticket_key=$(echo "$ticket_key" | tr -d '[:space:]')
  ticket_summary=$(echo "$ticket_summary" | tr -d '[:space:]')
  [[ -z "$ticket_key" ]] && continue

  DELIVERY_COMMENT="✅ Livré en Sprint ${SPRINT_NUM}

Ce ticket a été complété et présenté lors du Sprint Review du Sprint ${SPRINT_NUM}.

- Tickets terminés ce sprint : ${DONE_COUNT}
- QA first-pass rate : ${QA_PERCENT}%
- Vélocité équipe : ${TEAM_VELOCITY}"

  jira_add_comment "$ticket_key" "$DELIVERY_COMMENT" 2>/dev/null || \
    log_error "Failed to add comment to $ticket_key"

  COMMENT_ADDED=$(( COMMENT_ADDED + 1 ))
  log_info "Added delivery comment to $ticket_key"
  sleep 1  # Rate-limit Plane/Jira API
done <<< "$DONE_TICKETS_RAW"

log_success "=== Sprint Review Complete: ${DONE_COUNT} tickets reviewed, ${COMMENT_ADDED} comments added ==="
