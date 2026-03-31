#!/usr/bin/env bash
# =============================================================================
# ceremony-retro.sh — Sprint Retrospective ceremony
#
# Structure:
#   Omar opens in #sprint channel
#   Round 1 — Ce qui a bien marché (Salma, Youssef, Nadia, Rami, Layla)
#   Round 2 — Ce qu'on améliore   (Salma, Youssef, Nadia, Rami, Layla)
#             + optional PR-limit disagreement thread (40% probability)
#   Round 3 — Action items (Haiku-generated, voted, created as Plane tickets)
#   Omar closes
#
# Triggered by agent-cron.sh after sprint completion, or manually.
# =============================================================================
set -euo pipefail

export PATH="$HOME/.local/bin:/usr/local/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENT_NAME="omar"
source "${SCRIPT_DIR}/agent-common.sh"
source "${SCRIPT_DIR}/ceremony-common.sh"

LOG_FILE="${LOG_DIR}/ceremony-retro-$(date '+%Y-%m-%dT%H:%M:%S').log"
mkdir -p ${LOG_DIR}
log_info "=== Sprint Retrospective Starting ==="

# ─────────────────────────────────────────────────────────────────────────────
# GATHER REAL SPRINT METRICS
# ─────────────────────────────────────────────────────────────────────────────
log_info "Gathering sprint metrics..."

DECISIONS_FILE="${DATA_DIR}/context/projects/${PROJECT_KEY,,}/decisions.jsonl"
PASS_COUNT=0
FAIL_COUNT=0
PINGPONG_COUNT=0
if [[ -f "$DECISIONS_FILE" ]]; then
  PASS_COUNT=$(grep -c '"decision":"PASS"' "$DECISIONS_FILE" 2>/dev/null || echo "0")
  FAIL_COUNT=$(grep -c '"decision":"FAIL"' "$DECISIONS_FILE" 2>/dev/null || echo "0")
  PINGPONG_COUNT=$(python3 -c "
import json
decisions = []
try:
    with open('$DECISIONS_FILE') as f:
        for line in f:
            try: decisions.append(json.loads(line.strip()))
            except: pass
except: pass
tickets = {}
for d in decisions:
    t = d.get('ticket','')
    if d.get('decision') == 'FAIL':
        tickets[t] = tickets.get(t, 0) + 1
print(sum(1 for v in tickets.values() if v >= 2))
" 2>/dev/null || echo "0")
fi

TOTAL_REVIEWS=$(( PASS_COUNT + FAIL_COUNT ))
QA_PASS_RATE="N/A"
if (( TOTAL_REVIEWS > 0 )); then
  QA_PASS_RATE=$(python3 -c "print(f'{round($PASS_COUNT * 100 / $TOTAL_REVIEWS)}%')" 2>/dev/null || echo "N/A")
fi

# Retry / stuck ticket count
TOTAL_RETRIES=0
STUCK_TICKETS=""
for retry_file in /tmp/${PROJECT_PREFIX}-retries/${PROJECT_KEY}-*; do
  [[ -f "$retry_file" ]] || continue
  cnt=$(cat "$retry_file" 2>/dev/null || echo "0")
  TOTAL_RETRIES=$(( TOTAL_RETRIES + cnt ))
  if [[ "$cnt" -ge 2 ]]; then
    STUCK_TICKETS="${STUCK_TICKETS}$(basename "$retry_file")(${cnt}x) "
  fi
done

# Recent log errors
RECENT_ERRORS=$(tail -100 ${LOG_DIR}/cron.log 2>/dev/null \
  | grep -iE 'error|fail|stuck|blocked|timeout' | tail -10 \
  || echo "Aucune erreur récente")

# Sprint ticket counts
DONE_COUNT=$(jira_search_keys "project = ${JIRA_PROJECT} AND labels = 'sprint-active' AND statusCategory = 'Done'" "50" 2>/dev/null | wc -l | tr -d ' ' || echo "0")
TOTAL_COUNT=$(jira_search_keys "project = ${JIRA_PROJECT} AND labels = 'sprint-active'" "50" 2>/dev/null | wc -l | tr -d ' ' || echo "0")

SPRINT_PD=$(sum_sprint_person_days)
CURRENT_VELOCITY=$(get_velocity)
COST_SUMMARY=$(get_budget_status 2>/dev/null || echo "No cost data")

# Open PRs count
OPEN_PRS_COUNT=$(cd "$PROJECT_DIR" && gh pr list --state open --json number --limit 20 2>/dev/null \
  | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")

# Build a compact data context string for Haiku
SPRINT_DATA_CONTEXT="Projet: ${PROJECT_KEY} — ${PROJECT_NAME:-BisB}
Tickets complétés: ${DONE_COUNT}/${TOTAL_COUNT}
Person-days livrés: ${SPRINT_PD}
Vélocité (moy 3 sprints): ${CURRENT_VELOCITY}
QA first-pass rate: ${QA_PASS_RATE} (${PASS_COUNT} PASS / ${FAIL_COUNT} FAIL)
Tickets ping-pong (>2 round-trips): ${PINGPONG_COUNT}
Total retries agents: ${TOTAL_RETRIES}
PRs ouvertes: ${OPEN_PRS_COUNT}
Coût API aujourd'hui: ${COST_SUMMARY}
Erreurs récentes: ${RECENT_ERRORS}"

log_info "Metrics: ${DONE_COUNT}/${TOTAL_COUNT} done, QA=${QA_PASS_RATE}, retries=${TOTAL_RETRIES}, pingpong=${PINGPONG_COUNT}"

# ─────────────────────────────────────────────────────────────────────────────
# PERSONA FILES
# ─────────────────────────────────────────────────────────────────────────────
PM_PERSONA="${SCRIPT_DIR}/../ai/pm.md"
DEV_PERSONA="${SCRIPT_DIR}/../ai/dev.md"
QA_PERSONA="${SCRIPT_DIR}/../ai/qa.md"
ARCH_PERSONA="${SCRIPT_DIR}/../ai/architect.md"
OPS_PERSONA="${SCRIPT_DIR}/../ai/ops.md"
PRODUCT_PERSONA="${SCRIPT_DIR}/../ai/product-marketing.md"

# ─────────────────────────────────────────────────────────────────────────────
# OMAR OPENS — root post in #sprint channel
# ─────────────────────────────────────────────────────────────────────────────
log_info "Omar opening retro..."

RETRO_DATE=$(date '+%d %B %Y')
OPEN_MSG="📋 **Sprint Retrospective — ${RETRO_DATE}**

Équipe, le sprint est terminé. Prenons 30 minutes pour en tirer les bonnes leçons.

**Résultat sprint :** ${DONE_COUNT}/${TOTAL_COUNT} tickets ✅ | ${SPRINT_PD} person-days | vélocité ${CURRENT_VELOCITY}
**QA first-pass :** ${QA_PASS_RATE} | Retries : ${TOTAL_RETRIES} | Ping-pong : ${PINGPONG_COUNT}

On procède en trois tours :
1️⃣ Ce qui a bien marché
2️⃣ Ce qu'on améliore
3️⃣ Action items concrets

$(mm_mention salma 2>/dev/null || echo "@salma") $(mm_mention youssef 2>/dev/null || echo "@youssef") $(mm_mention nadia 2>/dev/null || echo "@nadia") $(mm_mention rami 2>/dev/null || echo "@rami") $(mm_mention layla 2>/dev/null || echo "@layla") — c'est parti 🚀"

ROOT_POST_ID=$(ceremony_post "omar" "$OPEN_MSG" "sprint" "")
log_info "Root post ID: ${ROOT_POST_ID:-none}"

# ─────────────────────────────────────────────────────────────────────────────
# ROUND 1 — CE QUI A BIEN MARCHÉ
# ─────────────────────────────────────────────────────────────────────────────
log_info "Round 1: Ce qui a bien marché"

SAVED_AGENT="$AGENT_NAME"
AGENT_NAME="omar"
if [[ "${CHAT_BACKEND:-slack}" == "mattermost" ]]; then
  mm_post "**Ronde 1 — Ce qui a bien marché** 💚" "sprint" "" "$ROOT_POST_ID" > /dev/null 2>&1 || true
else
  slack_notify "**Ronde 1 — Ce qui a bien marché** 💚" "sprint"
fi
AGENT_NAME="$SAVED_AGENT"
sleep 30

ROUND1_TASK="Tu participes à la rétrospective de sprint. C'est la ronde 1 : ce qui a bien marché.
Partage UNE seule chose positive basée sur les données du sprint.
Sois spécifique et ancré dans les métriques réelles (ex: taux QA, nombre tickets, vélocité).
Commence par '✅' et une phrase courte."

for AGENT in salma youssef nadia rami layla; do
  case "$AGENT" in
    salma)   PERSONA="$PM_PERSONA" ;;
    youssef) PERSONA="$DEV_PERSONA" ;;
    nadia)   PERSONA="$QA_PERSONA" ;;
    rami)    PERSONA="$ARCH_PERSONA" ;;
    layla)   PERSONA="$PRODUCT_PERSONA" ;;
  esac

  MSG=$(ceremony_haiku_turn "$AGENT" "$PERSONA" "$SPRINT_DATA_CONTEXT" "$ROUND1_TASK")
  ceremony_post "$AGENT" "$MSG" "sprint" "$ROOT_POST_ID" > /dev/null
  log_info "Round1: ${AGENT} done"
done

# ─────────────────────────────────────────────────────────────────────────────
# ROUND 2 — CE QU'ON AMÉLIORE
# ─────────────────────────────────────────────────────────────────────────────
log_info "Round 2: Ce qu'on améliore"

SAVED_AGENT="$AGENT_NAME"
AGENT_NAME="omar"
if [[ "${CHAT_BACKEND:-slack}" == "mattermost" ]]; then
  mm_post "**Ronde 2 — Ce qu'on améliore** 🔧" "sprint" "" "$ROOT_POST_ID" > /dev/null 2>&1 || true
else
  slack_notify "**Ronde 2 — Ce qu'on améliore** 🔧" "sprint"
fi
AGENT_NAME="$SAVED_AGENT"
sleep 30

ROUND2_TASK="Tu participes à la rétrospective de sprint. C'est la ronde 2 : ce qu'on améliore.
Propose UNE seule amélioration de processus, basée sur les données concrètes.
Sois précis : nomme le problème et propose une action mesurable.
Commence par '🔧' et une phrase courte."

for AGENT in salma youssef nadia rami layla; do
  case "$AGENT" in
    salma)   PERSONA="$PM_PERSONA" ;;
    youssef) PERSONA="$DEV_PERSONA" ;;
    nadia)   PERSONA="$QA_PERSONA" ;;
    rami)    PERSONA="$ARCH_PERSONA" ;;
    layla)   PERSONA="$PRODUCT_PERSONA" ;;
  esac

  MSG=$(ceremony_haiku_turn "$AGENT" "$PERSONA" "$SPRINT_DATA_CONTEXT" "$ROUND2_TASK")
  ceremony_post "$AGENT" "$MSG" "sprint" "$ROOT_POST_ID" > /dev/null
  log_info "Round2: ${AGENT} done"
done

# ─────────────────────────────────────────────────────────────────────────────
# OPTIONAL DISAGREEMENT — limite PR 300 lignes (40% probability)
# ─────────────────────────────────────────────────────────────────────────────
if maybe_disagree 40; then
  log_info "Disagreement triggered: PR size limit debate"

  PR_LIMIT="${PROJECT_MAX_PR_LINES:-300}"

  # Youssef propose de relaxer la limite
  YOUSSEF_ARG=$(ceremony_haiku_turn "youssef" "$DEV_PERSONA" "$SPRINT_DATA_CONTEXT" \
    "Tu proposes de monter la limite de PRs de ${PR_LIMIT} à 400 lignes, car certains refactors complexes en ont besoin. Argumente en 2 phrases max. Commence par '💬 Youssef :'")
  ceremony_post "youssef" "$YOUSSEF_ARG" "sprint" "$ROOT_POST_ID" > /dev/null

  # Nadia défend avec données
  NADIA_ARG=$(ceremony_haiku_turn "nadia" "$QA_PERSONA" "$SPRINT_DATA_CONTEXT" \
    "Tu défends la limite de ${PR_LIMIT} lignes avec une donnée précise sur la qualité (ex: les PRs >300 ont plus de bugs selon les métriques). 2 phrases max. Commence par '💬 Nadia :'")
  ceremony_post "nadia" "$NADIA_ARG" "sprint" "$ROOT_POST_ID" > /dev/null

  # Rami médie
  RAMI_MEDIATION=$(ceremony_haiku_turn "rami" "$ARCH_PERSONA" "$SPRINT_DATA_CONTEXT" \
    "Tu médiates le débat entre Youssef et Nadia sur la limite de taille de PRs. Tu proposes un compromis : 300 lignes par défaut, 400 avec justification explicite dans la PR. 2 phrases max. Commence par '💬 Rami :'")
  ceremony_post "rami" "$RAMI_MEDIATION" "sprint" "$ROOT_POST_ID" > /dev/null

  # Salma clôt la discussion — pas de sleep entre ces posts rapides
  SAVED_AGENT="$AGENT_NAME"
  AGENT_NAME="salma"
  SALMA_CLOSE="💬 **Salma :** Adopté ! On documente ça dans nos normes : limite 300 lignes par défaut, 400 lignes avec justification technique dans la PR description. Youssef, tu mets à jour le CLAUDE.md ?"
  if [[ "${CHAT_BACKEND:-slack}" == "mattermost" ]]; then
    mm_post "$SALMA_CLOSE" "sprint" "" "$ROOT_POST_ID" > /dev/null 2>&1 || true
  else
    slack_notify "$SALMA_CLOSE" "sprint"
  fi
  AGENT_NAME="$SAVED_AGENT"
  sleep 5

  log_info "Disagreement discussion complete"
fi

# ─────────────────────────────────────────────────────────────────────────────
# ROUND 3 — ACTION ITEMS (Haiku generates 3, agents vote, tickets créés)
# ─────────────────────────────────────────────────────────────────────────────
log_info "Round 3: Action items"

SAVED_AGENT="$AGENT_NAME"
AGENT_NAME="omar"
if [[ "${CHAT_BACKEND:-slack}" == "mattermost" ]]; then
  mm_post "**Ronde 3 — Action items** 🎯" "sprint" "" "$ROOT_POST_ID" > /dev/null 2>&1 || true
else
  slack_notify "**Ronde 3 — Action items** 🎯" "sprint"
fi
AGENT_NAME="$SAVED_AGENT"
sleep 30

# Haiku génère 3 action items basés sur les vraies métriques
ACTION_ITEMS_RAW=$(claude -p --model claude-haiku-4-5 --max-turns 1 "
Tu es Omar, Scrum Master du projet ${PROJECT_KEY} (jeu de plateau tunisien Business is Business).
Analyse les métriques du sprint et génère EXACTEMENT 3 action items.

MÉTRIQUES RÉELLES :
${SPRINT_DATA_CONTEXT}

Règles :
- Chaque action doit être ancrée dans une métrique concrète
- Chaque action doit être assignable à un agent spécifique (youssef/nadia/rami/omar/salma)
- Chaque action doit être mesurable (critère de succès au prochain sprint)
- Pipeline/scripts/automation → assigner à youssef

SORTIE : exactement 3 lignes, format strict :
ACTION|résumé court (max 80 chars)|agent_assigné|raison_en_10_mots

Exemple :
ACTION|Ajouter pre-QA self-check dans agent Youssef|youssef|First-pass QA 60%, cible 75% prochain sprint
ACTION|Réduire timeout agent de 600s à 300s|omar|3 timeouts ce sprint ralentissent le pipeline
ACTION|Intégration tests PropertySystem manquants|nadia|2 bugs prod liés à system non couvert
" 2>/dev/null || echo "")

log_info "Action items raw output generated"

# Parse les action items
ACTION_SUMMARIES=()
ACTION_AGENTS=()
ACTION_REASONS=()

while IFS='|' read -r marker summary agent reason; do
  [[ "$marker" != "ACTION" ]] && continue
  [[ -z "$summary" ]] && continue
  ACTION_SUMMARIES+=("$summary")
  ACTION_AGENTS+=("${agent:-youssef}")
  ACTION_REASONS+=("${reason:-amélioration identifiée lors de la rétro}")
done <<< "$ACTION_ITEMS_RAW"

# Si Haiku n'a pas répondu correctement, fallback
if [[ ${#ACTION_SUMMARIES[@]} -eq 0 ]]; then
  ACTION_SUMMARIES=(
    "Améliorer le taux de premier passage QA"
    "Réduire les retries agents par meilleure spec"
    "Ajouter tests d'intégration pour le moteur de jeu"
  )
  ACTION_AGENTS=("nadia" "salma" "youssef")
  ACTION_REASONS=(
    "QA first-pass rate à améliorer selon métriques sprint"
    "${TOTAL_RETRIES} retries détectés ce sprint"
    "Couverture de tests insuffisante sur les systèmes core"
  )
fi

# Afficher les action items proposés
ITEMS_MSG="**Omar propose les action items suivants pour le prochain sprint :**"
for i in "${!ACTION_SUMMARIES[@]}"; do
  ITEMS_MSG="${ITEMS_MSG}
$((i+1)). 📌 **${ACTION_SUMMARIES[$i]}** → assigné à *${ACTION_AGENTS[$i]}*
   _Raison : ${ACTION_REASONS[$i]}_"
done
ITEMS_MSG="${ITEMS_MSG}

${AGENT_CATCHPHRASE[omar]}"

SAVED_AGENT="$AGENT_NAME"
AGENT_NAME="omar"
if [[ "${CHAT_BACKEND:-slack}" == "mattermost" ]]; then
  mm_post "$ITEMS_MSG" "sprint" "" "$ROOT_POST_ID" > /dev/null 2>&1 || true
else
  slack_notify "$ITEMS_MSG" "sprint"
fi
AGENT_NAME="$SAVED_AGENT"
sleep 30

# Chaque agent vote
VOTE_TASK="C'est la ronde de vote pour les action items de la rétro.
Exprime ton engagement ou une réserve sur l'un des points.
Commence par '✅ Je m'y engage' si tu es d'accord, ou '⚠️ Réserve :' si tu as une inquiétude.
1 phrase max."

for AGENT in salma youssef nadia rami layla; do
  case "$AGENT" in
    salma)   PERSONA="$PM_PERSONA" ;;
    youssef) PERSONA="$DEV_PERSONA" ;;
    nadia)   PERSONA="$QA_PERSONA" ;;
    rami)    PERSONA="$ARCH_PERSONA" ;;
    layla)   PERSONA="$PRODUCT_PERSONA" ;;
  esac

  VOTE_MSG=$(ceremony_haiku_turn "$AGENT" "$PERSONA" \
    "${SPRINT_DATA_CONTEXT}
Action items proposés: ${ACTION_SUMMARIES[*]:-}" \
    "$VOTE_TASK")
  ceremony_post "$AGENT" "$VOTE_MSG" "sprint" "$ROOT_POST_ID" > /dev/null
  log_info "Vote: ${AGENT} done"
done

# ─────────────────────────────────────────────────────────────────────────────
# CRÉER LES TICKETS PLANE POUR LES ACTION ITEMS
# ─────────────────────────────────────────────────────────────────────────────
log_info "Creating Plane tickets for action items..."

CREATED_TICKETS=()
for i in "${!ACTION_SUMMARIES[@]}"; do
  SUMMARY="[Retro] ${ACTION_SUMMARIES[$i]}"
  ASSIGNED_AGENT="${ACTION_AGENTS[$i]}"
  REASON="${ACTION_REASONS[$i]}"

  TICKET_KEY=$(jira_create_ticket "$SUMMARY" 2>/dev/null || echo "")
  if [[ -n "$TICKET_KEY" ]]; then
    jira_add_label "$TICKET_KEY" "retro-action" 2>/dev/null || true
    jira_add_label "$TICKET_KEY" "agent:${ASSIGNED_AGENT}" 2>/dev/null || true

    # Si l'action concerne pipeline/scripts/automation → assigner explicitement à Youssef + label self-improve
    if echo "${SUMMARY}${REASON}" | grep -iqE 'script|pipeline|automation|cron|agent.*improve|améliorer.*agent|n8n|bash'; then
      jira_add_label "$TICKET_KEY" "agent:youssef" 2>/dev/null || true
      jira_add_label "$TICKET_KEY" "self-improve" 2>/dev/null || true
      plane_assign_ticket "$TICKET_KEY" "youssef" 2>/dev/null || true
      ASSIGNED_AGENT="youssef"
      log_info "Self-improvement ticket ${TICKET_KEY} assigned to Youssef (pipeline/scripts) + label self-improve"
    else
      plane_assign_ticket "$TICKET_KEY" "$ASSIGNED_AGENT" 2>/dev/null || true
    fi

    save_estimate "$TICKET_KEY" "0.5" "3" "M" "omar" 2>/dev/null || true
    CREATED_TICKETS+=("${TICKET_KEY} (${ASSIGNED_AGENT})")
    log_info "Created retro ticket: ${TICKET_KEY} → ${ASSIGNED_AGENT}"

    # ── Write to cross-ceremony memory (ceremony-decisions.jsonl) ────────────
    DECISIONS_FILE="/var/lib/bisb/data/ceremony-decisions.jsonl"
    mkdir -p "$(dirname "$DECISIONS_FILE")" 2>/dev/null || true
    TS=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    # Escape double quotes for JSON safety
    DECISION_JSON=$(echo "${ACTION_SUMMARIES[$i]}" | tr '"' "'" | tr $'\n' ' ')
    REASON_JSON=$(echo "${ACTION_REASONS[$i]}" | tr '"' "'" | tr $'\n' ' ')
    printf '{"ts":"%s","ceremony":"retro","sprint":"%s","decision":"%s","owner":"%s","ticket":"%s","reason":"%s"}\n' \
      "$TS" "${PROJECT_KEY} — ${RETRO_DATE}" "$DECISION_JSON" "$ASSIGNED_AGENT" "$TICKET_KEY" "$REASON_JSON" \
      >> "$DECISIONS_FILE" 2>/dev/null || true
  fi
done

# ─────────────────────────────────────────────────────────────────────────────
# OMAR FERME LA RÉTRO
# ─────────────────────────────────────────────────────────────────────────────
log_info "Omar closing retro..."

NEXT_PLANNING_DAYS=2
TICKETS_LIST=""
for t in "${CREATED_TICKETS[@]}"; do
  TICKETS_LIST="${TICKETS_LIST}  • ${t}\n"
done
[[ -z "$TICKETS_LIST" ]] && TICKETS_LIST="  Aucun ticket créé\n"

# Mention Youssef pour les self-improvement tickets
YOUSSEF_MENTION=""
for t in "${CREATED_TICKETS[@]}"; do
  if echo "$t" | grep -q "youssef"; then
    YOUSSEF_MENTION="
$(mm_mention youssef 2>/dev/null || echo "@youssef") : les action items pipeline/scripts sont dans ta pile — crée une PR propre pour chacun 🛠️"
    break
  fi
done

CLOSE_MSG="**Résumé de la rétro — ${RETRO_DATE}** ✅

**Tickets action créés :**
$(printf '%b' "$TICKETS_LIST")
**Stats sprint clôturé :**
  • ${DONE_COUNT}/${TOTAL_COUNT} tickets terminés
  • QA first-pass : ${QA_PASS_RATE}
  • Retries : ${TOTAL_RETRIES} | Ping-pong : ${PINGPONG_COUNT}
  • Vélocité : ${CURRENT_VELOCITY}
${YOUSSEF_MENTION}

**Next: Planning dans ${NEXT_PLANNING_DAYS} jours** 📅

Merci à tous. On s'améliore sprint après sprint. 💪"

ceremony_post "omar" "$CLOSE_MSG" "sprint" "$ROOT_POST_ID" > /dev/null

log_activity "omar" "ceremony-retro" "INFO" "Retro completed: ${#CREATED_TICKETS[@]} action items, QA=${QA_PASS_RATE}, retries=${TOTAL_RETRIES}"
log_success "=== Sprint Retrospective Complete (${SECONDS}s) ==="
