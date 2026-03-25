#!/usr/bin/env bash
# =============================================================================
# run-standup.sh — Daily Standup wrapper → delegates to ceremony-standup.sh
# Triggered: daily 08:00 UTC (09:00 Tunis) weekdays via cron
# =============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "${SCRIPT_DIR}/ceremony-standup.sh" "$@"
