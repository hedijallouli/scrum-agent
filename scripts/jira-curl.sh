#!/usr/bin/env bash
# =============================================================================
# jira-curl — Drop-in curl replacement for Jira API calls.
# curl HTTP/2 is broken on this VPS (error 43). This wrapper parses the curl
# arguments and routes the request through Python requests instead.
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
    -H) shift 2 ;;  # Headers are handled by jira-api.py
    -d) DATA="$2"; shift 2 ;;
    -w*) shift; [[ "$1" != -* ]] && shift ;;  # Skip -w format
    --http1.1|--http2) shift ;;
    *)
      # This should be the URL
      if [[ "$1" == http* || "$1" == *JIRA_BASE_URL* || "$1" == */rest/* ]]; then
        URL="$1"
      fi
      shift
      ;;
  esac
done

if [[ -z "$URL" ]]; then
  echo "jira-curl: no URL provided" >&2
  exit 1
fi

# Extract path from full URL (remove base URL prefix)
JIRA_BASE="${JIRA_BASE_URL}"
PATH_PART="${URL#${JIRA_BASE}}"

# If URL doesn't start with base URL, try to extract /rest/... path
if [[ "$PATH_PART" == "$URL" ]]; then
  PATH_PART=$(echo "$URL" | grep -oP '/rest/.*')
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -n "$DATA" ]]; then
  python3 "${SCRIPT_DIR}/jira-api.py" "$METHOD" "$PATH_PART" "$DATA"
else
  python3 "${SCRIPT_DIR}/jira-api.py" "$METHOD" "$PATH_PART"
fi
