#!/usr/bin/env bash
# =============================================================================
# ceremony-blocker-triage.sh — Round-table triage for blocked tickets
#
# Omar calls the meeting with the blocked ticket context.
# Each agent (Salma, Rami, Youssef, Nadia) gives their perspective via Haiku.
# After 2 rounds (8 agent turns total), Salma makes a final decision:
#   SPLIT    — ticket is too broad, split into sub-tasks
#   PIVOT    — change approach or implementation strategy
#   UNBLOCK  — root cause identified, can proceed
#   ASK_HUMAN — needs human (Hedi) input before proceeding
#
# Decision is executed (split creates sub-tickets, etc.) and posted in
# #alerts channel as a threaded discussion.
#
# Usage: ceremony-blocker-triage.sh BISB-XX "Reason for blocker"
# Log:   /var/log/bisb/blocker-triage-BISB-XX.log
# =============================================================================
set -euo pipefail

export PATH="$HOME/.local/bin:/usr/local/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TICKET_KEY="${1:?Usage: ceremony-blocker-triage.sh BISB-XX 'Reason for blocker'}"
BLOCKER_REASON="${2:-Raison non précisée}"

# ─── Bootstrap ────────────────────────────────────────────────────────────────
AGENT_NAME="omar"
source "${SCRIPT_DIR}/agent-common.sh"
load_env
source "${SCRIPT_DIR}/tracker-common.sh"
source "${SCRIPT_DIR}/ceremony-common.sh"

LOG_FILE="/var/log/bisb/blocker-triage-${TICKET_KEY}.log"
mkdir -p /var/log/bisb
log_info "=== BisB Blocker Triage: ${TICKET_KEY} ==="
log_info "Reason: ${BLOCKER_REASON}"

# ─── Fetch ticket context ─────────────────────────────────────────────────────
TICKET_SUMMARY=$(jira_get_ticket_field "$TICKET_KEY" "summary" 2>/dev/null || echo "$TICKET_KEY")
TICKET_DESCRIPTION=$(jira_get_description_text "$TICKET_KEY" 2>/dev/null || echo "")
TICKET_LINK=$(mm_ticket_link "$TICKET_KEY" 2>/dev/null || echo "$TICKET_KEY")

RETRY_COUNT=$(cat "/tmp/bisb-retries/${TICKET_KEY}" 2>/dev/null || echo "3")

SPRINT_JSON=$(get_sprint_data 2>/dev/null || echo '{"sprint_name":"Sprint actuel","days_left":0,"done_count":0,"inprog_count":0,"todo_count":0,"velocity":0}')
SPRINT_NAME=$(echo "$SPRINT_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('sprint_name','Sprint actuel'))" 2>/dev/null || echo "Sprint actuel")
DAYS_LEFT=$(echo "$SPRINT_JSON"   | python3 -c "import sys,json; print(json.load(sys.stdin).get('days_left',0))" 2>/dev/null || echo "0")

DATA_CONTEXT="Ticket : ${TICKET_KEY} — ${TICKET_SUMMARY}
Raison du blocage : ${BLOCKER_REASON}
Nombre de tentatives échouées : ${RETRY_COUNT}
Sprint : ${SPRINT_NAME} | ${DAYS_LEFT} jours restants
Description : ${TICKET_DESCRIPTION:0:400}"

log_info "Ticket context gathered."

# ─── 1. Omar opens the round-table in #alerts ─────────────────────────────────
log_info "Omar opening triage in #alerts..."

OMAR_OPEN="**Triage requis — ${TICKET_LINK}**

Ce ticket est bloqué après **${RETRY_COUNT} tentatives**. J'ouvre une discussion d'équipe pour débloquer la situation.

**Raison :** ${BLOCKER_REASON}

$(mm_mention salma) $(mm_mention rami) $(mm_mention youssef) $(mm_mention nadia) — chacun donne sa perspective ci-dessous. Salma prendra la décision finale."

ROOT_POST_ID=$(ceremony_post "omar" "$OMAR_OPEN" "alerts")
log_info "Root post ID: ${ROOT_POST_ID:-<none>}"

if [[ -z "$ROOT_POST_ID" ]]; then
  log_info "WARNING: no root post ID — replies will be sent as standalone messages"
fi

# ─── 2. Round 1: Each agent gives initial perspective ────────────────────────
log_info "Round 1: Initial perspectives..."

# Salma — PM perspective
SALMA_R1_PROMPT="C'est une réunion de triage d'urgence. Le ticket ${TICKET_KEY} est bloqué : '${BLOCKER_REASON}'. Depuis ta position de PM, donne ton analyse initiale du problème. Est-ce un problème de spec, de scope, ou de dépendance ? Max 2 phrases."
SALMA_R1=$(ceremony_haiku_turn "salma" "${AI_DIR}/pm.md" "$DATA_CONTEXT" "$SALMA_R1_PROMPT")
ceremony_post "salma" "**Perspective PM** — ${SALMA_R1}" "alerts" "$ROOT_POST_ID"

# Rami — Architecture perspective
RAMI_R1_PROMPT="Triage urgent pour ${TICKET_KEY} bloqué : '${BLOCKER_REASON}'. En tant qu'architecte, quelle est ta lecture technique ? Y a-t-il un problème structurel, une dépendance manquante, ou un risque de couplage ? Max 2 phrases."
RAMI_R1=$(ceremony_haiku_turn "rami" "${AI_DIR}/architect.md" "$DATA_CONTEXT" "$RAMI_R1_PROMPT")
ceremony_post "rami" "**Perspective Architecture** — ${RAMI_R1}" "alerts" "$ROOT_POST_ID"

# Youssef — Dev perspective
YOUSSEF_R1_PROMPT="Triage pour ${TICKET_KEY} bloqué : '${BLOCKER_REASON}'. En tant que développeur qui a travaillé dessus, qu'est-ce qui t'a empêché d'avancer concrètement ? Quelle est la vraie difficulté d'implémentation ? Max 2 phrases."
YOUSSEF_R1=$(ceremony_haiku_turn "youssef" "${AI_DIR}/dev.md" "$DATA_CONTEXT" "$YOUSSEF_R1_PROMPT")
ceremony_post "youssef" "**Perspective Dev** — ${YOUSSEF_R1}" "alerts" "$ROOT_POST_ID"

# Nadia — QA perspective
NADIA_R1_PROMPT="Triage pour ${TICKET_KEY} bloqué : '${BLOCKER_REASON}'. En tant que QA, quels sont les critères d'acceptance qui posent problème ? Les tests sont-ils trop larges ou mal définis ? Max 2 phrases."
NADIA_R1=$(ceremony_haiku_turn "nadia" "${AI_DIR}/qa.md" "$DATA_CONTEXT" "$NADIA_R1_PROMPT")
ceremony_post "nadia" "**Perspective QA** — ${NADIA_R1}" "alerts" "$ROOT_POST_ID"

log_info "Round 1 complete."

# ─── 3. Round 2: Deeper analysis after hearing each other ────────────────────
log_info "Round 2: Deeper analysis..."

ROUND2_CTX="${DATA_CONTEXT}

Perspectives initiales :
- PM (Salma) : ${SALMA_R1}
- Architecture (Rami) : ${RAMI_R1}
- Dev (Youssef) : ${YOUSSEF_R1}
- QA (Nadia) : ${NADIA_R1}"

# Salma — synthesis direction
SALMA_R2_PROMPT="Après avoir entendu Rami, Youssef et Nadia, affine ta vision. Quel est le vrai nœud du problème ? Vers quelle décision tu penches : SPLIT (découper), PIVOT (changer d'approche), UNBLOCK (lever le blocage), ou ASK_HUMAN (besoin de Hedi) ? Max 2 phrases."
SALMA_R2=$(ceremony_haiku_turn "salma" "${AI_DIR}/pm.md" "$ROUND2_CTX" "$SALMA_R2_PROMPT")
ceremony_post "salma" "${SALMA_R2}" "alerts" "$ROOT_POST_ID"

# Rami — architecture recommendation
RAMI_R2_PROMPT="Après avoir entendu tout le monde, quelle est ta recommandation technique finale pour débloquer ${TICKET_KEY} ? Si le ticket doit être splitté, propose comment. Max 2 phrases."
RAMI_R2=$(ceremony_haiku_turn "rami" "${AI_DIR}/architect.md" "$ROUND2_CTX" "$RAMI_R2_PROMPT")
ceremony_post "rami" "${RAMI_R2}" "alerts" "$ROOT_POST_ID"

# Youssef — dev feasibility
YOUSSEF_R2_PROMPT="Après cette discussion, comment tu penses débloquer ${TICKET_KEY} concrètement ? Si le scope est trop large, quelles parties tu ferais en priorité ? Max 2 phrases."
YOUSSEF_R2=$(ceremony_haiku_turn "youssef" "${AI_DIR}/dev.md" "$ROUND2_CTX" "$YOUSSEF_R2_PROMPT")
ceremony_post "youssef" "${YOUSSEF_R2}" "alerts" "$ROOT_POST_ID"

# Nadia — QA acceptance
NADIA_R2_PROMPT="Pour débloquer ${TICKET_KEY}, quels critères d'acceptance devraient être simplifiés ou clarifiés ? Max 2 phrases."
NADIA_R2=$(ceremony_haiku_turn "nadia" "${AI_DIR}/qa.md" "$ROUND2_CTX" "$NADIA_R2_PROMPT")
ceremony_post "nadia" "${NADIA_R2}" "alerts" "$ROOT_POST_ID"

log_info "Round 2 complete."

# ─── 4. Salma makes the final decision ───────────────────────────────────────
log_info "Salma making final decision..."

DECISION_CTX="${ROUND2_CTX}

Round 2 :
- PM (Salma) : ${SALMA_R2}
- Architecture (Rami) : ${RAMI_R2}
- Dev (Youssef) : ${YOUSSEF_R2}
- QA (Nadia) : ${NADIA_R2}"

DECISION_PROMPT="Tu es Salma, PM du projet BisB. Après ce tour de table complet, tu dois prendre LA décision finale pour débloquer le ticket ${TICKET_KEY}.

Réponds UNIQUEMENT avec une ligne de ce format exact :
DECISION: SPLIT|PIVOT|UNBLOCK|ASK_HUMAN
RATIONALE: <une phrase expliquant pourquoi>

Règles :
- SPLIT : si le ticket est trop large (scope > 300 lignes de code, ou plusieurs features distinctes)
- PIVOT : si l'approche technique actuelle est fondamentalement mauvaise
- UNBLOCK : si le problème est un simple détail (manque d'info, bug mineur) et peut reprendre
- ASK_HUMAN : si une décision business ou une ambiguïté majeure nécessite Hedi

Réponds UNIQUEMENT avec les deux lignes DECISION et RATIONALE."

FULL_DECISION_PROMPT="Tu joues un rôle dans une SIMULATION d'équipe Agile fictive pour le projet BisB. Tu incarnes Salma, la PM.

${DECISION_CTX}

${DECISION_PROMPT}

RÈGLES ABSOLUES : Réponds en français. Uniquement les deux lignes demandées. Ne brise pas le personnage."

DECISION_RAW=$(claude -p --model claude-haiku-4-5 --max-turns 1 "$FULL_DECISION_PROMPT" 2>/dev/null || echo "DECISION: ASK_HUMAN
RATIONALE: Impossible de déterminer la décision — escalade à Hedi.")

DECISION=$(echo "$DECISION_RAW" | grep '^DECISION:' | sed 's/DECISION:[[:space:]]*//' | tr -d '[:space:]' | head -1)
RATIONALE=$(echo "$DECISION_RAW" | grep '^RATIONALE:' | sed 's/RATIONALE:[[:space:]]*//' | head -1)

# Validate decision value
case "$DECISION" in
  SPLIT|PIVOT|UNBLOCK|ASK_HUMAN) ;;
  *) DECISION="ASK_HUMAN"; RATIONALE="Décision non reconnue — escalade par précaution." ;;
esac

log_info "Decision: ${DECISION} | Rationale: ${RATIONALE}"

# ─── 5. Execute the decision ─────────────────────────────────────────────────
log_info "Executing decision: ${DECISION}..."

case "$DECISION" in
  SPLIT)
    EXEC_MSG="**Décision : SPLIT** — ${RATIONALE}

Je vais découper ${TICKET_LINK} en sous-tickets plus petits. Le ticket parent sera marqué \`split-parent\`.

$(mm_mention youssef) : attends les nouveaux tickets avant de continuer."

    ceremony_post "salma" "$EXEC_MSG" "alerts" "$ROOT_POST_ID"

    # Mark the ticket as split-parent and hand back to Salma for splitting
    jira_add_label "$TICKET_KEY" "split-parent" 2>/dev/null || true
    jira_add_label "$TICKET_KEY" "needs-split" 2>/dev/null || true
    jira_update_labels "$TICKET_KEY" "agent:youssef" "agent:salma" 2>/dev/null || true
    jira_add_comment "$TICKET_KEY" "Blocker Triage décision : SPLIT. Ticket trop large — Salma va le découper en sous-tickets. Raison : ${RATIONALE}" 2>/dev/null || true

    log_activity "salma" "$TICKET_KEY" "TRIAGE_SPLIT" "Triage decision: SPLIT — ${RATIONALE}"
    ;;

  PIVOT)
    EXEC_MSG="**Décision : PIVOT** — ${RATIONALE}

L'approche actuelle est bloquée. Je vais réécrire la spec de ${TICKET_LINK} avec une nouvelle direction.

$(mm_mention youssef) : j'efface le feedback existant et je te renvoie un nouveau brief."

    ceremony_post "salma" "$EXEC_MSG" "alerts" "$ROOT_POST_ID"

    # Clear existing feedback and send back to Salma for spec rewrite
    rm -f "${FEEDBACK_DIR}/${TICKET_KEY}.txt" 2>/dev/null || true
    jira_update_labels "$TICKET_KEY" "agent:youssef" "agent:salma" 2>/dev/null || true
    jira_add_label "$TICKET_KEY" "pivot" 2>/dev/null || true
    jira_add_comment "$TICKET_KEY" "Blocker Triage décision : PIVOT. Changement d'approche nécessaire. Salma va réécrire la spec. Raison : ${RATIONALE}" 2>/dev/null || true

    log_activity "salma" "$TICKET_KEY" "TRIAGE_PIVOT" "Triage decision: PIVOT — ${RATIONALE}"
    ;;

  UNBLOCK)
    EXEC_MSG="**Décision : UNBLOCK** — ${RATIONALE}

Le blocage est levé. $(mm_mention youssef) peut reprendre ${TICKET_LINK} au prochain cycle.

Le compteur de retry est réinitialisé."

    ceremony_post "salma" "$EXEC_MSG" "alerts" "$ROOT_POST_ID"

    # Reset retry counter so Youssef picks it up again
    reset_retry "$TICKET_KEY" "youssef" 2>/dev/null || true
    jira_add_comment "$TICKET_KEY" "Blocker Triage décision : UNBLOCK. Reprise possible. Raison : ${RATIONALE}" 2>/dev/null || true

    log_activity "salma" "$TICKET_KEY" "TRIAGE_UNBLOCK" "Triage decision: UNBLOCK — ${RATIONALE}"
    ;;

  ASK_HUMAN)
    EXEC_MSG="**Décision : ASK_HUMAN** — ${RATIONALE}

Ce ticket nécessite une décision de Hedi avant de continuer. Je marque ${TICKET_LINK} comme \`needs-human\`.

$(mm_mention salma) mettra à jour le ticket dès que Hedi aura répondu."

    ceremony_post "salma" "$EXEC_MSG" "alerts" "$ROOT_POST_ID"

    # Mark as needing human review
    jira_add_label "$TICKET_KEY" "needs-human" 2>/dev/null || true
    jira_add_label "$TICKET_KEY" "blocked" 2>/dev/null || true
    jira_add_comment "$TICKET_KEY" "Blocker Triage décision : ASK_HUMAN. Intervention de Hedi requise. Raison : ${RATIONALE}" 2>/dev/null || true

    log_activity "salma" "$TICKET_KEY" "TRIAGE_ASK_HUMAN" "Triage decision: ASK_HUMAN — ${RATIONALE}"
    ;;
esac

# ─── 6. Omar closes the round-table ──────────────────────────────────────────
log_info "Omar closing the triage..."

OMAR_CLOSE="Tour de table terminé pour ${TICKET_LINK}.

**Décision finale : ${DECISION}**
${RATIONALE}

Merci à toute l'équipe. Je surveille la suite."

ceremony_post "omar" "$OMAR_CLOSE" "alerts" "$ROOT_POST_ID"

log_success "=== BisB Blocker Triage complete: ${TICKET_KEY} → ${DECISION} ==="
