#!/usr/bin/env bash
# =============================================================================
# plane-curl.sh — Drop-in replacement for jira-curl.sh targeting Plane API.
# Parses curl-style arguments and routes to plane-api.py.
#
# This file is called by the tracker abstraction layer in agent-common.sh
# when TRACKER_BACKEND=plane. It has the same interface as jira-curl.sh.
# =============================================================================

# Parse curl-style arguments
METHOD="GET"
URL=""
DATA=""
SILENT=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    -s) SILENT=true; shift ;;
    -X) METHOD="$2"; shift 2 ;;
    -H) shift 2 ;;  # Headers handled by plane-api.py
    -d) DATA="$2"; shift 2 ;;
    -w*) shift; [[ "${1:-}" != -* ]] && shift ;;
    --http1.1|--http2) shift ;;
    *)
      if [[ "$1" == http* || "$1" == */api/* ]]; then
        URL="$1"
      fi
      shift
      ;;
  esac
done

if [[ -z "$URL" ]]; then
  echo "plane-curl: no URL provided" >&2
  exit 1
fi

# Extract path from full URL
PLANE_BASE="${PLANE_BASE_URL:-}"
PATH_PART="${URL#${PLANE_BASE}}"

# If URL doesn't start with base URL, try to extract /api/... path
if [[ "$PATH_PART" == "$URL" ]]; then
  PATH_PART=$(echo "$URL" | grep -oP '/api/.*')
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -n "$DATA" ]]; then
  python3 "${SCRIPT_DIR}/plane-api.py" "$METHOD" "$PATH_PART" "$DATA"
else
  python3 "${SCRIPT_DIR}/plane-api.py" "$METHOD" "$PATH_PART"
fi
