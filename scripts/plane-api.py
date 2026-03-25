#!/usr/bin/env python3
"""
Plane API helper — mirrors jira-api.py but targets self-hosted Plane.
Plane uses simpler REST API with API key auth and markdown comments.

Usage:
  plane-api.py GET  /api/v1/workspaces/{ws}/projects/{pid}/issues/
  plane-api.py POST /api/v1/workspaces/{ws}/projects/{pid}/issues/ '{"name":"Bug fix"}'
  plane-api.py PATCH /api/v1/workspaces/{ws}/projects/{pid}/issues/{id}/ '{"state":"done"}'

Environment variables required:
  PLANE_API_KEY, PLANE_BASE_URL, PLANE_WORKSPACE_SLUG, PLANE_PROJECT_ID
"""
import requests
import os
import sys
import json


def main():
    if len(sys.argv) < 3:
        print("Usage: plane-api.py METHOD /api/path [json_body]", file=sys.stderr)
        sys.exit(1)

    method = sys.argv[1].upper()
    path = sys.argv[2]
    body = sys.argv[3] if len(sys.argv) > 3 else None

    api_key = os.environ.get("PLANE_API_KEY", "")
    base_url = os.environ.get("PLANE_BASE_URL", "").rstrip("/")

    if not all([api_key, base_url]):
        print("Missing PLANE_API_KEY or PLANE_BASE_URL", file=sys.stderr)
        sys.exit(1)

    url = base_url + path
    headers = {
        "Content-Type": "application/json",
        "X-API-Key": api_key
    }

    try:
        if method == "GET":
            r = requests.get(url, headers=headers, timeout=30)
        elif method == "PUT":
            r = requests.put(url, headers=headers, data=body, timeout=30)
        elif method == "POST":
            r = requests.post(url, headers=headers, data=body, timeout=30)
        elif method == "PATCH":
            r = requests.patch(url, headers=headers, data=body, timeout=30)
        elif method == "DELETE":
            r = requests.delete(url, headers=headers, timeout=30)
        else:
            print(f"Unsupported method: {method}", file=sys.stderr)
            sys.exit(1)

        if r.text:
            print(r.text)

        if 200 <= r.status_code < 300:
            sys.exit(0)
        else:
            print(f"Plane API error: {r.status_code} {r.reason}", file=sys.stderr)
            sys.exit(1)

    except Exception as e:
        print(f"Plane API request failed: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
