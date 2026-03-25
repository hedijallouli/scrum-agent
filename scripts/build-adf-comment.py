#!/usr/bin/env python3
"""
Build Jira ADF (Atlassian Document Format) comment from plain text.
Used by jira_add_rich_comment() in agent-common.sh.

Usage: echo "message" | python3 build-adf-comment.py display_name job_title panel_type verdict emoji_shortname emoji_id

Outputs JSON suitable for Jira REST API POST /rest/api/3/issue/{key}/comment
"""
import json
import sys

def main():
    if len(sys.argv) < 5:
        print(json.dumps({"body": {"version": 1, "type": "doc", "content": []}}))
        sys.exit(0)

    display_name = sys.argv[1]
    job_title = sys.argv[2]
    panel_type = sys.argv[3]  # info, success, error, warning, note
    verdict = sys.argv[4]
    emoji_shortname = sys.argv[5] if len(sys.argv) > 5 else ""
    emoji_id = sys.argv[6] if len(sys.argv) > 6 else ""

    # Read message from stdin
    message = sys.stdin.read().strip()

    # Parse message into ADF content blocks
    content_blocks = []

    # Header with agent identity
    header_content = []
    if emoji_shortname and emoji_id:
        header_content.append({
            "type": "emoji",
            "attrs": {"shortName": emoji_shortname, "id": emoji_id}
        })
        header_content.append({"type": "text", "text": " "})

    header_content.append({
        "type": "text",
        "text": display_name,
        "marks": [{"type": "strong"}]
    })
    if job_title:
        header_content.append({
            "type": "text",
            "text": f" — {job_title}"
        })

    content_blocks.append({
        "type": "paragraph",
        "content": header_content
    })

    # Verdict badge
    verdict_colors = {
        "PASS": "#36B37E",
        "FAIL": "#FF5630",
        "WARNING": "#FFAB00",
        "INFO": "#0065FF"
    }
    color = verdict_colors.get(verdict, "#6554C0")

    content_blocks.append({
        "type": "paragraph",
        "content": [{
            "type": "text",
            "text": f"[{verdict}]",
            "marks": [
                {"type": "strong"},
                {"type": "textColor", "attrs": {"color": color}}
            ]
        }]
    })

    # Message body
    for line in message.split("\n"):
        stripped = line.strip()
        if not stripped:
            continue
        elif stripped.startswith("## "):
            content_blocks.append({
                "type": "heading",
                "attrs": {"level": 3},
                "content": [{"type": "text", "text": stripped[3:]}]
            })
        elif stripped.startswith("- [ ] "):
            content_blocks.append({
                "type": "paragraph",
                "content": [{"type": "text", "text": "☐ " + stripped[6:]}]
            })
        elif stripped.startswith("- [x] "):
            content_blocks.append({
                "type": "paragraph",
                "content": [{"type": "text", "text": "✅ " + stripped[6:]}]
            })
        elif stripped.startswith("- "):
            content_blocks.append({
                "type": "paragraph",
                "content": [{"type": "text", "text": "• " + stripped[2:]}]
            })
        elif stripped.startswith("**") and stripped.endswith("**"):
            content_blocks.append({
                "type": "paragraph",
                "content": [{
                    "type": "text",
                    "text": stripped[2:-2],
                    "marks": [{"type": "strong"}]
                }]
            })
        else:
            content_blocks.append({
                "type": "paragraph",
                "content": [{"type": "text", "text": stripped}]
            })

    # Wrap in panel
    adf = {
        "body": {
            "version": 1,
            "type": "doc",
            "content": [{
                "type": "panel",
                "attrs": {"panelType": panel_type},
                "content": content_blocks
            }]
        }
    }

    print(json.dumps(adf))

if __name__ == "__main__":
    main()
