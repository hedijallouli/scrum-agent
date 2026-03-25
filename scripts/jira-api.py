#!/usr/bin/env python3
"""
Universal Jira API helper — replaces curl for all Jira REST calls.
curl is broken on this VPS (HTTP/2 error 43 + HTTP/1.1 returns 400).
Python requests library works fine.

Usage:
  jira-api.py GET  /rest/api/3/issue/BISB-22?fields=summary
  jira-api.py PUT  /rest/api/3/issue/BISB-22 '{"fields":{"description":{...}}}'
  jira-api.py POST /rest/api/3/issue/BISB-22/comment '{"body":{...}}'
  jira-api.py DELETE /rest/api/3/issue/BISB-22/comment/12345

Environment variables required:
  JIRA_EMAIL, JIRA_API_TOKEN, JIRA_BASE_URL
"""
import requests
import os
import sys
import json


def main():
    if len(sys.argv) < 3:
        print("Usage: jira-api.py METHOD /rest/path [json_body]", file=sys.stderr)
        sys.exit(1)

    method = sys.argv[1].upper()
    path = sys.argv[2]
    body = sys.argv[3] if len(sys.argv) > 3 else None

    email = os.environ.get("JIRA_EMAIL", "")
    token = os.environ.get("JIRA_API_TOKEN", "")
    base_url = os.environ.get("JIRA_BASE_URL", "")

    if not all([email, token, base_url]):
        print("Missing JIRA_EMAIL, JIRA_API_TOKEN, or JIRA_BASE_URL", file=sys.stderr)
        sys.exit(1)

    url = base_url.rstrip("/") + path
    headers = {"Content-Type": "application/json"}

    try:
        if method == "GET":
            r = requests.get(url, auth=(email, token), headers=headers, timeout=30)
        elif method == "PUT":
            r = requests.put(url, auth=(email, token), headers=headers, data=body, timeout=30)
        elif method == "POST":
            r = requests.post(url, auth=(email, token), headers=headers, data=body, timeout=30)
        elif method == "DELETE":
            r = requests.delete(url, auth=(email, token), headers=headers, timeout=30)
        else:
            print(f"Unsupported method: {method}", file=sys.stderr)
            sys.exit(1)

        # Print response body to stdout (for scripts that need to parse it)
        if r.text:
            print(r.text)

        # Exit with 0 for success (2xx), 1 for errors
        if r.status_code >= 200 and r.status_code < 300:
            sys.exit(0)
        else:
            print(f"Jira API error: {r.status_code} {r.reason}", file=sys.stderr)
            sys.exit(1)

    except Exception as e:
        print(f"Jira API request failed: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
