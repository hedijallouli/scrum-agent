#!/usr/bin/env python3
"""Query Jira for tickets matching a JQL query. Returns ticket keys one per line."""
import requests, os, sys

def main():
    if len(sys.argv) < 2:
        print('Usage: jira-query.py <JQL>', file=sys.stderr)
        sys.exit(1)

    jql = sys.argv[1]
    email = os.environ.get('JIRA_EMAIL', '')
    token = os.environ.get('JIRA_API_TOKEN', '')
    base_url = os.environ.get('JIRA_BASE_URL', '')

    if not all([email, token, base_url]):
        print('Missing JIRA_EMAIL, JIRA_API_TOKEN, or JIRA_BASE_URL', file=sys.stderr)
        sys.exit(1)

    url = base_url + '/rest/api/3/search/jql'
    try:
        r = requests.get(
            url,
            params={'jql': jql, 'fields': 'key', 'maxResults': '5'},
            auth=(email, token),
            timeout=15
        )
        r.raise_for_status()
        for issue in r.json().get('issues', []):
            print(issue['key'])
    except Exception as e:
        print(f'Jira query error: {e}', file=sys.stderr)
        sys.exit(1)

if __name__ == '__main__':
    main()
