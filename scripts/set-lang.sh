#!/usr/bin/env bash
# =============================================================================
# set-lang.sh — Switch the agent communication language
#
# Usage: bash set-lang.sh [fr|en|de]
#
# Languages:
#   fr — Français (default, naturel pour l'équipe tunisienne)
#   en — English (for international communication / marketing)
#   de — Deutsch (for German market / marketing purposes)
#
# This updates BISB_LANG in /etc/${PROJECT_PREFIX}/.env.agents and notifies the team.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/agent-common.sh" 2>/dev/null || true
source "${SCRIPT_DIR}/tracker-common.sh" 2>/dev/null || true

LANG_CODE="${1:-}"
ENV_FILE="/etc/${PROJECT_PREFIX}/.env.agents"

if [[ -z "$LANG_CODE" ]]; then
  echo "Usage: set-lang.sh [fr|en|de]"
  echo ""
  echo "Current language: $(grep -oP 'BISB_LANG=\K\w+' "$ENV_FILE" 2>/dev/null || echo 'fr (default)')"
  exit 0
fi

case "$LANG_CODE" in
  fr) LANG_NAME="Français" ;;
  en) LANG_NAME="English" ;;
  de) LANG_NAME="Deutsch" ;;
  *)
    echo "❌ Langue non supportée: $LANG_CODE (options: fr, en, de)"
    exit 1
    ;;
esac

# Update or add BISB_LANG in env file
if grep -q '^BISB_LANG=' "$ENV_FILE" 2>/dev/null; then
  sed -i "s/^BISB_LANG=.*/BISB_LANG=${LANG_CODE}/" "$ENV_FILE"
else
  echo "" >> "$ENV_FILE"
  echo "# Agent communication language (fr=French, en=English, de=German)" >> "$ENV_FILE"
  echo "BISB_LANG=${LANG_CODE}" >> "$ENV_FILE"
fi

echo "✅ Langue changée → ${LANG_NAME} (${LANG_CODE})"

# Notify team
NOTIFY_MSG=""
case "$LANG_CODE" in
  fr) NOTIFY_MSG="🇫🇷 *Changement de langue* — L'équipe passe en français. À partir du prochain cycle, tous les messages seront en français." ;;
  en) NOTIFY_MSG="🇬🇧 *Language switch* — The team is switching to English. From the next cycle, all messages will be in English." ;;
  de) NOTIFY_MSG="🇩🇪 *Sprachwechsel* — Das Team wechselt zu Deutsch. Ab dem nächsten Zyklus sind alle Nachrichten auf Deutsch." ;;
esac

# Post notification to pipeline channel
if declare -f slack_notify &>/dev/null; then
  slack_notify "$NOTIFY_MSG" "pipeline"
  echo "📢 Notification envoyée au pipeline."
fi
