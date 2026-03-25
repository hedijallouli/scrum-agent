#!/usr/bin/env bash
# =============================================================================
# ceremony-refinement.sh — Backlog Refinement Session
# Triggered: weekly on Thursday (via cron or manually)
# Usage: ceremony-refinement.sh
#
# Flow:
#   1. Salma opens in #standup channel
#   2. For each of top 5 unrefined backlog tickets:
#      Salma → Rami (complexity) → Youssef (effort) → Nadia (AC) → Layla (value)
#   3. Salma writes structured comment to ticket in Plane
#   4. Omar closes
# =============================================================================
set -euo pipefail

export PATH="$HOME/.local/bin:/usr/local/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENT_NAME="salma"
source "${SCRIPT_DIR}/agent-common.sh"
source "${SCRIPT_DIR}/ceremony-common.sh"

LOG_FILE="/var/log/bisb/ceremony-refinement.log"
mkdir -p /var/log/bisb

log_info "=== Backlog Refinement Ceremony Starting ==="

# ── Ceremony channel ──────────────────────────────────────────────────────────
CEREMONY_CHANNEL="standup"

# ─── Fetch top 5 unrefined backlog tickets ───────────────────────────────────
# "Unrefined" = state Todo, not in active sprint, no blocked/needs-human label.
# We sort by priority desc (urgent first), then oldest first.
log_info "Fetching unrefined backlog tickets..."

BACKLOG_TICKETS_RAW=$(jira_search_keys_with_summaries \
  "project = ${PROJECT_KEY} AND statusCategory != 'Done' AND sprint is EMPTY AND labels NOT IN ('blocked','needs-human-review','needs-human','refined')" \
  "5" 2>/dev/null || echo "")

# Fallback: fetch any backlog tickets if sprint field not supported
if [[ -z "$BACKLOG_TICKETS_RAW" ]]; then
  BACKLOG_TICKETS_RAW=$(jira_search_keys_with_summaries \
    "project = ${PROJECT_KEY} AND statusCategory != 'Done' AND labels NOT IN ('blocked','needs-human-review','needs-human','refined')" \
    "5" 2>/dev/null || echo "")
fi

TICKET_COUNT=$(echo "$BACKLOG_TICKETS_RAW" | grep -c '|' 2>/dev/null || echo "0")
log_info "Found $TICKET_COUNT unrefined backlog tickets"

if [[ "$TICKET_COUNT" -eq 0 ]]; then
  log_info "No unrefined tickets found. Nothing to refine."
  AGENT_NAME="salma"
  if [[ "${CHAT_BACKEND:-slack}" == "mattermost" ]]; then
    mm_post "📋 **Backlog Refinement** : Aucun ticket non-raffiné trouvé dans le backlog. Backlog déjà propre ✅" \
      "$CEREMONY_CHANNEL" "" ""
  else
    slack_notify "📋 *Backlog Refinement* : Aucun ticket non-raffiné trouvé dans le backlog. Backlog déjà propre ✅" \
      "$CEREMONY_CHANNEL"
  fi
  log_success "No tickets to refine — ceremony complete."
  exit 0
fi

# ── Build ticket list for opening message ─────────────────────────────────────
TICKET_LIST_DISPLAY=$(echo "$BACKLOG_TICKETS_RAW" | python3 -c "
import sys
lines = [l.strip() for l in sys.stdin if l.strip()]
out = []
for i, line in enumerate(lines, 1):
    parts = line.split('|', 1)
    key = parts[0].strip()
    summary = parts[1].strip() if len(parts) > 1 else '(pas de titre)'
    out.append(f'  {i}. {key}: {summary[:65]}')
print('\n'.join(out))
" 2>/dev/null || echo "  (liste indisponible)")

# ── Open ceremony root thread ─────────────────────────────────────────────────
log_info "Salma opens the Refinement session..."

SALMA_OPEN="📋 **Backlog Refinement** — Session de jeudi !

Top **${TICKET_COUNT}** tickets à affiner avant le prochain sprint planning :

${TICKET_LIST_DISPLAY}

*Tour de table pour chaque ticket : Rami (complexité) → Youssef (effort) → Nadia (critères) → Layla (valeur).*
*Chaque ticket reçoit une estimation structurée. C'est parti ! 👇*"

CEREMONY_ROOT_ID=""
AGENT_NAME="salma"
if [[ "${CHAT_BACKEND:-slack}" == "mattermost" ]]; then
  CEREMONY_ROOT_ID=$(mm_post "$SALMA_OPEN" "$CEREMONY_CHANNEL" "" "" "return_id" 2>/dev/null || echo "")
else
  slack_notify "$SALMA_OPEN" "$CEREMONY_CHANNEL"
fi
sleep 30

# ─── Per-ticket refinement loop ───────────────────────────────────────────────
TICKET_INDEX=0

while IFS='|' read -r raw_key raw_summary; do
  TICKET_KEY=$(echo "$raw_key" | tr -d '[:space:]')
  TICKET_SUMMARY=$(echo "$raw_summary" | xargs 2>/dev/null || echo "$raw_summary")
  [[ -z "$TICKET_KEY" ]] && continue

  TICKET_INDEX=$(( TICKET_INDEX + 1 ))
  log_info "Refining ticket ${TICKET_INDEX}/${TICKET_COUNT}: ${TICKET_KEY} — ${TICKET_SUMMARY}"

  # Fetch ticket description for richer context
  TICKET_DESCRIPTION=$(jira_get_description_text "$TICKET_KEY" 2>/dev/null || echo "Pas de description disponible.")
  if [[ -z "$TICKET_DESCRIPTION" || "$TICKET_DESCRIPTION" == "None" ]]; then
    TICKET_DESCRIPTION="Pas de description disponible."
  fi

  TICKET_CONTEXT="Ticket : ${TICKET_KEY}
Titre : ${TICKET_SUMMARY}
Description actuelle : ${TICKET_DESCRIPTION:-Pas de description disponible.}

Projet : BisB — jeu de société tunisien digitalisé (TypeScript, React, engine pattern Command/Event)
Stack : packages/engine (game logic) + packages/web (React UI) | Tests : Vitest"

  # ── Salma introduces the ticket ────────────────────────────────────────────
  log_info "  Salma introduces ${TICKET_KEY}..."

  SALMA_INTRO="---
🎯 **Ticket ${TICKET_INDEX}/${TICKET_COUNT} : ${TICKET_KEY}**
> *${TICKET_SUMMARY}*

*Description :* ${TICKET_DESCRIPTION:0:200}$([ ${#TICKET_DESCRIPTION} -gt 200 ] && echo '…' || echo '')

Équipe, on assess ce ticket. Rami, tu commences ?"

  AGENT_NAME="salma"
  if [[ "${CHAT_BACKEND:-slack}" == "mattermost" && -n "$CEREMONY_ROOT_ID" ]]; then
    mm_post "$SALMA_INTRO" "$CEREMONY_CHANNEL" "" "$CEREMONY_ROOT_ID"
  else
    slack_notify "$SALMA_INTRO" "$CEREMONY_CHANNEL"
  fi
  sleep 30

  # ── Rami: complexity assessment ────────────────────────────────────────────
  log_info "  Rami assesses complexity for ${TICKET_KEY}..."

  RAMI_PROMPT="Tu évalues la COMPLEXITÉ technique de ce ticket lors du Backlog Refinement.

TICKET À ÉVALUER:
${TICKET_CONTEXT}

Format OBLIGATOIRE:
'Ce ticket est [Simple/Moyen/Complexe] — voici pourquoi : [2-3 raisons techniques précises].
Impact architecture : [quels fichiers/systèmes touchés]. Risques : [risques spécifiques ou 'aucun risque majeur'].'

Sois concret. Mentionne les fichiers/packages BisB si pertinent."

  RAMI_MSG=$(ceremony_haiku_turn \
    "rami" \
    "${SCRIPT_DIR}/../ai/architect.md" \
    "$TICKET_CONTEXT" \
    "$RAMI_PROMPT")

  AGENT_NAME="rami"
  if [[ "${CHAT_BACKEND:-slack}" == "mattermost" && -n "$CEREMONY_ROOT_ID" ]]; then
    mm_post "🏗️ **Rami** :\n\n${RAMI_MSG}" "$CEREMONY_CHANNEL" "" "$CEREMONY_ROOT_ID"
  else
    slack_notify "🏗️ *Rami* :\n\n${RAMI_MSG}" "$CEREMONY_CHANNEL"
  fi
  sleep 30

  # ── Youssef: effort estimate ────────────────────────────────────────────────
  log_info "  Youssef estimates effort for ${TICKET_KEY}..."

  YOUSSEF_PROMPT="Tu estimes l'EFFORT de développement de ce ticket lors du Backlog Refinement.
L'architecte (Rami) vient de dire : '${RAMI_MSG}'

TICKET À ÉVALUER:
${TICKET_CONTEXT}

Format OBLIGATOIRE:
'Je dirais [S/M/L/XL] — environ [X jours]. [Justification basée sur la complexité réelle].
Si Rami me donne [le pattern/l'architecture], je peux l'estimer à [taille réduite].'

Tailles : S=0.5j, M=1j, L=2-3j, XL=4j+
Sois réaliste, pas optimiste à outrance."

  YOUSSEF_MSG=$(ceremony_haiku_turn \
    "youssef" \
    "${SCRIPT_DIR}/../ai/dev.md" \
    "$TICKET_CONTEXT" \
    "$YOUSSEF_PROMPT")

  AGENT_NAME="youssef"
  if [[ "${CHAT_BACKEND:-slack}" == "mattermost" && -n "$CEREMONY_ROOT_ID" ]]; then
    mm_post "🔨 **Youssef** :\n\n${YOUSSEF_MSG}" "$CEREMONY_CHANNEL" "" "$CEREMONY_ROOT_ID"
  else
    slack_notify "🔨 *Youssef* :\n\n${YOUSSEF_MSG}" "$CEREMONY_CHANNEL"
  fi
  sleep 30

  # ── Nadia: acceptance criteria ─────────────────────────────────────────────
  log_info "  Nadia writes acceptance criteria for ${TICKET_KEY}..."

  NADIA_PROMPT="Tu rédiges les CRITÈRES D'ACCEPTATION de ce ticket lors du Backlog Refinement.

TICKET À ÉVALUER:
${TICKET_CONTEXT}

Format OBLIGATOIRE:
'Pour valider ça, il nous faut :
(1) [cas de test nominal — comportement attendu]
(2) [cas de test négatif ou erreur]
(3) [cas limite ou edge case]
Total: 3 critères (minimum). QA signoff requis sur tous.'

Sois précise. Les critères doivent être testables concrètement dans le contexte BisB."

  NADIA_MSG=$(ceremony_haiku_turn \
    "nadia" \
    "${SCRIPT_DIR}/../ai/qa.md" \
    "$TICKET_CONTEXT" \
    "$NADIA_PROMPT")

  AGENT_NAME="nadia"
  if [[ "${CHAT_BACKEND:-slack}" == "mattermost" && -n "$CEREMONY_ROOT_ID" ]]; then
    mm_post "🔍 **Nadia** :\n\n${NADIA_MSG}" "$CEREMONY_CHANNEL" "" "$CEREMONY_ROOT_ID"
  else
    slack_notify "🔍 *Nadia* :\n\n${NADIA_MSG}" "$CEREMONY_CHANNEL"
  fi
  sleep 30

  # ── Layla: business value / player perspective ─────────────────────────────
  log_info "  Layla assesses value for ${TICKET_KEY}..."

  LAYLA_PROMPT="Tu évalues la VALEUR JOUEUR de ce ticket lors du Backlog Refinement. Tu es Layla.

TICKET À ÉVALUER:
${TICKET_CONTEXT}

Format OBLIGATOIRE:
'Du point de vue joueur, [ce ticket] est [haute/moyenne/basse] priorité parce que [raison centrée joueur BisB].
Impact sur l'expérience de jeu : [impact concret sur les mécaniques — enchères, propriétés, casino, tombola, etc.].
Recommandation sprint : [à faire ce sprint / peut attendre / bloquant pour X].'

Ancre-toi dans les mécaniques du jeu BisB."

  LAYLA_MSG=$(ceremony_haiku_turn \
    "layla" \
    "${SCRIPT_DIR}/../ai/product-marketing.md" \
    "$TICKET_CONTEXT" \
    "$LAYLA_PROMPT")

  AGENT_NAME="layla"
  if [[ "${CHAT_BACKEND:-slack}" == "mattermost" && -n "$CEREMONY_ROOT_ID" ]]; then
    mm_post "📊 **Layla** :\n\n${LAYLA_MSG}" "$CEREMONY_CHANNEL" "" "$CEREMONY_ROOT_ID"
  else
    slack_notify "📊 *Layla* :\n\n${LAYLA_MSG}" "$CEREMONY_CHANNEL"
  fi
  sleep 30

  # ── Salma writes structured refinement comment to ticket ──────────────────
  log_info "  Salma writes refinement comment to ${TICKET_KEY}..."

  # Extract effort estimate size (S/M/L/XL) from Youssef's message
  EFFORT_SIZE=$(echo "$YOUSSEF_MSG" | python3 -c "
import sys, re
text = sys.stdin.read()
# Look for T-shirt size at start of answer
m = re.search(r'\b(XL|L|M|S)\b', text, re.IGNORECASE)
print(m.group(0).upper() if m else 'M')
" 2>/dev/null || echo "M")

  EFFORT_DAYS=$(echo "$YOUSSEF_MSG" | python3 -c "
import sys, re
text = sys.stdin.read()
# Look for X jours / X day
m = re.search(r'(\d+(?:\.\d+)?)\s*(?:jour|day)', text, re.IGNORECASE)
print(m.group(1) if m else '1')
" 2>/dev/null || echo "1")

  COMPLEXITY_LEVEL=$(echo "$RAMI_MSG" | python3 -c "
import sys, re
text = sys.stdin.read()
m = re.search(r'\b(Simple|Moyen|Complexe)\b', text, re.IGNORECASE)
print(m.group(0).capitalize() if m else 'Moyen')
" 2>/dev/null || echo "Moyen")

  PRIORITY_LEVEL=$(echo "$LAYLA_MSG" | python3 -c "
import sys, re
text = sys.stdin.read()
m = re.search(r'\b(haute|moyenne|basse)\s+priorit[eé]', text, re.IGNORECASE)
if m:
    print(m.group(1).capitalize())
else:
    m2 = re.search(r'priorit[eé]\s+:\s*([^\n.]+)', text, re.IGNORECASE)
    print(m2.group(1).strip()[:20] if m2 else 'Moyenne')
" 2>/dev/null || echo "Moyenne")

  REFINEMENT_COMMENT="## Refinement — $(date '+%Y-%m-%d')

### Complexité (Rami)
${RAMI_MSG}

### Estimation effort (Youssef)
**Taille : ${EFFORT_SIZE} (~${EFFORT_DAYS} jour(s))**

${YOUSSEF_MSG}

### Critères d'acceptation (Nadia)
${NADIA_MSG}

### Valeur joueur (Layla)
**Priorité : ${PRIORITY_LEVEL}**

${LAYLA_MSG}

---
_Raffiné lors du Backlog Refinement — complexité ${COMPLEXITY_LEVEL}, effort ${EFFORT_SIZE}, priorité ${PRIORITY_LEVEL}_"

  jira_add_comment "$TICKET_KEY" "$REFINEMENT_COMMENT" 2>/dev/null || \
    log_error "Failed to add refinement comment to $TICKET_KEY"

  # Add 'refined' label so ticket is excluded from next refinement run
  jira_add_label "$TICKET_KEY" "refined" 2>/dev/null || \
    log_info "Could not add 'refined' label to $TICKET_KEY (non-fatal)"

  log_info "  Refinement comment added to $TICKET_KEY"
  sleep 2  # Rate-limit Plane/Jira API

done <<< "$BACKLOG_TICKETS_RAW"

# ─── Salma: summary closing ───────────────────────────────────────────────────
log_info "Salma posts refinement summary..."

SALMA_SUMMARY_PROMPT="Tu conclus le Backlog Refinement. Tu es Salma.

Vous venez d'affiner ${TICKET_COUNT} tickets ensemble.
Donne un résumé en 2 phrases : ce qui a été raffiné, et si le backlog est prêt pour le sprint planning.
Format: 'Refinement terminé. Nous avons affiné ${TICKET_COUNT} tickets : [liste brève]. Le backlog est [prêt/presque prêt] pour le planning de jeudi.'
Reste concise."

SALMA_SUMMARY=$(ceremony_haiku_turn \
  "salma" \
  "${SCRIPT_DIR}/../ai/pm.md" \
  "Session de refinement : ${TICKET_COUNT} tickets affinés. Tickets : ${TICKET_LIST_DISPLAY}" \
  "$SALMA_SUMMARY_PROMPT")

AGENT_NAME="salma"
if [[ "${CHAT_BACKEND:-slack}" == "mattermost" && -n "$CEREMONY_ROOT_ID" ]]; then
  mm_post "📋 **Salma** — Clôture Refinement :\n\n${SALMA_SUMMARY}" "$CEREMONY_CHANNEL" "" "$CEREMONY_ROOT_ID"
else
  slack_notify "📋 *Salma — Clôture Refinement* :\n\n${SALMA_SUMMARY}" "$CEREMONY_CHANNEL"
fi
sleep 30

# ─── Omar: final sign-off ─────────────────────────────────────────────────────
log_info "Omar closes the refinement..."

OMAR_CLOSE="📅 **Omar** (Scrum Master) — Refinement terminé.

**${TICKET_COUNT} tickets** affinés et commentés dans Plane. Backlog prêt pour le planning de jeudi.

_Prochain refinement : jeudi prochain._"

AGENT_NAME="omar"
if [[ "${CHAT_BACKEND:-slack}" == "mattermost" && -n "$CEREMONY_ROOT_ID" ]]; then
  mm_post "$OMAR_CLOSE" "$CEREMONY_CHANNEL" "" "$CEREMONY_ROOT_ID"
else
  slack_notify "$OMAR_CLOSE" "$CEREMONY_CHANNEL"
fi

log_success "=== Backlog Refinement Complete: ${TICKET_COUNT} tickets refined ==="
