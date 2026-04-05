#!/usr/bin/env bash
# =============================================================================
# ceremony-planning.sh — Sprint Planning ceremony
#
# Structure:
#   Salma opens in #sprint: propose sprint goal based on backlog priorities
#   Part 1 — WHAT (tour de table)
#     Layla:   player / market perspective on top candidates
#     Rami:    architectural concerns / technical debt
#     Nadia:   QA scope concerns
#     Youssef: effort estimates (S/M/L/XL)
#   Optional disagreement (25%) — Youssef vs Nadia on scope grouping
#   Part 2 — HOW (developers only)
#     Rami:    recommended technical approach
#     Youssef: implementation order and handoff to Nadia
#   Vote round (all agents)
#   Salma finalises sprint goal
#   Assign selected tickets in Plane (Youssef=dev, Nadia=QA)
#   Update Plane cycle description with sprint goal
#   Omar closes with sprint summary
# =============================================================================
set -euo pipefail

export PATH="$HOME/.local/bin:/usr/local/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENT_NAME="salma"
source "${SCRIPT_DIR}/agent-common.sh"
source "${SCRIPT_DIR}/ceremony-common.sh"

LOG_FILE="${LOG_DIR}/ceremony-planning-$(date '+%Y-%m-%dT%H:%M:%S').log"
mkdir -p ${LOG_DIR}
log_info "=== Sprint Planning Starting ==="

# ── Set ceremony flag to prevent false ceremony triggers while planning runs ──
# (The cron's sprint-completion check fires if it finds the previous cycle done
#  before the new cycle is created. Setting the flag early prevents this.)
CEREMONY_FLAG="/tmp/${PROJECT_PREFIX}-ceremony-done-$(date -u +%Y%m%d)"
touch "$CEREMONY_FLAG" 2>/dev/null || true

# ─────────────────────────────────────────────────────────────────────────────
# GATHER BACKLOG + CAPACITY + VELOCITY
# ─────────────────────────────────────────────────────────────────────────────
log_info "Gathering backlog and team capacity..."

# Top 20 unassigned, not Done backlog tickets
BACKLOG_RAW=$(jira_get_backlog_tickets 20 2>/dev/null || echo "")
BACKLOG_COUNT=$(echo "$BACKLOG_RAW" | grep -c "${PROJECT_KEY}-" 2>/dev/null || echo "0")

# Previous velocity + capacity calculation
SPRINT_VELOCITY=$(get_velocity)
TEAM_CAPACITY_PD="14.0"   # 4 dev agents × 5 days × 0.7 efficiency
ADJUSTED_CAPACITY=$(python3 -c "
v = float('${SPRINT_VELOCITY}')
cap = float('${TEAM_CAPACITY_PD}')
adj = min(1.0, max(0.5, v))
print(round(cap * adj, 1))
" 2>/dev/null || echo "10.0")

# QA metrics from last sprint
DECISIONS_FILE="${DATA_DIR}/context/projects/${PROJECT_KEY,,}/decisions.jsonl"
PASS_COUNT=0
FAIL_COUNT=0
if [[ -f "$DECISIONS_FILE" ]]; then
  PASS_COUNT=$(grep -c '"decision":"PASS"' "$DECISIONS_FILE" 2>/dev/null || echo "0")
  FAIL_COUNT=$(grep -c '"decision":"FAIL"' "$DECISIONS_FILE" 2>/dev/null || echo "0")
fi
PASS_COUNT=$(echo "$PASS_COUNT" | tr -dc '0-9'); PASS_COUNT=${PASS_COUNT:-0}
FAIL_COUNT=$(echo "$FAIL_COUNT" | tr -dc '0-9'); FAIL_COUNT=${FAIL_COUNT:-0}
TOTAL_REVIEWS=$(( PASS_COUNT + FAIL_COUNT ))
QA_PASS_RATE="N/A"
if (( TOTAL_REVIEWS > 0 )); then
  QA_PASS_RATE=$(python3 -c "print(f'{round($PASS_COUNT * 100 / $TOTAL_REVIEWS)}%')" 2>/dev/null || echo "N/A")
fi

COST_SUMMARY=$(get_budget_status 2>/dev/null || echo "No cost data")

# Extract top 5 candidate tickets for discussion
TOP_CANDIDATES=$(echo "$BACKLOG_RAW" | head -5)
TOP_KEYS=$(echo "$TOP_CANDIDATES" | grep -oP "${PROJECT_KEY}-\d+" | head -5 || echo "")
TOP_FIRST_KEY=$(echo "$TOP_KEYS" | head -1 || echo "")

# Read recent retro decisions for cross-ceremony memory
DECISIONS_FILE="/var/lib/${PROJECT_PREFIX}/data/ceremony-decisions.jsonl"
RECENT_DECISIONS_PLANNING=""
if [[ -f "$DECISIONS_FILE" ]]; then
  RECENT_DECISIONS_PLANNING=$(tail -5 "$DECISIONS_FILE" 2>/dev/null | python3 -c "
import sys, json
lines = []
for l in sys.stdin:
    l = l.strip()
    if l:
        try:
            d = json.loads(l)
            lines.append(d)
        except Exception:
            pass
recent = lines[-3:]
if recent:
    print('Engagements retro a respecter ce sprint :')
    for d in recent:
        print(f'  - {d.get(\"decision\",\"\")} (owner: {d.get(\"owner\",\"\")})')
" 2>/dev/null || true)
fi

PLANNING_CONTEXT="Projet: ${PROJECT_KEY} — ${PROJECT_NAME:-BisB (Business is Business)}
Backlog disponible: ${BACKLOG_COUNT} tickets non assignés
Capacité équipe: ${ADJUSTED_CAPACITY} person-days (vélocité: ${SPRINT_VELOCITY})
QA first-pass (sprint précédent): ${QA_PASS_RATE}
Top tickets candidats:
${TOP_CANDIDATES}
Budget API: ${COST_SUMMARY}
${RECENT_DECISIONS_PLANNING}"

log_info "Backlog: ${BACKLOG_COUNT} tickets, capacity: ${ADJUSTED_CAPACITY} PD, velocity: ${SPRINT_VELOCITY}"

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
# SALMA OUVRE — propose le sprint goal
# ─────────────────────────────────────────────────────────────────────────────
log_info "Salma opening planning..."

SPRINT_GOAL_PROPOSAL=$(ceremony_haiku_turn "salma" "$PM_PERSONA" "$PLANNING_CONTEXT" \
  "Tu ouvres le Sprint Planning. Propose un sprint goal clair basé sur les tickets prioritaires du backlog.
Le sprint goal doit être en 1 phrase inspirante, axée sur la valeur joueur.
Ensuite, liste les 3-5 tickets prioritaires que tu proposes d'inclure.
Commence par '🎯 Sprint Planning — [date]'.")

PLANNING_DATE=$(date '+%d %B %Y')
OPEN_MSG="🗓️ **Sprint Planning — ${PLANNING_DATE}**

Capacité équipe : **${ADJUSTED_CAPACITY} person-days** | Vélocité : ${SPRINT_VELOCITY}
Backlog : ${BACKLOG_COUNT} tickets disponibles

${SPRINT_GOAL_PROPOSAL}

$(mm_mention layla 2>/dev/null || echo "@layla") $(mm_mention rami 2>/dev/null || echo "@rami") $(mm_mention nadia 2>/dev/null || echo "@nadia") $(mm_mention youssef 2>/dev/null || echo "@youssef") — on commence ! 👇"

ROOT_POST_ID=$(ceremony_post "salma" "$OPEN_MSG" "sprint" "")
log_info "Root post ID: ${ROOT_POST_ID:-none}"

# ─────────────────────────────────────────────────────────────────────────────
# PART 1 — WHAT : tour de table
# ─────────────────────────────────────────────────────────────────────────────
log_info "Part 1: WHAT — tour de table"

SAVED_AGENT="$AGENT_NAME"
AGENT_NAME="omar"
if [[ "${CHAT_BACKEND:-slack}" == "mattermost" ]]; then
  mm_post "**Partie 1 — WHAT : Tour de table** 💬" "sprint" "" "$ROOT_POST_ID" > /dev/null 2>&1 || true
else
  slack_notify "**Partie 1 — WHAT : Tour de table** 💬" "sprint"
fi
AGENT_NAME="$SAVED_AGENT"
sleep 30

# ── Layla : perspective joueur / marché ──────────────────────────────────────
log_info "Layla: player perspective..."
LAYLA_MSG=$(ceremony_haiku_turn "layla" "$PRODUCT_PERSONA" "$PLANNING_CONTEXT" \
  "Tu donnes ton avis de stakeholder/Product sur les tickets prioritaires.
Indique quel ticket apportera le plus de valeur joueur.
Format : 'Du point de vue joueur, je voterai pour [ticket] car…'
1-2 phrases max.")
ceremony_post "layla" "$LAYLA_MSG" "sprint" "$ROOT_POST_ID" > /dev/null

# ── Rami : dettes techniques / architecture ───────────────────────────────────
log_info "Rami: architecture concerns..."
RAMI_MSG=$(ceremony_haiku_turn "rami" "$ARCH_PERSONA" "$PLANNING_CONTEXT" \
  "Tu identifies les concerns architecturaux sur les tickets candidats.
Mentionne les dettes techniques cachées (ex: 'BISB-X cache une dette tech : …').
Sois concret, 2 phrases max.")
ceremony_post "rami" "$RAMI_MSG" "sprint" "$ROOT_POST_ID" > /dev/null

# ── Nadia : scope QA ──────────────────────────────────────────────────────────
log_info "Nadia: QA scope..."
# Calcule le nombre de tickets proposés pour le contexte
TICKET_COUNT_IN_SPRINT=$(echo "$TOP_KEYS" | wc -l | tr -d ' ')
NADIA_MSG=$(ceremony_haiku_turn "nadia" "$QA_PERSONA" "$PLANNING_CONTEXT" \
  "Tu évalues le scope QA si on prend les ${TICKET_COUNT_IN_SPRINT} tickets candidats.
Indique si le scope QA est serré ou OK.
Format : 'Si on prend ces tickets, le scope QA est… car…'
2 phrases max.")
ceremony_post "nadia" "$NADIA_MSG" "sprint" "$ROOT_POST_ID" > /dev/null

# ── Youssef : estimations d'effort ───────────────────────────────────────────
log_info "Youssef: effort estimates..."
YOUSSEF_ESTIMATES=$(ceremony_haiku_turn "youssef" "$DEV_PERSONA" "$PLANNING_CONTEXT" \
  "Tu donnes une estimation d'effort pour chaque ticket candidat.
Utilise : S=0.5j, M=1j, L=2j, XL=3j (à splitter).
Format : liste courte '${PROJECT_KEY}-XX : M (1j) — raison'
Max 5 tickets. Sois direct et réaliste.")
ceremony_post "youssef" "$YOUSSEF_ESTIMATES" "sprint" "$ROOT_POST_ID" > /dev/null

# ─────────────────────────────────────────────────────────────────────────────
# OPTIONAL DISAGREEMENT — scope grouping (25% probability)
# ─────────────────────────────────────────────────────────────────────────────
if maybe_disagree 25 && [[ -n "$TOP_FIRST_KEY" ]]; then
  log_info "Disagreement triggered: scope grouping debate"

  # Youssef veut grouper deux tickets
  SECOND_KEY=$(echo "$TOP_KEYS" | sed -n '2p' || echo "${TOP_FIRST_KEY}")
  YOUSSEF_GROUP=$(ceremony_haiku_turn "youssef" "$DEV_PERSONA" "$PLANNING_CONTEXT" \
    "Tu proposes de grouper ${TOP_FIRST_KEY} et ${SECOND_KEY:-un autre ticket} dans une même PR car ils partagent la même logique.
Argumente en 1 phrase. Commence par '💬 Youssef :'")
  ceremony_post "youssef" "$YOUSSEF_GROUP" "sprint" "$ROOT_POST_ID" > /dev/null

  # Nadia défend une feature par PR
  NADIA_HOLD=$(ceremony_haiku_turn "nadia" "$QA_PERSONA" "$PLANNING_CONTEXT" \
    "Tu t'opposes au groupement de tickets proposé par Youssef.
La règle est : une feature par PR pour faciliter la QA.
1 phrase ferme. Commence par '💬 Nadia :'")
  ceremony_post "nadia" "$NADIA_HOLD" "sprint" "$ROOT_POST_ID" > /dev/null

  # Rami médie
  RAMI_MED=$(ceremony_haiku_turn "rami" "$ARCH_PERSONA" "$PLANNING_CONTEXT" \
    "Tu médiates le débat Youssef/Nadia sur le groupement de tickets.
Propose un compromis ou tranche. 1 phrase. Commence par '💬 Rami :'")
  ceremony_post "rami" "$RAMI_MED" "sprint" "$ROOT_POST_ID" > /dev/null

  # Omar tranche en tant que SM
  SAVED_AGENT="$AGENT_NAME"
  AGENT_NAME="omar"
  OMAR_SM_MSG="💬 **Omar (SM) :** On respecte les règles de l'équipe. $(mm_mention youssef 2>/dev/null || echo "@youssef"), 2 PRs séparées — c'est notre process pour la traçabilité QA. Si le contexte est partagé, un commentaire de cross-ref dans chaque PR suffit."
  if [[ "${CHAT_BACKEND:-slack}" == "mattermost" ]]; then
    mm_post "$OMAR_SM_MSG" "sprint" "" "$ROOT_POST_ID" > /dev/null 2>&1 || true
  else
    slack_notify "$OMAR_SM_MSG" "sprint"
  fi
  AGENT_NAME="$SAVED_AGENT"
  sleep 5

  log_info "Scope disagreement resolved"
fi

# ─────────────────────────────────────────────────────────────────────────────
# PART 2 — HOW : developers only
# ─────────────────────────────────────────────────────────────────────────────
log_info "Part 2: HOW — developers"

SAVED_AGENT="$AGENT_NAME"
AGENT_NAME="omar"
if [[ "${CHAT_BACKEND:-slack}" == "mattermost" ]]; then
  mm_post "**Partie 2 — HOW : Approche technique** 🏗️" "sprint" "" "$ROOT_POST_ID" > /dev/null 2>&1 || true
else
  slack_notify "**Partie 2 — HOW : Approche technique** 🏗️" "sprint"
fi
AGENT_NAME="$SAVED_AGENT"
sleep 30

# Rami : recommandation technique
RAMI_TECH=$(ceremony_haiku_turn "rami" "$ARCH_PERSONA" "$PLANNING_CONTEXT" \
  "Donne une recommandation technique concrète pour le premier ticket prioritaire (${TOP_FIRST_KEY:-ticket X}).
Mentionne le package, le pattern, les dépendances potentielles.
Format : 'Pour ${TOP_FIRST_KEY:-ce ticket}, voici l'approche technique que je recommande : …'
2-3 phrases max.")
ceremony_post "rami" "$RAMI_TECH" "sprint" "$ROOT_POST_ID" > /dev/null

# Youssef : plan d'implémentation
YOUSSEF_PLAN=$(ceremony_haiku_turn "youssef" "$DEV_PERSONA" "$PLANNING_CONTEXT" \
  "Confirme ta compréhension de l'approche technique de Rami et donne ton ordre d'implémentation.
Indique quel ticket tu attaques en premier et quand tu passes à Nadia.
Format : 'Compris — je commence par [ticket], je passe à Nadia dès que c'est prêt. Ensuite…'
2 phrases max.")
ceremony_post "youssef" "$YOUSSEF_PLAN" "sprint" "$ROOT_POST_ID" > /dev/null

# ─────────────────────────────────────────────────────────────────────────────
# VOTE ROUND — tous les agents
# ─────────────────────────────────────────────────────────────────────────────
log_info "Vote round..."

SAVED_AGENT="$AGENT_NAME"
AGENT_NAME="omar"
if [[ "${CHAT_BACKEND:-slack}" == "mattermost" ]]; then
  mm_post "**Vote — Validation du sprint** 🗳️" "sprint" "" "$ROOT_POST_ID" > /dev/null 2>&1 || true
else
  slack_notify "**Vote — Validation du sprint** 🗳️" "sprint"
fi
AGENT_NAME="$SAVED_AGENT"
sleep 30

VOTE_TASK="C'est le tour de vote pour valider le sprint.
Donne ton +1 ou soulève un concern final.
Commence par '+1' si tu approuves, ou '⚠️ Concern :' si tu as une dernière réserve.
1 phrase max."

for AGENT in layla rami nadia youssef; do
  case "$AGENT" in
    layla)   PERSONA="$PRODUCT_PERSONA" ;;
    rami)    PERSONA="$ARCH_PERSONA" ;;
    nadia)   PERSONA="$QA_PERSONA" ;;
    youssef) PERSONA="$DEV_PERSONA" ;;
  esac
  VOTE_MSG=$(ceremony_haiku_turn "$AGENT" "$PERSONA" "$PLANNING_CONTEXT" "$VOTE_TASK")
  ceremony_post "$AGENT" "$VOTE_MSG" "sprint" "$ROOT_POST_ID" > /dev/null
  log_info "Vote: ${AGENT} done"
done

# ─────────────────────────────────────────────────────────────────────────────
# SALMA FINALISE LE SPRINT GOAL
# ─────────────────────────────────────────────────────────────────────────────
log_info "Salma finalising sprint goal..."

FINAL_GOAL_TEXT=$(ceremony_haiku_turn "salma" "$PM_PERSONA" "$PLANNING_CONTEXT" \
  "Tous les agents ont voté. Finalise le sprint goal en 1 phrase courte et inspirante.
Format exact : 'Sprint goal finalisé : [goal en 1 phrase]. On lance ! 🎯'
Le goal doit refléter la valeur principale du sprint pour le jeu BisB.")
ceremony_post "salma" "$FINAL_GOAL_TEXT" "sprint" "$ROOT_POST_ID" > /dev/null

# Extraire le goal pour la mise à jour Plane
SPRINT_GOAL_CLEAN=$(echo "$FINAL_GOAL_TEXT" \
  | grep -oP "Sprint goal finalisé : .+?(?=\s*On lance|$)" \
  | sed "s/Sprint goal finalisé : //" \
  | head -1 \
  || echo "Sprint ${PROJECT_KEY} — ${TOP_FIRST_KEY:-backlog priorities}")
SPRINT_GOAL_CLEAN="${SPRINT_GOAL_CLEAN% 🎯}"
SPRINT_GOAL_CLEAN="${SPRINT_GOAL_CLEAN%.}"

log_info "Sprint goal: ${SPRINT_GOAL_CLEAN}"

# ─────────────────────────────────────────────────────────────────────────────
# ASSIGN TICKETS IN PLANE
# ─────────────────────────────────────────────────────────────────────────────
log_info "Assigning tickets in Plane..."

# ── Create Plane cycle for this sprint ───────────────────────────────────────
NEW_CYCLE_ID=""
if [[ "${TRACKER_BACKEND:-jira}" == "plane" ]] && declare -f plane_create_cycle &>/dev/null; then
  SPRINT_NUM=$(cat "${DATA_DIR}/sprints/current-sprint-num.txt" 2>/dev/null || echo "1")
  CYCLE_START=$(date -u +%Y-%m-%d)
  CYCLE_END=$(date -u -d "+7 days" +%Y-%m-%d 2>/dev/null || date -u -v+7d +%Y-%m-%d 2>/dev/null || date -u +%Y-%m-%d)
  NEW_CYCLE_ID=$(plane_create_cycle "Sprint ${SPRINT_NUM}" "$CYCLE_START" "$CYCLE_END" 2>/dev/null || echo "")
  if [[ -n "$NEW_CYCLE_ID" ]]; then
    log_info "Created Plane cycle: Sprint ${SPRINT_NUM} (${NEW_CYCLE_ID})"
    # Increment sprint number for next planning run
    echo $((SPRINT_NUM + 1)) > "${DATA_DIR}/sprints/current-sprint-num.txt" 2>/dev/null || true
  else
    log_info "Plane cycle creation failed — falling back to sprint-active labels"
  fi
fi

DEV_TICKETS=()
QA_TICKETS=()
ASSIGNED_COUNT=0
PD_TOTAL=0

# Iterate over selected backlog candidates; classify by ticket type
# Tickets with 'qa' / 'test' / 'nadia' in name → Nadia; rest → Youssef
while IFS='|' read -r ticket_key summary; do
  [[ -z "$ticket_key" ]] && continue
  [[ ! "$ticket_key" =~ ^${PROJECT_KEY}- ]] && continue

  # Simple heuristic: QA or test tickets go to Nadia
  if echo "${summary,,}" | grep -qE '\bqa\b|test|review|audit|qualité|quality'; then
    QA_TICKETS+=("$ticket_key")
    plane_assign_ticket "$ticket_key" "nadia" 2>/dev/null || true
    jira_add_label "$ticket_key" "agent:nadia" 2>/dev/null || true
    [[ -z "${NEW_CYCLE_ID:-}" ]] && jira_add_label "$ticket_key" "sprint-active" 2>/dev/null || true
    log_info "Assigned ${ticket_key} → nadia (QA)"
  else
    DEV_TICKETS+=("$ticket_key")
    plane_assign_ticket "$ticket_key" "youssef" 2>/dev/null || true
    jira_add_label "$ticket_key" "agent:youssef" 2>/dev/null || true
    [[ -z "${NEW_CYCLE_ID:-}" ]] && jira_add_label "$ticket_key" "sprint-active" 2>/dev/null || true
    # Ensure it goes through Salma enrichment if not already enriched
    TICKET_LABELS=$(jira_get_ticket_field "$ticket_key" "labels" 2>/dev/null || echo "")
    if ! echo "$TICKET_LABELS" | grep -q "enriched"; then
      jira_add_label "$ticket_key" "agent:salma" 2>/dev/null || true
    fi
    log_info "Assigned ${ticket_key} → youssef (dev)"
  fi

  # Track estimate
  TICKET_PD=$(get_estimate "$ticket_key")
  [[ "$TICKET_PD" == "0" ]] && TICKET_PD="0.5"
  PD_TOTAL=$(python3 -c "print(round(float('$PD_TOTAL') + float('$TICKET_PD'), 1))" 2>/dev/null || echo "$PD_TOTAL")

  (( ASSIGNED_COUNT++ )) || true
  (( ASSIGNED_COUNT >= 15 )) && break
done <<< "$(echo "$BACKLOG_RAW" | while IFS='|' read -r key sum; do echo "${key}|${sum:-}"; done)"

log_info "Assigned ${ASSIGNED_COUNT} tickets: ${#DEV_TICKETS[@]} dev (Youssef), ${#QA_TICKETS[@]} QA (Nadia)"

# ── Add tickets to Plane cycle ───────────────────────────────────────────────
if [[ -n "${NEW_CYCLE_ID:-}" ]] && declare -f plane_add_issues_to_cycle &>/dev/null; then
  ALL_SPRINT_KEYS=("${DEV_TICKETS[@]}" "${QA_TICKETS[@]}")
  if [[ ${#ALL_SPRINT_KEYS[@]} -gt 0 ]]; then
    plane_add_issues_to_cycle "$NEW_CYCLE_ID" "${ALL_SPRINT_KEYS[@]}" 2>/dev/null || true
    log_info "Added ${#ALL_SPRINT_KEYS[@]} tickets to cycle ${NEW_CYCLE_ID}"
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# UPDATE PLANE CYCLE DESCRIPTION WITH SPRINT GOAL
# ─────────────────────────────────────────────────────────────────────────────
CYCLE_DESCRIPTION="Sprint Goal: ${SPRINT_GOAL_CLEAN}

Planning: ${PLANNING_DATE}
Capacité: ${ADJUSTED_CAPACITY} PD | Vélocité: ${SPRINT_VELOCITY}
Tickets planifiés: ${ASSIGNED_COUNT} | PD estimés: ${PD_TOTAL}
Dev (Youssef): ${#DEV_TICKETS[@]} tickets | QA (Nadia): ${#QA_TICKETS[@]} tickets"

if [[ -n "${NEW_CYCLE_ID:-}" ]]; then
  plane_update_cycle_description "$CYCLE_DESCRIPTION" "$NEW_CYCLE_ID" 2>/dev/null || \
    log_info "Cycle description update failed"
else
  plane_update_cycle_description "$CYCLE_DESCRIPTION" 2>/dev/null || \
    log_info "Cycle description update skipped (not Plane or no active cycle)"
fi

# ─────────────────────────────────────────────────────────────────────────────
# OMAR FERME LE PLANNING
# ─────────────────────────────────────────────────────────────────────────────
log_info "Omar closing planning..."

DEV_LIST=""
for t in "${DEV_TICKETS[@]}"; do DEV_LIST="${DEV_LIST}  • ${t}\n"; done
[[ -z "$DEV_LIST" ]] && DEV_LIST="  (aucun)\n"

QA_LIST=""
for t in "${QA_TICKETS[@]}"; do QA_LIST="${QA_LIST}  • ${t}\n"; done
[[ -z "$QA_LIST" ]] && QA_LIST="  (aucun)\n"

CLOSE_MSG="**Sprint Planning terminé ✅**

**Sprint goal :** _${SPRINT_GOAL_CLEAN}_

**Capacité :** ${ADJUSTED_CAPACITY} PD planifiés (${PD_TOTAL} PD estimés)
**Tickets :** ${ASSIGNED_COUNT} total

**$(mm_mention youssef 2>/dev/null || echo "@youssef") — Dev (${#DEV_TICKETS[@]} tickets) :**
$(printf '%b' "$DEV_LIST")
**$(mm_mention nadia 2>/dev/null || echo "@nadia") — QA (${#QA_TICKETS[@]} tickets) :**
$(printf '%b' "$QA_LIST")
On a un plan clair. Bon sprint à tous ! 🚀
_Next standup : demain 08:30 UTC_"

ceremony_post "omar" "$CLOSE_MSG" "sprint" "$ROOT_POST_ID" > /dev/null

log_activity "salma" "ceremony-planning" "INFO" "Planning completed: goal='${SPRINT_GOAL_CLEAN}', ${ASSIGNED_COUNT} tickets, ${PD_TOTAL}PD"
log_success "=== Sprint Planning Complete (${SECONDS}s) ==="
