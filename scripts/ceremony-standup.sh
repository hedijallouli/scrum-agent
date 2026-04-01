#!/usr/bin/env bash
# =============================================================================
# ceremony-standup.sh — Daily Standup Ceremony (Tour de Table)
#
# Omar (Scrum Master) facilitates. Cumulative conversation — each agent reads
# what prior speakers said and reacts to them (ported from SI n8n pattern).
#
# Order: Omar opens → Youssef → Nadia → Rami → Layla → Salma (PM closes
# with structured decisions on stuck tickets) → Omar closes.
#
# Actionable: Salma's decisions are parsed and executed (reassign, reset
# retries, escalate to human). SI pattern: standup drives real ticket changes.
#
# Agents are paused during the ceremony to prevent dispatch conflicts.
#
# Posted as a Mattermost thread. ~30 seconds between each agent's turn.
# Total runtime: ~8–10 minutes.
#
# Triggered: daily 08:30 UTC (09:30 Tunis) weekdays via cron
# Log: ${LOG_DIR}/standup.log
# =============================================================================
set -euo pipefail

export PATH="$HOME/.local/bin:/usr/local/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── Bootstrap ────────────────────────────────────────────────────────────────
AGENT_NAME="omar"
source "${SCRIPT_DIR}/agent-common.sh"
load_env
source "${SCRIPT_DIR}/tracker-common.sh"
source "${SCRIPT_DIR}/ceremony-common.sh"

LOG_FILE="${LOG_DIR}/standup.log"
mkdir -p ${LOG_DIR}
log_info "=== BisB Ceremony Standup starting ==="

# ─── Idempotency guard ────────────────────────────────────────────────────────
STANDUP_FLAG="/tmp/${PROJECT_PREFIX}-standup-$(date +%Y-%m-%d)"
if [[ -f "$STANDUP_FLAG" ]]; then
  log_info "Standup already ran today. Exiting."
  exit 0
fi

# ─── Pause agents during ceremony ─────────────────────────────────────────────
ceremony_pause_agents
trap 'ceremony_resume_agents' EXIT

# ─── 1. Gather Sprint Data ────────────────────────────────────────────────────
log_info "Fetching sprint data..."

SPRINT_JSON=$(get_sprint_data)

SPRINT_NAME=$(echo "$SPRINT_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('sprint_name','Sprint actuel'))" 2>/dev/null || echo "Sprint actuel")
DAYS_LEFT=$(echo "$SPRINT_JSON"   | python3 -c "import sys,json; print(json.load(sys.stdin).get('days_left',0))"                   2>/dev/null || echo "?")
DONE_COUNT=$(echo "$SPRINT_JSON"  | python3 -c "import sys,json; print(json.load(sys.stdin).get('done_count',0))"                  2>/dev/null || echo "0")
INPROG_COUNT=$(echo "$SPRINT_JSON"| python3 -c "import sys,json; print(json.load(sys.stdin).get('inprog_count',0))"                2>/dev/null || echo "0")
TODO_COUNT=$(echo "$SPRINT_JSON"  | python3 -c "import sys,json; print(json.load(sys.stdin).get('todo_count',0))"                  2>/dev/null || echo "0")
VELOCITY=$(echo "$SPRINT_JSON"    | python3 -c "import sys,json; print(json.load(sys.stdin).get('velocity',0))"                    2>/dev/null || echo "0")

TOTAL_TICKETS=$(( DONE_COUNT + INPROG_COUNT + TODO_COUNT ))

log_info "Sprint: ${SPRINT_NAME} | ${DAYS_LEFT}j restants | ${DONE_COUNT}/${TOTAL_TICKETS} done (${VELOCITY}%)"

# ─── 2. Budget / velocity context (best-effort) ───────────────────────────────
BUDGET_STATUS=$(get_budget_status 2>/dev/null || echo "non disponible")
TEAM_VELOCITY=$(get_velocity       2>/dev/null || echo "${VELOCITY}%")

# ─── 3. Stuck tickets ─────────────────────────────────────────────────────────
STUCK=0
STUCK_LIST=""
STUCK_TICKETS_FOR_SALMA=""
for f in /tmp/${PROJECT_PREFIX}-retries/${PROJECT_KEY:?}-*; do
  [[ -f "$f" ]] || continue
  cnt=$(cat "$f" 2>/dev/null || echo 0)
  if [[ "$cnt" -ge 2 ]]; then
    (( STUCK++ )) || true
    ticket_key=$(basename "$f" | grep -oE "${PROJECT_KEY}-[0-9]+" || true)
    STUCK_LIST="${STUCK_LIST}  - ${ticket_key} (${cnt} retries)\n"
    STUCK_TICKETS_FOR_SALMA="${STUCK_TICKETS_FOR_SALMA}${ticket_key}(${cnt} retries), "
  fi
done

# ─── 4. Blacklisted tickets ───────────────────────────────────────────────────
BLACKLISTED_LIST=""
if [[ -f "${BLACKLIST_FILE:-/tmp/${PROJECT_PREFIX}-dispatch-blacklist}" ]]; then
  while IFS='|' read -r t ts reason; do
    [[ -z "$t" ]] && continue
    BLACKLISTED_LIST="${BLACKLISTED_LIST}  - ${t}: ${reason}\n"
  done < "${BLACKLIST_FILE:-/tmp/${PROJECT_PREFIX}-dispatch-blacklist}"
fi

# ─── 5. Health indicator ──────────────────────────────────────────────────────
if   [[ "$STUCK" -eq 0 && "$VELOCITY" -ge 20 ]]; then
  HEALTH=":large_green_circle: On Track"
elif [[ "$STUCK" -le 2 ]]; then
  HEALTH=":large_yellow_circle: Minor Blockers"
else
  HEALTH=":red_circle: Needs Attention"
fi

# ─── 6. Per-agent activity (real data from shared memory) ─────────────────────
log_info "Reading agent activity data..."

declare -A AGENT_ACTIVITY
for agent in salma youssef nadia rami layla; do
  AGENT_ACTIVITY[$agent]=$(get_agent_activity "$agent")
  log_info "  ${agent}: ${AGENT_ACTIVITY[$agent]}"
done

# ─── 7. Open PRs (for sprint context) ────────────────────────────────────────
OPEN_PRS=$(cd "$PROJECT_DIR" && gh pr list --state open --json number,title --limit 5 2>/dev/null | python3 -c "
import sys, json
prs = json.load(sys.stdin)
if not prs:
    print('Aucune PR ouverte')
else:
    print(', '.join('PR #' + str(p['number']) for p in prs))
" 2>/dev/null || echo "non disponible")

# ─── 8. Build sprint context block ───────────────────────────────────────────
DECISIONS_FILE="/var/lib/${PROJECT_PREFIX}/data/ceremony-decisions.jsonl"
RECENT_DECISIONS=""
if [[ -f "$DECISIONS_FILE" ]]; then
  RECENT_DECISIONS=$(tail -5 "$DECISIONS_FILE" 2>/dev/null | python3 -c "
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
    print('Décisions retro récentes :')
    for d in recent:
        print(f'  - [{d.get(\"sprint\",\"Sprint\")}] {d.get(\"decision\",\"\")} (@{d.get(\"owner\",\"\")})')
" 2>/dev/null || true)
fi

SPRINT_CONTEXT="Sprint : ${SPRINT_NAME} | ${DAYS_LEFT} jours restants
Tickets : ${DONE_COUNT}/${TOTAL_TICKETS} terminés (${VELOCITY}%) — ${INPROG_COUNT} en cours, ${TODO_COUNT} à faire
Bloqués : ${STUCK} | Santé : ${HEALTH}
PRs ouvertes : ${OPEN_PRS}
Budget pipeline : ${BUDGET_STATUS}
${RECENT_DECISIONS}"

# ─── 9. French date ──────────────────────────────────────────────────────────
STANDUP_DATE=$(python3 -c "
import datetime, locale
try:
    locale.setlocale(locale.LC_TIME, 'fr_FR.UTF-8')
except:
    pass
d = datetime.date.today()
days_fr   = ['Lundi','Mardi','Mercredi','Jeudi','Vendredi','Samedi','Dimanche']
months_fr = ['janvier','février','mars','avril','mai','juin',
             'juillet','août','septembre','octobre','novembre','décembre']
print(f'{days_fr[d.weekday()]} {d.day} {months_fr[d.month-1]} {d.year}')
" 2>/dev/null || date '+%A %d %B %Y')

# ═══════════════════════════════════════════════════════════════════════════════
# CUMULATIVE CONVERSATION — each agent reads what prior speakers said
# (Ported from SI n8n pattern: genuine multi-agent discussion)
# ═══════════════════════════════════════════════════════════════════════════════
CONVERSATION=""  # Accumulates all agent messages

# ─── 10. OMAR OPENS — root post ─────────────────────────────────────────────
log_info "Omar opening standup..."

OMAR_OPEN="Bonjour l'équipe ! :sunny:

**Standup ${SPRINT_NAME} — ${STANDUP_DATE}**

Tour de table — 3 questions pour chacun :
> **Hier** | **Aujourd'hui** | **Blockers**

Sprint en cours : ${DONE_COUNT}/${TOTAL_TICKETS} tickets terminés (${VELOCITY}%) — ${DAYS_LEFT} jours restants — ${HEALTH}

On y va ! :runner:"

ROOT_POST_ID=$(ceremony_post "omar" "$OMAR_OPEN" "standup" "")
log_info "Root post ID: ${ROOT_POST_ID:-<not returned>}"

if [[ -n "$ROOT_POST_ID" ]]; then
  ceremony_react "omar" "$ROOT_POST_ID" "spiral_notepad"
fi

# ─── 11. YOUSSEF (Dev) — speaks first, sets technical context ───────────────
log_info "Youssef's turn (1st speaker)..."

YOUSSEF_DATA="Activité récente : ${AGENT_ACTIVITY[youssef]}
Sprint : ${SPRINT_CONTEXT}
PRs ouvertes : ${OPEN_PRS}"

YOUSSEF_MSG=$(ceremony_haiku_turn \
  "youssef" \
  "${AI_DIR}/dev.md" \
  "$YOUSSEF_DATA" \
  "Réponds aux 3 questions standup dans ton rôle de développeur :
(1) Ce que tu as codé hier (feature, PR, fix),
(2) Ce que tu codes aujourd'hui,
(3) Tes blockers techniques ou RAS.
Sois concret — cite le ticket ou la PR si pertinent.")

ceremony_post "youssef" "$YOUSSEF_MSG" "standup" "$ROOT_POST_ID"
CONVERSATION="**Youssef (Dev)** : ${YOUSSEF_MSG}"

# Detect if Youssef mentioned a blocker
YOUSSEF_HAS_BLOCKER=false
if echo "$YOUSSEF_MSG" | grep -qiE "blocker|bloqué|bloquant|bloque|stuck|attente|besoin d.aide|cannot|ne peut pas|erreur|bug critique"; then
  YOUSSEF_HAS_BLOCKER=true
  log_info "Youssef blocker detected"
fi

# ─── 12. NADIA (QA) — reads Youssef, reacts to his work ────────────────────
log_info "Nadia's turn (reads Youssef)..."

NADIA_DATA="Activité récente : ${AGENT_ACTIVITY[nadia]}
Sprint : ${SPRINT_CONTEXT}
Tickets bloqués : ${STUCK} (${STUCK_LIST:-aucun})"

NADIA_MSG=$(ceremony_haiku_turn_cumulative \
  "nadia" \
  "${AI_DIR}/qa.md" \
  "$NADIA_DATA" \
  "Réponds aux 3 questions standup dans ton rôle de QA :
(1) Ce que tu as testé/reviewé hier,
(2) Ce que tu testes/valides aujourd'hui,
(3) Tes blockers ou points de qualité à remonter.
Si Youssef a mentionné une PR ou un ticket, réfère-toi à son travail." \
  "$CONVERSATION")

ceremony_post "nadia" "$NADIA_MSG" "standup" "$ROOT_POST_ID"
CONVERSATION="${CONVERSATION}

**Nadia (QA)** : ${NADIA_MSG}"

# ─── 13. RAMI (Architect) — reads Youssef + Nadia ──────────────────────────
log_info "Rami's turn (reads Youssef, Nadia)..."

RAMI_DATA="Activité récente : ${AGENT_ACTIVITY[rami]}
Sprint : ${SPRINT_CONTEXT}"

RAMI_MSG=$(ceremony_haiku_turn_cumulative \
  "rami" \
  "${AI_DIR}/architect.md" \
  "$RAMI_DATA" \
  "Réponds aux 3 questions standup dans ton rôle d'architecte technique :
(1) Ce que tu as fait hier (review archi, design, guidance technique),
(2) Ce que tu fais aujourd'hui,
(3) Tes blockers ou alertes architecturales.
Si Youssef a un blocker technique, propose ton aide si pertinent." \
  "$CONVERSATION")

ceremony_post "rami" "$RAMI_MSG" "standup" "$ROOT_POST_ID"
CONVERSATION="${CONVERSATION}

**Rami (Architecte)** : ${RAMI_MSG}"

# ─── 14. LAYLA (Product) — reads everyone ────────────────────────────────────
log_info "Layla's turn (reads Youssef, Nadia, Rami)..."

LAYLA_DATA="Activité récente : ${AGENT_ACTIVITY[layla]}
Sprint : ${SPRINT_CONTEXT}"

LAYLA_MSG=$(ceremony_haiku_turn_cumulative \
  "layla" \
  "${AI_DIR}/product-marketing.md" \
  "$LAYLA_DATA" \
  "Réponds aux 3 questions standup dans ton rôle de Product Strategist :
(1) Ce que tu as fait hier (veille marché, retour joueurs, vision produit),
(2) Ce que tu fais aujourd'hui,
(3) Tes attentes ou questions pour l'équipe.
Parle en tant que voix du joueur et du marché. Réagis à ce que les autres ont dit." \
  "$CONVERSATION")

ceremony_post "layla" "$LAYLA_MSG" "standup" "$ROOT_POST_ID"
CONVERSATION="${CONVERSATION}

**Layla (Product)** : ${LAYLA_MSG}"

# ═══════════════════════════════════════════════════════════════════════════════
# 15. SALMA (PM) — SPEAKS LAST — reads everyone + makes ACTIONABLE DECISIONS
# (Ported from SI n8n: standup-driven ticket triage)
# ═══════════════════════════════════════════════════════════════════════════════
log_info "Salma's turn (reads everyone, makes decisions)..."

SALMA_DATA="Activité récente : ${AGENT_ACTIVITY[salma]}
Sprint : ${SPRINT_CONTEXT}"

# Build the decision task differently based on whether there are stuck tickets
DECISION_TASK=""
if [[ "$STUCK" -gt 0 || -n "$BLACKLISTED_LIST" ]]; then
  DECISION_TASK="
IMPORTANT — Il y a des tickets qui nécessitent une décision de ta part :
Tickets bloqués : ${STUCK_TICKETS_FOR_SALMA:-aucun}
Tickets blacklistés : $(echo -e "${BLACKLISTED_LIST:-aucun}")

Après ton standup (Hier/Aujourd'hui/Blockers), ajoute un bloc de DÉCISIONS structurées.
Pour CHAQUE ticket bloqué, écris UNE ligne dans ce format exact :
DECISION: TICKET_KEY | ACTION | RAISON

Actions possibles :
- ASSIGN_YOUSSEF : réassigner à Youssef avec guidance
- ASSIGN_RAMI : demander à Rami de faire un review archi
- ASSIGN_HUMAN : escalader à Hedi (Needs Human)
- DEPRIORITIZE : déprioritiser (retirer du sprint)
- RESET_RETRY : réinitialiser les retries et retenter
- UNBLACKLIST : retirer de la blacklist et retenter

Exemple :
DECISION: BISB-52 | RESET_RETRY | Le blocker API est résolu, on peut retenter
DECISION: BISB-39 | ASSIGN_HUMAN | Nécessite une décision UX de Hedi"
fi

SALMA_MSG=$(ceremony_haiku_turn_cumulative \
  "salma" \
  "${AI_DIR}/pm.md" \
  "$SALMA_DATA" \
  "Réponds aux 3 questions standup dans ton rôle de PM/Product Owner :
(1) Ce que tu as fait hier (tickets priorisés, specs, coordination),
(2) Ce que tu fais aujourd'hui,
(3) Tes blockers ou RAS.
Tu parles en DERNIÈRE — tu as lu ce que toute l'équipe a dit. Fais une synthèse rapide si pertinent.
${DECISION_TASK}" \
  "$CONVERSATION")

ceremony_post "salma" "$SALMA_MSG" "standup" "$ROOT_POST_ID"

# ─── 16. Parse and execute Salma's decisions ─────────────────────────────────
log_info "Parsing Salma's decisions..."

DECISIONS_MADE=0
while IFS= read -r line; do
  # Parse: DECISION: BISB-XX | ACTION | REASON
  if [[ "$line" =~ ^DECISION:[[:space:]]*([A-Z]+-[0-9]+)[[:space:]]*\|[[:space:]]*([A-Z_]+)[[:space:]]*\|[[:space:]]*(.*) ]]; then
    TICKET="${BASH_REMATCH[1]}"
    ACTION="${BASH_REMATCH[2]}"
    REASON="${BASH_REMATCH[3]}"
    (( DECISIONS_MADE++ )) || true

    log_info "Decision: ${TICKET} → ${ACTION} — ${REASON}"

    case "$ACTION" in
      ASSIGN_YOUSSEF)
        plane_set_assignee "$TICKET" "youssef" 2>/dev/null || true
        reset_retry "$TICKET" "youssef" 2>/dev/null || true
        remove_from_blacklist "$TICKET" 2>/dev/null || true
        jira_add_rich_comment "$TICKET" "salma" "INFO" "Standup decision: réassigné à Youssef. ${REASON}" 2>/dev/null || true
        log_info "Executed: ${TICKET} → assigned to Youssef"
        ;;
      ASSIGN_RAMI)
        plane_set_assignee "$TICKET" "rami" 2>/dev/null || true
        jira_add_rich_comment "$TICKET" "salma" "INFO" "Standup decision: escaladé à Rami pour review archi. ${REASON}" 2>/dev/null || true
        log_info "Executed: ${TICKET} → assigned to Rami"
        ;;
      ASSIGN_HUMAN)
        plane_set_assignee "$TICKET" "hedi" 2>/dev/null || true
        jira_set_state "$TICKET" "needs-human" 2>/dev/null || true
        jira_add_rich_comment "$TICKET" "salma" "WARNING" "Standup decision: escaladé à Hedi. ${REASON}" 2>/dev/null || true
        log_info "Executed: ${TICKET} → assigned to Hedi (Needs Human)"
        ;;
      DEPRIORITIZE)
        jira_add_label "$TICKET" "deprioritized" 2>/dev/null || true
        jira_remove_label "$TICKET" "sprint-active" 2>/dev/null || true
        blacklist_ticket "$TICKET" "Deprioritized by Salma at standup" 2>/dev/null || true
        jira_add_rich_comment "$TICKET" "salma" "INFO" "Standup decision: déprioritisé. ${REASON}" 2>/dev/null || true
        log_info "Executed: ${TICKET} → deprioritized"
        ;;
      RESET_RETRY)
        # Reset all agent retries for this ticket
        for agent in youssef nadia rami salma layla; do
          reset_retry "$TICKET" "$agent" 2>/dev/null || true
        done
        remove_from_blacklist "$TICKET" 2>/dev/null || true
        jira_add_rich_comment "$TICKET" "salma" "INFO" "Standup decision: retries réinitialisés. ${REASON}" 2>/dev/null || true
        log_info "Executed: ${TICKET} → retries reset + unblacklisted"
        ;;
      UNBLACKLIST)
        remove_from_blacklist "$TICKET" 2>/dev/null || true
        jira_add_rich_comment "$TICKET" "salma" "INFO" "Standup decision: retiré de la blacklist. ${REASON}" 2>/dev/null || true
        log_info "Executed: ${TICKET} → unblacklisted"
        ;;
      *)
        log_info "Unknown decision action: ${ACTION} for ${TICKET}"
        ;;
    esac
  fi
done <<< "$SALMA_MSG"

if [[ "$DECISIONS_MADE" -gt 0 ]]; then
  log_info "Executed ${DECISIONS_MADE} standup decision(s)"
  # Persist decisions to cross-ceremony memory
  for i in $(seq 1 "$DECISIONS_MADE"); do
    echo "{\"sprint\":\"${SPRINT_NAME}\",\"ceremony\":\"standup\",\"date\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"decision\":\"standup triage\"}" \
      >> "$DECISIONS_FILE" 2>/dev/null || true
  done
fi

# ─── 17. OMAR CLOSES ────────────────────────────────────────────────────────
log_info "Omar closing standup..."

if   [[ "$STUCK" -eq 0 && "$VELOCITY" -ge 20 ]]; then
  HEALTH_SUMMARY="Tout est vert. :large_green_circle:"
elif [[ "$STUCK" -le 2 ]]; then
  HEALTH_SUMMARY="${STUCK} blocker(s) à surveiller. :large_yellow_circle:"
else
  HEALTH_SUMMARY="${STUCK} tickets bloqués — escalade requise. :red_circle:"
fi

DECISIONS_SUMMARY=""
if [[ "$DECISIONS_MADE" -gt 0 ]]; then
  DECISIONS_SUMMARY="
**Décisions standup** : ${DECISIONS_MADE} action(s) exécutée(s) par Salma :ok_hand:"
fi

OMAR_CLOSE="Merci à tous ! :saluting_face:

**Résumé** : ${SPRINT_NAME} — ${DONE_COUNT}/${TOTAL_TICKETS} terminés (${VELOCITY}%) — ${DAYS_LEFT} jours restants
**Santé** : ${HEALTH_SUMMARY}
**Vélocité** : ${TEAM_VELOCITY}${DECISIONS_SUMMARY}

Prochain standup : demain à 09h30 (Tunis). Bonne journée ! :muscle:"

ceremony_post "omar" "$OMAR_CLOSE" "standup" "$ROOT_POST_ID"

if [[ -n "$ROOT_POST_ID" ]]; then
  ceremony_react "omar" "$ROOT_POST_ID" "white_check_mark"
fi

# ─── 18. Finalise ─────────────────────────────────────────────────────────────
touch "$STANDUP_FLAG"
log_activity "omar" "STANDUP" "COMPLETE" "Standup ${SPRINT_NAME}: ${DONE_COUNT}/${TOTAL_TICKETS} done, ${STUCK} bloqués, velocity=${VELOCITY}%, decisions=${DECISIONS_MADE}"
log_success "=== Standup complet en ${SECONDS}s ==="
