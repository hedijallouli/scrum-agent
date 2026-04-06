#!/usr/bin/env bash
# =============================================================================
# tracker-common.sh — Abstraction layer for project trackers (Jira/Plane)
#
# Provides tracker-agnostic functions that dispatch to the correct backend
# based on TRACKER_BACKEND env var (default: "jira").
#
# Usage: source this AFTER agent-common.sh (it wraps jira_* functions)
#
# When TRACKER_BACKEND=jira  → uses existing jira_* functions (no change)
# When TRACKER_BACKEND=plane → uses plane_* functions defined here
# =============================================================================

TRACKER_BACKEND="${TRACKER_BACKEND:-jira}"

# ─── Plane API Helpers ─────────────────────────────────────────────────────
# These mirror jira_* functions but use Plane's REST API.
# Only loaded when TRACKER_BACKEND=plane.

if [[ "$TRACKER_BACKEND" == "plane" ]]; then
  PLANE_WS="${PLANE_WORKSPACE_SLUG:?Missing PLANE_WORKSPACE_SLUG}"
  PLANE_PID="${PLANE_PROJECT_ID:?Missing PLANE_PROJECT_ID}"
  PLANE_API="${PLANE_BASE_URL:?Missing PLANE_BASE_URL}/api/v1"

  # Per-agent Plane API keys (real user accounts — actions attributed to the agent)
  declare -A PLANE_AGENT_KEY=(
    [salma]="${PLANE_API_KEY_SALMA:-}"
    [youssef]="${PLANE_API_KEY_YOUSSEF:-}"
    [nadia]="${PLANE_API_KEY_NADIA:-}"
    [omar]="${PLANE_API_KEY_OMAR:-}"
    [rami]="${PLANE_API_KEY_RAMI:-}"
    [layla]="${PLANE_API_KEY_LAYLA:-}"
    [dispatcher]="${PLANE_API_KEY:-}"
  )

  # ─── Agent Plane User IDs (for assignment-based dispatch) ──────────────────
  # Full name → Plane member UUID (used for ticket assignees)
  declare -A PLANE_AGENT_USER_ID=(
    [salma]="e00f100f-6389-4bb0-8348-391ff8919c8d"
    [youssef]="2fdb6929-392f-4b0c-bb18-3e45c5121ec4"
    [nadia]="64f56e16-7ed3-4812-b09b-912f6a615e12"
    [rami]="df2af0b5-bfa6-4f65-b216-32d9ae799071"
    [omar]="435563ee-fef1-4cab-9048-653e0e7bb74a"
    [layla]="7da952f8-7d8f-45e9-9feb-70fba6ef45a4"
    [hedi]="635b2c8a-9532-49f8-8562-1fd182e09cd1"   # human lead — assigned when needs-human
    # [karim] retired — DevOps absorbed by Omar (same Plane user ID as Rami)
  )

  # ─── State UUIDs for the two new workflow states ────────────────────────────
  # Created by plane_migrate.py — hardcoded here for fast access without an API call.
  PLANE_STATE_BLOCKED="351f4d98-9660-43df-b0a7-9af820e3042e"
  PLANE_STATE_NEEDS_HUMAN="66423815-6ecd-4da8-b6ef-f3599005f55b"

  # Set a Plane ticket's state by name (Blocked / Needs Human / etc.)
  # Usage: plane_set_state BISB-49 "Blocked"
  plane_set_state() {
    local key="$1" state_name="$2"
    local seq_num="${key##*-}"
    # Resolve state_name to UUID
    local state_id
    case "$state_name" in
      Blocked)      state_id="$PLANE_STATE_BLOCKED" ;;
      "Needs Human") state_id="$PLANE_STATE_NEEDS_HUMAN" ;;
      *)
        # Dynamic lookup for other state names
        state_id=$(python3 -c "
import os, requests
base=os.environ.get('PLANE_BASE_URL','').rstrip('/')
ws=os.environ.get('PLANE_WORKSPACE_SLUG','')
pid=os.environ.get('PLANE_PROJECT_ID','')
key=os.environ.get('PLANE_API_KEY','')
h={'X-API-Key': key}
r=requests.get(f'{base}/api/v1/workspaces/{ws}/projects/{pid}/states/', headers=h, timeout=10)
states=r.json() if isinstance(r.json(),list) else r.json().get('results',[])
match=next((s for s in states if s.get('name','')==sys.argv[1]),None)
print(match['id'] if match else '')
import sys" "$state_name" 2>/dev/null)
        ;;
    esac
    [[ -z "$state_id" ]] && { log_info "plane_set_state: unknown state '${state_name}'"; return 0; }

    python3 -c "
import os, requests, sys
seq=int(sys.argv[1]); state_id=sys.argv[2]
base=os.environ.get('PLANE_BASE_URL','').rstrip('/')
ws=os.environ.get('PLANE_WORKSPACE_SLUG','')
pid=os.environ.get('PLANE_PROJECT_ID','')
key=os.environ.get('PLANE_API_KEY','')
h={'X-API-Key': key, 'Content-Type': 'application/json'}
r=requests.get(f'{base}/api/v1/workspaces/{ws}/projects/{pid}/issues/?per_page=200',headers=h,timeout=15)
issues=r.json().get('results',[])
issue=next((x for x in issues if x.get('sequence_id')==seq),None)
if not issue: sys.exit(0)
requests.patch(f'{base}/api/v1/workspaces/{ws}/projects/{pid}/issues/{issue[\"id\"]}/',
    headers=h, json={'state': state_id}, timeout=10)
" "$seq_num" "$state_id" 2>/dev/null || true
    log_info "plane_set_state: ${key} → ${state_name}"
  }

  # Override jira_add_label for Plane — maps labels to state changes (labels are deprecated)
  # Usage: jira_add_label BISB-49 blocked
  jira_add_label() {
    local key="$1" label="$2"
    case "$label" in
      blocked)
        plane_set_state "$key" "Blocked" ;;
      needs-human|needs-human-review|needs-human-input|needs-standup-review)
        plane_set_state "$key" "Needs Human" ;;
      *)
        # All other labels deprecated — log and skip
        log_info "jira_add_label('${label}') no-op: labels deprecated in Plane mode"
        ;;
    esac
  }

  # Assign a Plane ticket to a specific agent
  # Usage: plane_assign_ticket BISB-49 youssef
  plane_assign_ticket() {
    local key="$1" agent="$2"
    local seq_num="${key##*-}"
    local user_id="${PLANE_AGENT_USER_ID[$agent]:-}"
    [[ -z "$user_id" ]] && { log_info "No Plane user ID for agent: $agent"; return 0; }

    python3 - "$seq_num" "$user_id" << 'PYEOF'
import json, os, sys, requests
seq = int(sys.argv[1])
user_id = sys.argv[2]
base = os.environ.get('PLANE_BASE_URL','').rstrip('/')
ws = os.environ.get('PLANE_WORKSPACE_SLUG','')
pid = os.environ.get('PLANE_PROJECT_ID','')
key = os.environ.get('PLANE_API_KEY','')
h = {'X-API-Key': key, 'Content-Type': 'application/json'}

r = requests.get(f'{base}/api/v1/workspaces/{ws}/projects/{pid}/issues/?per_page=200', headers=h, timeout=15)
issues = r.json().get('results', [])
issue = next((x for x in issues if x.get('sequence_id') == seq), None)
if not issue: sys.exit(0)

requests.patch(f'{base}/api/v1/workspaces/{ws}/projects/{pid}/issues/{issue["id"]}/',
    headers=h, json={'assignees': [user_id]}, timeout=15)
PYEOF
  }

  # ─── Plane Cycle Management ──────────────────────────────────────────────────

  # Create a new Plane cycle (sprint)
  # Usage: plane_create_cycle "Sprint 2" "2026-04-04" "2026-04-11"
  # Returns: cycle UUID
  plane_create_cycle() {
    local name="$1" start_date="$2" end_date="$3"
    python3 - "$name" "$start_date" "$end_date" << 'PYEOF'
import json, os, sys, requests
name, start_date, end_date = sys.argv[1], sys.argv[2], sys.argv[3]
base = os.environ.get('PLANE_BASE_URL','').rstrip('/')
ws = os.environ.get('PLANE_WORKSPACE_SLUG','')
pid = os.environ.get('PLANE_PROJECT_ID','')
key = os.environ.get('PLANE_API_KEY','')
h = {'X-API-Key': key, 'Content-Type': 'application/json'}
r = requests.post(f'{base}/api/v1/workspaces/{ws}/projects/{pid}/cycles/',
    headers=h, json={'name': name, 'start_date': start_date, 'end_date': end_date}, timeout=15)
if r.status_code in (200, 201):
    print(r.json().get('id', ''))
else:
    print(f'plane_create_cycle error: {r.status_code} {r.text[:200]}', file=sys.stderr)
PYEOF
  }

  # Add issues to a Plane cycle (bulk)
  # Usage: plane_add_issues_to_cycle <cycle_id> CDO-3 CDO-4 CDO-5
  plane_add_issues_to_cycle() {
    local cycle_id="$1"; shift
    local keys=("$@")
    # Pass keys as space-separated arg
    python3 - "$cycle_id" "${keys[*]}" << 'PYEOF'
import json, os, sys, requests
cycle_id = sys.argv[1]
keys = sys.argv[2].split()
base = os.environ.get('PLANE_BASE_URL','').rstrip('/')
ws = os.environ.get('PLANE_WORKSPACE_SLUG','')
pid = os.environ.get('PLANE_PROJECT_ID','')
key = os.environ.get('PLANE_API_KEY','')
h = {'X-API-Key': key, 'Content-Type': 'application/json'}
# Resolve ticket keys to issue UUIDs
r = requests.get(f'{base}/api/v1/workspaces/{ws}/projects/{pid}/issues/?per_page=200', headers=h, timeout=15)
issues = r.json().get('results', [])
seq_to_uuid = {i.get('sequence_id'): i['id'] for i in issues}
uuids = []
for k in keys:
    try:
        seq = int(k.split('-')[-1])
        if seq in seq_to_uuid:
            uuids.append(seq_to_uuid[seq])
    except ValueError:
        pass
if uuids:
    r2 = requests.post(f'{base}/api/v1/workspaces/{ws}/projects/{pid}/cycles/{cycle_id}/cycle-issues/',
        headers=h, json={'issues': uuids}, timeout=15)
    if r2.status_code not in (200, 201):
        print(f'plane_add_issues_to_cycle error: {r2.status_code}', file=sys.stderr)
    else:
        print(f'Added {len(uuids)} issues to cycle', file=sys.stderr)
PYEOF
  }

  # Get issues in a Plane cycle
  # Usage: plane_get_cycle_issues <cycle_id>
  # Output: CDO-3|Extract React components...  (one per line)
  plane_get_cycle_issues() {
    local cycle_id="$1"
    [[ -z "$cycle_id" ]] && return 0
    python3 - "$cycle_id" << 'PYEOF'
import json, os, sys, requests
cycle_id = sys.argv[1]
project_key = os.environ.get('JIRA_PROJECT', os.environ.get('PROJECT_KEY', 'CDO'))
base = os.environ.get('PLANE_BASE_URL','').rstrip('/')
ws = os.environ.get('PLANE_WORKSPACE_SLUG','')
pid = os.environ.get('PLANE_PROJECT_ID','')
key = os.environ.get('PLANE_API_KEY','')
h = {'X-API-Key': key, 'Content-Type': 'application/json'}
try:
    # Get cycle issues (returns cycle-issue join objects with 'issue' UUID)
    cr = requests.get(f'{base}/api/v1/workspaces/{ws}/projects/{pid}/cycles/{cycle_id}/cycle-issues/?per_page=200',
        headers=h, timeout=15)
    cycle_issues = cr.json().get('results', cr.json()) if isinstance(cr.json(), dict) else cr.json()
    issue_uuids = {ci.get('issue') or ci.get('id') for ci in cycle_issues}
    # Get all project issues to resolve UUIDs to seq+name
    ir = requests.get(f'{base}/api/v1/workspaces/{ws}/projects/{pid}/issues/?per_page=200', headers=h, timeout=15)
    issues = ir.json().get('results', [])
    for issue in issues:
        if issue['id'] in issue_uuids:
            seq = issue.get('sequence_id', 0)
            name = issue.get('name', '')
            print(f'{project_key}-{seq}|{name}')
except Exception as e:
    print(f'plane_get_cycle_issues error: {e}', file=sys.stderr)
PYEOF
  }

  # Get cycle issue stats (done/in_progress/todo/total)
  # Usage: plane_get_cycle_stats <cycle_id>
  # Output: JSON {"done": N, "in_progress": N, "todo": N, "total": N}
  plane_get_cycle_stats() {
    local cycle_id="$1"
    [[ -z "$cycle_id" ]] && echo '{"done":0,"in_progress":0,"todo":0,"total":0}' && return 0
    python3 - "$cycle_id" << 'PYEOF'
import json, os, sys, requests
cycle_id = sys.argv[1]
base = os.environ.get('PLANE_BASE_URL','').rstrip('/')
ws = os.environ.get('PLANE_WORKSPACE_SLUG','')
pid = os.environ.get('PLANE_PROJECT_ID','')
key = os.environ.get('PLANE_API_KEY','')
h = {'X-API-Key': key, 'Content-Type': 'application/json'}
try:
    sr = requests.get(f'{base}/api/v1/workspaces/{ws}/projects/{pid}/states/', headers=h, timeout=15)
    states = sr.json().get('results', sr.json()) if isinstance(sr.json(), dict) else sr.json()
    state_group = {s['id']: s.get('group', '') for s in states}
    cr = requests.get(f'{base}/api/v1/workspaces/{ws}/projects/{pid}/cycles/{cycle_id}/cycle-issues/?per_page=200',
        headers=h, timeout=15)
    cycle_issues = cr.json().get('results', cr.json()) if isinstance(cr.json(), dict) else cr.json()
    issue_uuids = {ci.get('issue') or ci.get('id') for ci in cycle_issues}
    ir = requests.get(f'{base}/api/v1/workspaces/{ws}/projects/{pid}/issues/?per_page=200', headers=h, timeout=15)
    issues = ir.json().get('results', [])
    done = in_progress = todo = 0
    for issue in issues:
        if issue['id'] not in issue_uuids:
            continue
        grp = state_group.get(issue.get('state', ''), '')
        if grp == 'completed':
            done += 1
        elif grp == 'started':
            in_progress += 1
        elif grp != 'cancelled':
            todo += 1
    print(json.dumps({'done': done, 'in_progress': in_progress, 'todo': todo, 'total': done + in_progress + todo}))
except Exception as e:
    print(json.dumps({'done': 0, 'in_progress': 0, 'todo': 0, 'total': 0}))
    print(f'plane_get_cycle_stats error: {e}', file=sys.stderr)
PYEOF
  }

  # Remove an issue from a Plane cycle
  # Usage: plane_remove_issue_from_cycle <cycle_id> CDO-3
  plane_remove_issue_from_cycle() {
    local cycle_id="$1" ticket_key="$2"
    local seq_num="${ticket_key##*-}"
    python3 - "$cycle_id" "$seq_num" << 'PYEOF'
import os, sys, requests
cycle_id, seq = sys.argv[1], int(sys.argv[2])
base = os.environ.get('PLANE_BASE_URL','').rstrip('/')
ws = os.environ.get('PLANE_WORKSPACE_SLUG','')
pid = os.environ.get('PLANE_PROJECT_ID','')
key = os.environ.get('PLANE_API_KEY','')
h = {'X-API-Key': key, 'Content-Type': 'application/json'}
r = requests.get(f'{base}/api/v1/workspaces/{ws}/projects/{pid}/issues/?per_page=200', headers=h, timeout=15)
issues = r.json().get('results', [])
issue = next((x for x in issues if x.get('sequence_id') == seq), None)
if issue:
    requests.delete(f'{base}/api/v1/workspaces/{ws}/projects/{pid}/cycles/{cycle_id}/cycle-issues/{issue["id"]}/',
        headers=h, timeout=15)
PYEOF
  }

  # Get the UUID of the currently active Plane cycle (date-based fallback)
  # Usage: plane_get_current_cycle_id
  # Prints cycle UUID to stdout; empty if none found
  plane_get_current_cycle_id() {
    python3 - << 'PYEOF' 2>/dev/null
import os, sys, requests
base = os.environ.get('PLANE_BASE_URL', '').rstrip('/')
ws   = os.environ.get('PLANE_WORKSPACE_SLUG', '')
pid  = os.environ.get('PLANE_PROJECT_ID', '')
key  = os.environ.get('PLANE_API_KEY', '')
h    = {'X-API-Key': key, 'Content-Type': 'application/json'}
try:
    r = requests.get(f'{base}/api/v1/workspaces/{ws}/projects/{pid}/cycles/',
                     headers=h, timeout=15)
    data = r.json()
    cycles = data.get('results', data if isinstance(data, list) else [])
    for c in cycles:
        if c.get('status', '').lower() in ('current', 'started', 'active'):
            print(c['id']); sys.exit(0)
    # Fallback: most recently started cycle by start_date
    started = [c for c in cycles if c.get('start_date')]
    if started:
        started.sort(key=lambda x: x['start_date'], reverse=True)
        print(started[0]['id'])
except Exception as e:
    print(f'plane_get_current_cycle_id error: {e}', file=sys.stderr)
PYEOF
  }

  # ─── End Plane Cycle Management ────────────────────────────────────────────

  # Get tickets assigned to a specific agent (sprint-active, not done, not blocked)
  # Usage: plane_get_assigned_tickets youssef 3
  plane_get_assigned_tickets() {
    local agent="$1" max="${2:-3}"
    local user_id="${PLANE_AGENT_USER_ID[$agent]:-}"
    [[ -z "$user_id" ]] && return 0

    python3 - "$user_id" "$max" "$agent" << 'PYEOF'
import json, os, sys, requests
user_id = sys.argv[1]
max_results = int(sys.argv[2])
agent_name = sys.argv[3] if len(sys.argv) > 3 else ''
project_key = os.environ.get('JIRA_PROJECT', 'BISB')
base = os.environ.get('PLANE_BASE_URL','').rstrip('/')
ws = os.environ.get('PLANE_WORKSPACE_SLUG','')
pid = os.environ.get('PLANE_PROJECT_ID','')
key = os.environ.get('PLANE_API_KEY','')
h = {'X-API-Key': key, 'Content-Type': 'application/json'}

# Get states for group and name lookup
states_r = requests.get(f'{base}/api/v1/workspaces/{ws}/projects/{pid}/states/', headers=h, timeout=15)
state_list = states_r.json()
if isinstance(state_list, dict): state_list = state_list.get('results', [])
state_group = {s['id']: s.get('group','') for s in state_list}
state_name  = {s['id']: s.get('name','') for s in state_list}

# Agent-specific allowed states (prevent cross-role ticket pollution)
# e.g. Youssef must NOT pick up "In Review" tickets (Nadia's domain)
AGENT_ALLOWED_STATES = {
    'salma':   {'Backlog', 'In Progress', 'Todo'},
    'youssef': {'In Progress', 'Ready'},
    'nadia':   {'In Review'},
    'rami':    {'In Progress', 'QA'},
    'omar':    {'Done'},
    'layla':   {'In Progress', 'Ready'},
}
allowed_states = AGENT_ALLOWED_STATES.get(agent_name, None)  # None = no restriction

# Labels deprecated — all blocking/gate logic now uses state names.
# "Blocked" and "Needs Human" are first-class states in the Plane workflow.
SKIP_STATE_NAMES = {'Blocked', 'Needs Human'}

# Fetch issues assigned to this agent
r = requests.get(f'{base}/api/v1/workspaces/{ws}/projects/{pid}/issues/?per_page=200', headers=h, timeout=15)
issues = r.json().get('results', [])

count = 0
for issue in issues:
    if count >= max_results: break
    # Must be assigned to this agent
    assignees = issue.get('assignees', [])
    if user_id not in assignees: continue
    # Must not be in a completed or cancelled state group
    s_id = issue.get('state','')
    if state_group.get(s_id, '') in ('completed', 'cancelled'): continue
    # Skip Blocked / Needs Human states (replaces old label-based checks)
    if state_name.get(s_id,'') in SKIP_STATE_NAMES: continue
    # Agent-role state guard: skip tickets in states outside this agent's lane
    # Spec gate for Youssef is implicit: he only sees 'Ready' and 'In Progress' tickets.
    # Salma writes spec (In Progress), Rami approves by moving ticket to 'Ready'.
    if allowed_states and state_name.get(s_id,'') not in allowed_states: continue
    seq = issue.get('sequence_id', 0)
    print(f'{project_key}-{seq}')
    count += 1
PYEOF
  }

  # Returns the API key for the current agent (falls back to shared key)
  plane_agent_key() {
    local agent_base="${AGENT_NAME:-}"
    agent_base="${agent_base%%-${PROJECT_KEY}*}"
    local key="${PLANE_AGENT_KEY[$agent_base]:-}"
    echo "${key:-${PLANE_API_KEY}}"
  }

  plane_headers() {
    echo "-H \"X-API-Key: ${PLANE_API_KEY}\" -H \"Content-Type: application/json\""
  }

  plane_api() {
    local method="$1" path="$2" data="${3:-}"
    # Use per-agent key so actions are attributed to the correct agent in Plane
    PLANE_API_KEY="$(plane_agent_key)" python3 "${SCRIPT_DIR}/plane-api.py" "$method" "$path" ${data:+"$data"}
  }

  # Override jira_get_ticket → Plane issue fetch
  jira_get_ticket() {
    local key="$1"
    # Extract sequence number from key (e.g. BISB-54 → 54)
    local seq_num="${key##*-}"
    # Cache per-run to avoid rate limits (valid for 5 min within same agent run)
    local cache_file="/tmp/${PROJECT_PREFIX}-ticket-${key}.json"
    if [[ -f "$cache_file" ]] && (( $(date +%s) - $(date -r "$cache_file" +%s 2>/dev/null || echo 0) < 300 )); then
      cat "$cache_file"
      return 0
    fi
    # Use Python with requests to fetch issue + states + labels in one script
    # (Plane's list endpoint returns state/labels as UUIDs, not nested objects)
    python3 -c "
import json, sys, os, requests

def _map_state(group):
    return {'completed': 'done', 'started': 'indeterminate', 'unstarted': 'new'}.get(group, 'new')
def _map_priority(p):
    return {'urgent': 'Highest', 'high': 'High', 'medium': 'Medium', 'low': 'Low', 'none': 'Lowest'}.get(p, 'Medium')

seq = int(sys.argv[1]) if sys.argv[1].isdigit() else -1
key = sys.argv[2]
base = os.environ.get('PLANE_BASE_URL', '').rstrip('/')
ws = os.environ.get('PLANE_WORKSPACE_SLUG', '')
pid = os.environ.get('PLANE_PROJECT_ID', '')
h = {'X-API-Key': os.environ.get('PLANE_API_KEY', ''), 'Content-Type': 'application/json'}

# Fetch all issues
r = requests.get(f'{base}/api/v1/workspaces/{ws}/projects/{pid}/issues/?per_page=200', headers=h, timeout=30)
data = r.json()
results = data.get('results', []) if isinstance(data, dict) else (data if isinstance(data, list) else [])
issue = next((x for x in results if x.get('sequence_id') == seq), None)
if not issue:
    print('{}')
    sys.exit(0)

# Fetch states to resolve UUID → name/group
sr = requests.get(f'{base}/api/v1/workspaces/{ws}/projects/{pid}/states/', headers=h, timeout=15)
sd = sr.json()
states = sd if isinstance(sd, list) else sd.get('results', [])
state_map = {s['id']: s for s in states}

# Fetch labels to resolve UUID → name
lr = requests.get(f'{base}/api/v1/workspaces/{ws}/projects/{pid}/labels/', headers=h, timeout=15)
ld = lr.json()
labels_list = ld if isinstance(ld, list) else ld.get('results', [])
label_name_map = {l['id']: l['name'] for l in labels_list}

# Resolve state
state_obj = state_map.get(issue.get('state', ''), {})
state_name = state_obj.get('name', 'Unknown')
state_group = state_obj.get('group', '')

# Resolve labels — Plane API returns 'label_ids' as list of UUID strings
raw_label_ids = issue.get('label_ids', [])
label_names = [label_name_map.get(lid, lid) for lid in raw_label_ids]

import re as _re
def _strip_html(html):
    text = _re.sub(r'<[^>]+>', ' ', html or '')
    text = _re.sub(r'&amp;', '&', text)
    text = _re.sub(r'&lt;', '<', text)
    text = _re.sub(r'&gt;', '>', text)
    text = _re.sub(r'&nbsp;', ' ', text)
    return _re.sub(r'\s+', ' ', text).strip()

desc = issue.get('description_stripped', '') or ''
if not desc:
    desc = _strip_html(issue.get('description_html', '') or '')

out = {
    'key': key,
    'id': issue.get('id', ''),
    'fields': {
        'summary': issue.get('name', ''),
        'description': desc,
        'labels': label_names,
        'status': {
            'name': state_name,
            'statusCategory': {'key': _map_state(state_group)}
        },
        'priority': {'name': _map_priority(issue.get('priority', ''))},
        'issuetype': {'name': 'Task'},
        'comment': {'comments': []},
        'subtasks': []
    }
}
print(json.dumps(out))
" "$seq_num" "$key" 2>/dev/null | tee "$cache_file"
  }

  # Override jira_add_label → Plane label add
  jira_add_label() {
    local key="$1" label="$2"
    local seq_num="${key##*-}"

    # Get issue UUID by sequence_id (exact match, not search)
    local issue_data issue_id current_labels_json
    issue_data=$(plane_api GET "/api/v1/workspaces/${PLANE_WS}/projects/${PLANE_PID}/issues/?per_page=200" 2>/dev/null)
    issue_id=$(echo "$issue_data" | python3 -c "
import json,sys
d=json.load(sys.stdin)
r=d.get('results',[])
seq=$seq_num
i=next((x for x in r if x.get('sequence_id')==seq),None)
print(i['id'] if i else '')
" 2>/dev/null)
    [[ -z "$issue_id" ]] && return 1

    # Get current labels to preserve them
    current_labels_json=$(echo "$issue_data" | python3 -c "
import json,sys
d=json.load(sys.stdin)
r=d.get('results',[])
seq=$seq_num
i=next((x for x in r if x.get('sequence_id')==seq),None)
print(json.dumps(i.get('labels',[]) if i else []))
" 2>/dev/null)

    # Get or create label — search all labels and match exact name
    local label_id
    label_id=$(plane_api GET "/api/v1/workspaces/${PLANE_WS}/projects/${PLANE_PID}/labels/?per_page=100" 2>/dev/null \
      | python3 -c "
import json,sys
d=json.load(sys.stdin)
r=d.get('results',d if isinstance(d,list) else [])
match=next((x for x in r if x.get('name','')==sys.argv[1]),None)
print(match['id'] if match else '')
" "$label" 2>/dev/null)

    if [[ -z "$label_id" ]]; then
      # Create the label
      label_id=$(plane_api POST "/api/v1/workspaces/${PLANE_WS}/projects/${PLANE_PID}/labels/" \
        "{\"name\":\"${label}\"}" 2>/dev/null \
        | python3 -c "import json,sys; print(json.load(sys.stdin).get('id',''))" 2>/dev/null)
    fi

    [[ -z "$label_id" ]] && return 1

    # Add label to issue (preserving existing labels)
    local new_labels_json
    new_labels_json=$(python3 -c "
import json,sys
existing=json.loads(sys.argv[1])
new_id=sys.argv[2]
if new_id not in existing:
    existing.append(new_id)
print(json.dumps(existing))
" "$current_labels_json" "$label_id" 2>/dev/null)

    plane_api PATCH "/api/v1/workspaces/${PLANE_WS}/projects/${PLANE_PID}/issues/${issue_id}/" \
      "{\"labels\":${new_labels_json}}" >/dev/null 2>&1
  }

  # Override jira_remove_label → Plane label remove
  jira_remove_label() {
    local key="$1" label="$2"
    local seq_num="${key##*-}"

    # Get issue and all labels in a single pass
    local all_issues all_labels
    all_issues=$(plane_api GET "/api/v1/workspaces/${PLANE_WS}/projects/${PLANE_PID}/issues/?per_page=200" 2>/dev/null)
    all_labels=$(plane_api GET "/api/v1/workspaces/${PLANE_WS}/projects/${PLANE_PID}/labels/?per_page=100" 2>/dev/null)

    python3 -c "
import json, sys, os, requests
issues_data = json.loads(sys.argv[1])
labels_data = json.loads(sys.argv[2])
remove_name = sys.argv[3]
seq = int(sys.argv[4])

results = issues_data.get('results', [])
issue = next((x for x in results if x.get('sequence_id') == seq), None)
if not issue: sys.exit(0)

issue_id = issue['id']

# Build name→id map from all labels
label_list = labels_data.get('results', labels_data if isinstance(labels_data, list) else [])
name_to_id = {l.get('name', ''): l['id'] for l in label_list}
remove_id = name_to_id.get(remove_name, '')

# Current labels are UUIDs; filter out the one to remove
current_labels = [lid for lid in issue.get('labels', []) if lid != remove_id]

base = os.environ['PLANE_BASE_URL'].rstrip('/')
ws = os.environ['PLANE_WORKSPACE_SLUG']
pid = os.environ['PLANE_PROJECT_ID']
requests.patch(f'{base}/api/v1/workspaces/{ws}/projects/{pid}/issues/{issue_id}/',
    headers={'X-API-Key': os.environ['PLANE_API_KEY'], 'Content-Type': 'application/json'},
    json={'labels': current_labels}, timeout=15)
" "$all_issues" "$all_labels" "$label" "$seq_num" 2>/dev/null || true
  }

  # Override jira_add_comment → Plane comment (markdown, much simpler!)
  jira_add_comment() {
    local key="$1" message="$2"
    local seq_num="${key##*-}"
    local issue_id
    issue_id=$(plane_api GET "/api/v1/workspaces/${PLANE_WS}/projects/${PLANE_PID}/issues/?per_page=200" 2>/dev/null \
      | python3 -c "import json,sys; d=json.load(sys.stdin); r=d.get('results',[]); seq=int(sys.argv[1]); i=next((x for x in r if x.get('sequence_id')==seq),None); print(i['id'] if i else '')" "$seq_num" 2>/dev/null)
    [[ -z "$issue_id" ]] && return 0  # graceful no-op if not found

    local body
    body=$(python3 -c "
import json, sys
msg = sys.argv[1]
print(json.dumps({'comment_stripped': msg, 'comment_html': '<p>' + msg + '</p>'}))" "$message")

    plane_api POST "/api/v1/workspaces/${PLANE_WS}/projects/${PLANE_PID}/issues/${issue_id}/comments/" \
      "$body" >/dev/null 2>&1
  }

  # Override jira_search_keys → Plane issue search with label filtering
  jira_search_keys() {
    local jql="$1" max_results="${2:-10}"
    python3 -c "
import json, sys, os, re, requests

jql = sys.argv[1]
max_results = int(sys.argv[2])
base = os.environ.get('PLANE_BASE_URL', '').rstrip('/')
ws = os.environ.get('PLANE_WORKSPACE_SLUG', '')
pid = os.environ.get('PLANE_PROJECT_ID', '')
api_key = os.environ.get('PLANE_API_KEY', '')
project_key = os.environ.get('JIRA_PROJECT', 'BISB')

headers = {'X-API-Key': api_key, 'Content-Type': 'application/json'}

# Determine state filter from JQL
exclude_done = 'Done' in jql and '!=' in jql
only_done = \"statusCategory = 'Done'\" in jql or 'statusCategory=Done' in jql

# Fetch all labels once for lookup
labels_r = requests.get(f'{base}/api/v1/workspaces/{ws}/projects/{pid}/labels/', headers=headers, timeout=15)
label_map = {}  # name -> id
for l in (labels_r.json() if isinstance(labels_r.json(), list) else labels_r.json().get('results', [])):
    label_map[l.get('name', '')] = l.get('id', '')

# Fetch all states for group lookup (Plane state_group URL param doesn't support comma-separated)
states_r = requests.get(f'{base}/api/v1/workspaces/{ws}/projects/{pid}/states/', headers=headers, timeout=15)
states_data = states_r.json() if states_r.ok else {}
state_list = states_data.get('results', states_data if isinstance(states_data, list) else [])
# state_id -> group mapping
state_id_to_group = {s['id']: s.get('group','') for s in state_list}

# Parse required labels from JQL: labels = 'x' AND labels = 'y'
required_labels = re.findall(r\"labels\s*=\s*'([^']+)'\", jql)
# Parse excluded labels: labels NOT IN ('a','b') or labels != 'x'
excluded_labels = re.findall(r\"labels\s*NOT\s+IN\s*\(([^)]+)\)\", jql, re.IGNORECASE)
excluded_set = set()
for group in excluded_labels:
    excluded_set.update(re.findall(r\"'([^']+)'\", group))
excluded_set.update(re.findall(r\"labels\s*!=\s*'([^']+)'\", jql))

# Fetch all issues (Plane doesn't support label or multi-state-group filtering via URL params)
r = requests.get(f'{base}/api/v1/workspaces/{ws}/projects/{pid}/issues/', headers=headers,
                 params={'per_page': 200}, timeout=30)
data = r.json()
results = data.get('results', data if isinstance(data, list) else [])

# Get label names for each issue using label UUIDs
def get_issue_label_names(issue):
    label_detail = issue.get('label_detail', [])
    if label_detail:
        return {l.get('name', '') for l in label_detail}
    # Fallback: look up label IDs in label_map (reverse lookup)
    # Plane returns label_ids field (not 'labels')
    id_to_name = {v: k for k, v in label_map.items()}
    return {id_to_name.get(lid, '') for lid in issue.get('label_ids', issue.get('labels', []))}

filtered = []
for issue in results:
    # Filter by state group
    issue_state_group = state_id_to_group.get(issue.get('state', ''), '')
    if exclude_done and issue_state_group == 'completed':
        continue
    if only_done and issue_state_group != 'completed':
        continue
    issue_labels = get_issue_label_names(issue)
    # Check required labels
    if required_labels and not all(l in issue_labels for l in required_labels):
        continue
    # Check excluded labels
    if excluded_set and any(l in issue_labels for l in excluded_set):
        continue
    filtered.append(issue)

for issue in filtered[:max_results]:
    seq = issue.get('sequence_id', 0)
    print(f'{project_key}-{seq}')
" "$jql" "$max_results" 2>/dev/null
  }

  # Override jira_search_keys_with_summaries → Plane issue search with summaries
  jira_search_keys_with_summaries() {
    local jql="$1" max_results="${2:-10}"
    python3 -c "
import json, sys, os, re, requests

jql = sys.argv[1]
max_results = int(sys.argv[2])
base = os.environ.get('PLANE_BASE_URL', '').rstrip('/')
ws = os.environ.get('PLANE_WORKSPACE_SLUG', '')
pid = os.environ.get('PLANE_PROJECT_ID', '')
api_key = os.environ.get('PLANE_API_KEY', '')
project_key = os.environ.get('JIRA_PROJECT', 'BISB')

headers = {'X-API-Key': api_key, 'Content-Type': 'application/json'}

exclude_done = 'Done' in jql and '!=' in jql
only_done = \"statusCategory = 'Done'\" in jql or 'statusCategory=Done' in jql

states_r = requests.get(f'{base}/api/v1/workspaces/{ws}/projects/{pid}/states/', headers=headers, timeout=15)
states_data = states_r.json() if states_r.ok else {}
state_list = states_data.get('results', states_data if isinstance(states_data, list) else [])
state_id_to_group = {s['id']: s.get('group','') for s in state_list}

labels_r = requests.get(f'{base}/api/v1/workspaces/{ws}/projects/{pid}/labels/', headers=headers, timeout=15)
label_map = {}
for l in (labels_r.json() if isinstance(labels_r.json(), list) else labels_r.json().get('results', [])):
    label_map[l.get('name', '')] = l.get('id', '')

required_labels = re.findall(r\"labels\s*=\s*'([^']+)'\", jql)

r = requests.get(f'{base}/api/v1/workspaces/{ws}/projects/{pid}/issues/', headers=headers,
                 params={'per_page': 200}, timeout=30)
data = r.json()
results = data.get('results', data if isinstance(data, list) else [])

def get_issue_label_names(issue):
    label_detail = issue.get('label_detail', [])
    if label_detail:
        return {l.get('name', '') for l in label_detail}
    id_to_name = {v: k for k, v in label_map.items()}
    return {id_to_name.get(lid, '') for lid in issue.get('label_ids', issue.get('labels', []))}

filtered = []
for issue in results:
    issue_state_group = state_id_to_group.get(issue.get('state', ''), '')
    if exclude_done and issue_state_group == 'completed':
        continue
    if only_done and issue_state_group != 'completed':
        continue
    issue_labels = get_issue_label_names(issue)
    if required_labels and not all(l in issue_labels for l in required_labels):
        continue
    filtered.append(issue)

for issue in filtered[:max_results]:
    seq = issue.get('sequence_id', 0)
    name = issue.get('name', 'No summary')
    print(f'{project_key}-{seq}|{name}')
" "$jql" "$max_results" 2>/dev/null
  }

  # Override jira_create_ticket → Plane issue create
  jira_create_ticket() {
    local summary="$1" issue_type="${2:-Task}"
    local escaped
    escaped=$(python3 -c "import json,sys; print(json.dumps(sys.stdin.read().strip()))" <<< "$summary")

    plane_api POST "/api/v1/workspaces/${PLANE_WS}/projects/${PLANE_PID}/issues/" \
      "{\"name\":${escaped}}" 2>/dev/null \
      | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('identifier', f\"${PROJECT_KEY}-{d.get('sequence_id',0)}\"))" 2>/dev/null
  }

  # Override jira_transition → Plane state change
  jira_transition() {
    local key="$1" target_state="$2"

    # Map Jira-style transition names to Plane state names
    local plane_state
    case "${target_state,,}" in
      done|terminé|terminee|termine)         plane_state="Done" ;;
      cours|"in progress"|"en cours"|inprogress|in_progress) plane_state="In Progress" ;;
      review|"in review"|revue)              plane_state="In Review" ;;
      todo|"to do"|"a faire"|"à faire")      plane_state="Todo" ;;
      ready)                                 plane_state="Ready" ;;
      qa)                                    plane_state="QA" ;;
      merged)                                plane_state="Merged" ;;
      blocked)                               plane_state="Blocked" ;;
      *)                                     plane_state="In Progress" ;;
    esac

    plane_update_state "$key" "$plane_state" 2>/dev/null || true
    log_info "Transitioned ${key} to ${plane_state} (via Plane)"
  }

  # Override jira_add_rich_comment → Plane plain comment (no header, no avatar, no verdict badge)
  jira_add_rich_comment() {
    local key="$1" agent="${2:-}" verdict="${3:-}" message="${4:-}"
    [[ -n "$message" ]] && jira_add_comment "$key" "$message"
  }

  # Override jira_assign_to_me → Plane set assignee
  jira_assign_to_me() {
    local key="$1"
    plane_set_assignee "$key" "${AGENT_NAME:-}" 2>/dev/null || true
  }

  # Override jira_update_labels → no-op (Plane uses state-based routing, not labels)
  jira_update_labels() {
    return 0
  }

  # Override jira_set_spec → Plane markdown description (no ADF panels needed)
  jira_set_spec() {
    local key="$1" agent="$2" spec_text="$3"
    local agent_display="${AGENT_SLACK_USERNAME[$agent]:-$agent}"

    # Get issue UUID
    local issue_id
    issue_id=$(plane_api GET "/api/v1/workspaces/${PLANE_WS}/projects/${PLANE_PID}/issues/?search=${key}" 2>/dev/null \
      | python3 -c "import json,sys; d=json.load(sys.stdin); r=d.get('results',[d]); print(r[0]['id'] if r else '')" 2>/dev/null)
    [[ -z "$issue_id" ]] && return 1

    # Plane descriptions are markdown — just use the spec text directly
    local escaped_spec
    escaped_spec=$(python3 -c "import json,sys; print(json.dumps(sys.stdin.read().strip()))" <<< "$spec_text")

    plane_api PATCH "/api/v1/workspaces/${PLANE_WS}/projects/${PLANE_PID}/issues/${issue_id}/" \
      "{\"description_stripped\":${escaped_spec}}" >/dev/null 2>&1
    log_info "Updated description for ${key} with ${agent} spec (markdown)"
  }

  # Override jira_link → Plane issue URL
  jira_link() {
    local key="$1"
    echo "${PLANE_BASE_URL}/${PLANE_WS}/projects/${PLANE_PID}/issues/?search=${key}"
  }

  # Update ticket state by name (e.g. "Todo", "Ready", "In Progress", "In Review", "QA", "Done", "Merged")
  plane_update_state() {
    local ticket_key="$1"
    local state_name="$2"
    local seq_num="${ticket_key##*-}"

    local state_id
    case "$state_name" in
      "Backlog")     state_id="${STATE_BACKLOG:-0cdf8a6f-61d7-478f-b90d-123c3d40c59a}" ;;
      "Todo")        state_id="${STATE_TODO:-0cdf8a6f-61d7-478f-b90d-123c3d40c59a}" ;;
      "Ready")       state_id="${STATE_READY:-8b48ad73-013d-499c-9a17-32426d734102}" ;;
      "In Progress") state_id="${STATE_IN_PROGRESS:-8ee90e44-e99b-45ca-b366-bd35370bcc3f}" ;;
      "In Review")   state_id="${STATE_IN_REVIEW:-da24b884-7df3-4c95-8c4a-8ea1e30653f1}" ;;
      "QA")          state_id="${STATE_QA:-03afa4d7-a380-426c-8d14-edeb082fc1da}" ;;
      "Merged")      state_id="${STATE_MERGED:-1843e452-9ab3-4a4c-8d32-4f6b1c18eb4d}" ;;
      "Done")        state_id="${STATE_DONE:-62e32c32-150b-4e65-827e-0caccec15adf}" ;;
      *)             log_info "plane_update_state: unknown state '$state_name'"; return 1 ;;
    esac

    python3 - "$seq_num" "$state_id" << 'PYEOF'
import json, os, sys, requests
seq = int(sys.argv[1])
state_id = sys.argv[2]
base = os.environ.get('PLANE_BASE_URL', '').rstrip('/')
ws = os.environ.get('PLANE_WORKSPACE_SLUG', '')
pid = os.environ.get('PLANE_PROJECT_ID', '')
key = os.environ.get('PLANE_API_KEY', '')
h = {'X-API-Key': key, 'Content-Type': 'application/json'}
try:
    r = requests.get(f'{base}/api/v1/workspaces/{ws}/projects/{pid}/issues/?per_page=200', headers=h, timeout=15)
    issues = r.json().get('results', [])
    issue = next((x for x in issues if x.get('sequence_id') == seq), None)
    if not issue:
        sys.exit(0)
    requests.patch(f'{base}/api/v1/workspaces/{ws}/projects/{pid}/issues/{issue["id"]}/',
        headers=h, json={'state': state_id}, timeout=15)
except Exception as e:
    print(f'plane_update_state error: {e}', file=sys.stderr)
PYEOF
  }

  # Set or clear ticket assignee by agent name (pass "" to clear assignees)
  plane_set_assignee() {
    local ticket_key="$1"
    local agent="$2"
    local seq_num="${ticket_key##*-}"

    local user_id=""
    if [[ -n "$agent" ]]; then
      user_id="${PLANE_AGENT_USER_ID[$agent]:-}"
      if [[ -z "$user_id" ]]; then
        log_info "plane_set_assignee: no user ID for agent '$agent'"
        return 0
      fi
    fi

    python3 - "$seq_num" "$user_id" << 'PYEOF'
import json, os, sys, requests
seq = int(sys.argv[1])
user_id = sys.argv[2]
base = os.environ.get('PLANE_BASE_URL', '').rstrip('/')
ws = os.environ.get('PLANE_WORKSPACE_SLUG', '')
pid = os.environ.get('PLANE_PROJECT_ID', '')
key = os.environ.get('PLANE_API_KEY', '')
h = {'X-API-Key': key, 'Content-Type': 'application/json'}
try:
    r = requests.get(f'{base}/api/v1/workspaces/{ws}/projects/{pid}/issues/?per_page=200', headers=h, timeout=15)
    issues = r.json().get('results', [])
    issue = next((x for x in issues if x.get('sequence_id') == seq), None)
    if not issue:
        sys.exit(0)
    assignees = [user_id] if user_id else []
    requests.patch(f'{base}/api/v1/workspaces/{ws}/projects/{pid}/issues/{issue["id"]}/',
        headers=h, json={'assignees': assignees}, timeout=15)
except Exception as e:
    print(f'plane_set_assignee error: {e}', file=sys.stderr)
PYEOF
  }

  # Override jira_set_state → route to plane_update_state
  jira_set_state() {
    local key="$1" state_name="$2"
    # Normalize common state names
    case "${state_name,,}" in
      needs-human|needs_human|"needs human") state_name="Needs Human" ;;
      blocked) state_name="Blocked" ;;
      done|terminé) state_name="Done" ;;
    esac
    plane_update_state "$key" "$state_name"
  }

  # Get unassigned tickets in Todo state (for Salma to pick up as new work)
  plane_get_unassigned_todo() {
    local project_key="${JIRA_PROJECT:-BISB}"
    local todo_state_id="${STATE_TODO:-0cdf8a6f-61d7-478f-b90d-123c3d40c59a}"
    local backlog_state_id="${STATE_BACKLOG:-}"
    local blocked_label="blocked"
    local needs_human_label="needs-human"

    python3 - "$project_key" "$todo_state_id" "$backlog_state_id" "$blocked_label" "$needs_human_label" << 'PYEOF'
import json, os, sys, requests
project_key = sys.argv[1]
todo_state_id = sys.argv[2]
backlog_state_id = sys.argv[3]
# Rebuild remaining argv offsets
blocked_label = sys.argv[4]
needs_human_label = sys.argv[5]
# Accept both Todo and Backlog states
valid_states = {todo_state_id}
if backlog_state_id:
    valid_states.add(backlog_state_id)
base = os.environ.get('PLANE_BASE_URL', '').rstrip('/')
ws = os.environ.get('PLANE_WORKSPACE_SLUG', '')
pid = os.environ.get('PLANE_PROJECT_ID', '')
key = os.environ.get('PLANE_API_KEY', '')
h = {'X-API-Key': key, 'Content-Type': 'application/json'}
try:
    lr = requests.get(f'{base}/api/v1/workspaces/{ws}/projects/{pid}/labels/?per_page=100', headers=h, timeout=15)
    label_list = lr.json()
    if isinstance(label_list, dict): label_list = label_list.get('results', [])
    name_to_id = {l.get('name', ''): l['id'] for l in label_list}
    blocked_id = name_to_id.get(blocked_label, '')
    needs_human_id = name_to_id.get(needs_human_label, name_to_id.get('needs-human-review', ''))

    r = requests.get(f'{base}/api/v1/workspaces/{ws}/projects/{pid}/issues/?per_page=200', headers=h, timeout=15)
    issues = r.json().get('results', [])
    for issue in issues:
        if issue.get('state') not in valid_states:
            continue
        assignees = issue.get('assignees', [])
        if assignees:
            continue
        label_ids = issue.get('label_ids', [])  # Plane API returns UUID list in 'label_ids'
        if blocked_id and blocked_id in label_ids:
            continue
        if needs_human_id and needs_human_id in label_ids:
            continue
        seq = issue.get('sequence_id', 0)
        print(f'{project_key}-{seq}')
except Exception as e:
    print(f'plane_get_unassigned_todo error: {e}', file=sys.stderr)
PYEOF
  }

  # Get unassigned tickets in a specific state (for state-based dispatch)
  # Usage: plane_get_unassigned_by_state "Ready" 3
  plane_get_unassigned_by_state() {
    local state_name="$1"
    local max="${2:-3}"
    local project_key="${JIRA_PROJECT:-BISB}"
    # Map state name to UUID (same hardcoded list as plane_update_state)
    local state_id
    case "$state_name" in
      "Backlog")     state_id="${STATE_BACKLOG:-0cdf8a6f-61d7-478f-b90d-123c3d40c59a}" ;;
      "Todo")        state_id="${STATE_TODO:-0cdf8a6f-61d7-478f-b90d-123c3d40c59a}" ;;
      "In Progress") state_id="${STATE_IN_PROGRESS:-8ee90e44-e99b-45ca-b366-bd35370bcc3f}" ;;
      "In Review")   state_id="${STATE_IN_REVIEW:-da24b884-7df3-4c95-8c4a-8ea1e30653f1}" ;;
      "QA")          state_id="${STATE_QA:-03afa4d7-a380-426c-8d14-edeb082fc1da}" ;;
      "Ready")       state_id="${STATE_READY:-8b48ad73-013d-499c-9a17-32426d734102}" ;;
      "Merged")      state_id="${STATE_MERGED:-1843e452-9ab3-4a4c-8d32-4f6b1c18eb4d}" ;;
      "Done")        state_id="${STATE_DONE:-62e32c32-150b-4e65-827e-0caccec15adf}" ;;
      *)             log_info "plane_get_unassigned_by_state: unknown state '$state_name'"; return 1 ;;
    esac

    python3 - "$project_key" "$state_id" "$max" << 'PYEOF'
import json, os, sys, requests
project_key = sys.argv[1]
state_id = sys.argv[2]
max_results = int(sys.argv[3])
base = os.environ.get('PLANE_BASE_URL', '').rstrip('/')
ws = os.environ.get('PLANE_WORKSPACE_SLUG', '')
pid = os.environ.get('PLANE_PROJECT_ID', '')
key = os.environ.get('PLANE_API_KEY', '')
h = {'X-API-Key': key, 'Content-Type': 'application/json'}
try:
    lr = requests.get(f'{base}/api/v1/workspaces/{ws}/projects/{pid}/labels/?per_page=100', headers=h, timeout=15)
    label_list = lr.json()
    if isinstance(label_list, dict): label_list = label_list.get('results', [])
    name_to_id = {l.get('name', ''): l['id'] for l in label_list}
    blocked_id = name_to_id.get('blocked', '')
    needs_human_id = name_to_id.get('needs-human', name_to_id.get('needs-human-review', ''))

    r = requests.get(f'{base}/api/v1/workspaces/{ws}/projects/{pid}/issues/?per_page=200', headers=h, timeout=15)
    issues = r.json().get('results', [])
    count = 0
    for issue in issues:
        if count >= max_results: break
        if issue.get('state') != state_id: continue
        if issue.get('assignees', []): continue  # Skip assigned tickets
        label_ids = issue.get('label_ids', [])
        if blocked_id and blocked_id in label_ids: continue
        if needs_human_id and needs_human_id in label_ids: continue
        seq = issue.get('sequence_id', 0)
        print(f'{project_key}-{seq}')
        count += 1
except Exception as e:
    print(f'plane_get_unassigned_by_state error: {e}', file=sys.stderr)
PYEOF
  }

  # Override jira_update_labels → Plane state + assignee update
  # Maps agent routing labels to Plane states and assignees.
  # The from_agent (remove_label) determines Rami's routing:
  #   from agent:salma → spec review (In Progress + assign rami)
  #   from anything else → QA review (QA + assign rami)
  # Also syncs labels for backward compatibility and visibility.
  jira_update_labels() {
    local key="$1" remove_label="$2" add_label="$3"
    # Extract agent name from label format "agent:youssef" → "youssef"
    local to_agent="${add_label#agent:}"
    local from_agent="${remove_label#agent:}"

    # Map agent transitions to Plane state + assignee changes
    if [[ "$to_agent" != "$add_label" ]]; then
      # It's an agent routing label — update state and assignee
      case "$to_agent" in
        youssef)         plane_update_state "$key" "Ready" 2>/dev/null || true
                         plane_set_assignee "$key" "youssef" 2>/dev/null || true ;;
        nadia)           plane_update_state "$key" "In Review" 2>/dev/null || true
                         plane_set_assignee "$key" "nadia" 2>/dev/null || true ;;
        rami)
          # Distinguish spec review (from Salma) vs QA review (from Nadia or anyone else)
          if [[ "$from_agent" == "salma" ]]; then
            plane_update_state "$key" "In Progress" 2>/dev/null || true
            plane_set_assignee "$key" "rami" 2>/dev/null || true
          else
            plane_update_state "$key" "QA" 2>/dev/null || true
            plane_set_assignee "$key" "rami" 2>/dev/null || true
          fi ;;
        omar)            plane_update_state "$key" "Done" 2>/dev/null || true
                         plane_set_assignee "$key" "omar" 2>/dev/null || true ;;
        salma)           plane_update_state "$key" "In Progress" 2>/dev/null || true
                         plane_set_assignee "$key" "salma" 2>/dev/null || true ;;
        layla)           plane_update_state "$key" "In Progress" 2>/dev/null || true
                         plane_set_assignee "$key" "layla" 2>/dev/null || true ;;
        ready-for-merge) plane_update_state "$key" "Done" 2>/dev/null || true
                         plane_set_assignee "$key" "omar" 2>/dev/null || true ;;
        *)               log_info "jira_update_labels: unknown to_agent '$to_agent', keeping state as-is" ;;
      esac
    fi

    # Keep labels synchronized for backward compatibility and visibility
    jira_remove_label "$key" "$remove_label" 2>/dev/null || true
    jira_add_label "$key" "$add_label" 2>/dev/null || true
  }

  log_info "Tracker backend: Plane (${PLANE_BASE_URL})"

else
  # Jira backend — all jira_* functions are already defined in agent-common.sh
  log_info "Tracker backend: Jira"
fi

# ─── Chat Backend Abstraction (Slack/Mattermost) ──────────────────────────
CHAT_BACKEND="${CHAT_BACKEND:-slack}"

if [[ "$CHAT_BACKEND" == "mattermost" ]]; then
  MM_URL="${MATTERMOST_URL:?Missing MATTERMOST_URL}"
  MM_TOKEN="${MATTERMOST_BOT_TOKEN:?Missing MATTERMOST_BOT_TOKEN}"

  # Per-agent bot tokens + Mattermost user IDs (for @mentions)
  declare -A MM_AGENT_TOKEN=(
    [salma]="${MM_TOKEN_SALMA:-}"
    [youssef]="${MM_TOKEN_YOUSSEF:-}"
    [nadia]="${MM_TOKEN_NADIA:-}"
    [omar]="${MM_TOKEN_OMAR:-}"
    [layla]="${MM_TOKEN_LAYLA:-}"
    [rami]="${MM_TOKEN_RAMI:-}"
    [dispatcher]="${MM_TOKEN_OMAR:-}"
  )

  # Mattermost user IDs for @mention support
  declare -A MM_AGENT_USER_ID=(
    [salma]="kdpqac4b67rjpxa4eo95w96qry"
    [youssef]="zjo43ghdsf88mdfhd6rroc54ey"
    [nadia]="1mfmqc7qpt8qpgyr1owa8dmhiy"
    [rami]="adkx6ufbify95g1dm88xjj8eta"
    [omar]="kpo1wnz59tgqt8rdt6htk736na"
    [layla]="4dcs8qt6ut8adkubjb4kbbiqbr"
  )

  # Map channel names to Mattermost channel IDs
  MM_CHANNEL_PIPELINE="${MM_CHANNEL_PIPELINE:-}"
  MM_CHANNEL_STANDUP="${MM_CHANNEL_STANDUP:-}"
  MM_CHANNEL_SPRINT="${MM_CHANNEL_SPRINT:-}"
  MM_CHANNEL_ALERTS="${MM_CHANNEL_ALERTS:-}"

  mm_get_channel_id() {
    local channel_type="${1:-pipeline}"
    case "$channel_type" in
      pipeline) echo "$MM_CHANNEL_PIPELINE" ;;
      standup)  echo "$MM_CHANNEL_STANDUP" ;;
      sprint)   echo "$MM_CHANNEL_SPRINT" ;;
      alerts)   echo "$MM_CHANNEL_ALERTS" ;;
      *)        echo "$MM_CHANNEL_PIPELINE" ;;
    esac
  }

  # ── @mention helper ────────────────────────────────────────────────────
  # Usage: mm_mention youssef  →  @youssef-ai (resolves to display-friendly mention)
  mm_mention() {
    local agent="${1:-}"
    local uid="${MM_AGENT_USER_ID[$agent]:-}"
    if [[ -n "$uid" ]]; then
      # Mattermost @username mention (username without the -ai is how they appear)
      echo "@${agent}-ai"
    else
      echo "@${agent}"
    fi
  }

  # ── Rich ticket link: "BISB-64 · Auction Confetti on winner" ──────────
  # Fetches ticket title from Plane; caches in /tmp/${PROJECT_PREFIX}-ticket-cache/
  _MM_TICKET_CACHE_DIR="/tmp/${PROJECT_PREFIX}-ticket-cache"
  mkdir -p "$_MM_TICKET_CACHE_DIR" 2>/dev/null || true

  mm_ticket_link() {
    local key="${1:-}"
    [[ -z "$key" ]] && echo "$key" && return 0

    # Check cache first (5 min TTL)
    local cache_file="${_MM_TICKET_CACHE_DIR}/${key}.title"
    local title=""
    if [[ -f "$cache_file" ]]; then
      local age=$(( $(date +%s) - $(stat -c %Y "$cache_file" 2>/dev/null || echo 0) ))
      if [[ $age -lt 300 ]]; then
        title=$(cat "$cache_file" 2>/dev/null || echo "")
      fi
    fi

    # Fetch from Plane if not cached
    if [[ -z "$title" ]] && [[ -n "${PLANE_BASE_URL:-}" ]]; then
      local seq_num="${key##*-}"
      title=$(python3 - "$seq_num" << 'PYPEOF'
import os, sys, requests
seq = sys.argv[1]
base = os.environ.get("PLANE_BASE_URL","")
key_api = os.environ.get("PLANE_API_KEY","")
ws = os.environ.get("PLANE_WORKSPACE_SLUG","")
proj = os.environ.get("PLANE_PROJECT_ID","")
try:
    r = requests.get(f"{base}/api/v1/workspaces/{ws}/projects/{proj}/issues/?sequence_id={seq}&per_page=1",
                     headers={"X-API-Key": key_api}, timeout=3)
    if r.ok:
        results = r.json().get("results", [])
        for issue in results:
            if str(issue.get("sequence_id")) == seq:
                name = issue.get("name","")
                # Truncate at 50 chars
                print(name[:50] + ("…" if len(name) > 50 else ""))
                break
except Exception:
    pass
PYPEOF
2>/dev/null || echo "")
      [[ -n "$title" ]] && echo "$title" > "$cache_file"
    fi

    # Build URL
    local url="${PLANE_BASE_URL:-http://49.13.225.201:8090}/bisb/projects/${PLANE_PROJECT_ID:-c52b76e9-6592-49d0-a856-fd01fec3e6cd}/issues/?search=${key}"

    if [[ -n "$title" ]]; then
      echo "[${key} · ${title}](${url})"
    else
      echo "[${key}](${url})"
    fi
  }

  # ── Thread management: one root post per ticket ────────────────────────────
  # Get the stored root post ID for a ticket (from /tmp/${PROJECT_PREFIX}-threads/)
  mm_get_thread_root() {
    local ticket_key="$1"
    local thread_file="/tmp/${PROJECT_PREFIX}-threads/${ticket_key}"
    [[ -f "$thread_file" ]] && cat "$thread_file" || echo ""
  }

  # Store the root post ID for a ticket
  mm_set_thread_root() {
    local ticket_key="$1"
    local post_id="$2"
    mkdir -p /tmp/${PROJECT_PREFIX}-threads
    echo "$post_id" > "/tmp/${PROJECT_PREFIX}-threads/${ticket_key}"
  }

  # Post a message, creating a thread root if none exists for this ticket
  # Usage: mm_thread_post "$message" "$channel_type" "$color"
  mm_thread_post() {
    local message="$1"
    local channel_type="${2:-pipeline}"
    local color="${3:-}"

    local root_id=""
    if [[ -n "${TICKET_KEY:-}" ]]; then
      root_id=$(mm_get_thread_root "$TICKET_KEY")
    fi

    if [[ -z "$root_id" ]]; then
      # No thread yet — post as root message
      local post_id
      post_id=$(mm_post "$message" "$channel_type" "$color" "" "return_id")
      if [[ -n "${TICKET_KEY:-}" && -n "$post_id" ]]; then
        mm_set_thread_root "$TICKET_KEY" "$post_id"
      fi
    else
      # Thread exists — reply to root
      mm_post "$message" "$channel_type" "$color" "$root_id"
    fi
  }

  # ── Post a message, optionally as a thread reply ───────────────────────
  # Usage: mm_post "$message" "$channel_type" "$color" "$root_post_id" ["return_id"]
  mm_post() {
    local message="$1"
    local channel_type="${2:-pipeline}"
    local color="${3:-}"
    local root_post_id="${4:-}"
    local return_id="${5:-}"

    local agent_base="${AGENT_NAME:-bisb-bot}"
    agent_base="${agent_base%%-${PROJECT_KEY}*}"

    local token="${MM_AGENT_TOKEN[$agent_base]:-$MM_TOKEN}"
    local channel_id
    channel_id=$(mm_get_channel_id "$channel_type")

    [[ -z "$channel_id" ]] && { log_info "Mattermost: no channel for $channel_type"; return 0; }

    local escaped_msg
    escaped_msg=$(python3 -c "import json,sys; print(json.dumps(sys.stdin.read().strip()))" <<< "$message")

    # Build valid JSON body with properly escaped keys (avoids bash quote-mangling)
    local json_body
    json_body="{\"channel_id\":\"${channel_id}\",\"message\":${escaped_msg}"
    [[ -n "$root_post_id" ]] && json_body="${json_body},\"root_id\":\"${root_post_id}\""
    json_body="${json_body}}"

    local response
    response=$(curl -s -X POST "${MM_URL}/api/v4/posts" \
      -H "Authorization: Bearer ${token}" \
      -H "Content-Type: application/json" \
      -d "$json_body" 2>/dev/null || echo "")

    # Optionally return post ID for threading
    if [[ "${return_id}" == "return_id" ]]; then
      echo "$response" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('id',''))" 2>/dev/null || true
    fi
  }

  # ── Add emoji reaction to a post ──────────────────────────────────────
  mm_react() {
    local post_id="$1"
    local emoji="${2:-thumbsup}"
    local agent_base="${AGENT_NAME:-bisb-bot}"
    agent_base="${agent_base%%-${PROJECT_KEY}*}"
    local token="${MM_AGENT_TOKEN[$agent_base]:-$MM_TOKEN}"
    local user_id="${MM_AGENT_USER_ID[$agent_base]:-}"
    [[ -z "$post_id" || -z "$user_id" ]] && return 0
    curl -s -X POST "${MM_URL}/api/v4/reactions" \
      -H "Authorization: Bearer ${token}" \
      -H "Content-Type: application/json" \
      -d "{\"user_id\":\"${user_id}\",\"post_id\":\"${post_id}\",\"emoji_name\":\"${emoji}\"}" \
      > /dev/null 2>&1 || true
  }

  # ── Triage roundtable: threaded discussion when ticket is blocked ──────
  # Called when a ticket exceeds max retries. Posts a thread with all stakeholders.
  mm_triage_roundtable() {
    local key="$1"
    local reason="$2"
    local retry_count="${3:-3}"
    local ticket_link
    ticket_link=$(mm_ticket_link "$key")

    # Post root message from Omar
    local root_msg="🚨 **Triage requis — ${ticket_link}**

Après **${retry_count} tentatives**, ce ticket est bloqué. J'ouvre une discussion d'équipe.

**Raison :** ${reason}

$(mm_mention salma) $(mm_mention youssef) $(mm_mention nadia) $(mm_mention rami) — votre input est demandé."

    local SAVED_AGENT="$AGENT_NAME"
    AGENT_NAME="omar"
    local root_post_id
    root_post_id=$(mm_post "$root_msg" "pipeline" "" "")

    if [[ -n "$root_post_id" ]]; then
      # Salma replies with PM perspective
      AGENT_NAME="salma"
      mm_post "📋 **Perspective PM** — Je vais revoir la spec et identifier ce qui bloque. $(mm_mention youssef), envoie-moi les détails des checks échoués." "pipeline" "" "$root_post_id"

      # Rami replies with architecture perspective
      AGENT_NAME="rami"
      mm_post "🏗️ **Perspective Architecture** — Je regarde le diff. Si le scope est trop large, je propose de splitter en 2 PRs." "pipeline" "" "$root_post_id"
    fi

    AGENT_NAME="$SAVED_AGENT"
  }

  # ── Override slack_notify ─────────────────────────────────────────────
  # Supports two calling conventions:
  #   3-arg: slack_notify "message" [channel] [color]  — agent from AGENT_NAME
  #   4-arg: slack_notify "agent" "message" [channel] [color]  — agent as first arg
  slack_notify() {
    local saved_agent="${AGENT_NAME:-}"
    local message channel_type color
    if [[ "$1" =~ ^(salma|youssef|nadia|rami|omar|layla|dispatcher)$ ]]; then
      # 4-arg form: agent message [channel] [color]
      AGENT_NAME="$1"
      message="$2"
      channel_type="${3:-pipeline}"
      color="${4:-}"
    else
      # 3-arg form: message [channel] [color]
      message="$1"
      channel_type="${2:-pipeline}"
      color="${3:-}"
    fi
    mm_thread_post "$message" "$channel_type" "$color" > /dev/null 2>&1 || true
    AGENT_NAME="${saved_agent}"
  }

  # ── Update bot display names (remove -ai suffix) ──────────────────────
  # Run once at startup if BISB_MM_NAMES_INITIALIZED is not set
  if [[ -z "${BISB_MM_NAMES_INITIALIZED:-}" ]]; then
    declare -A MM_DISPLAY_NAMES=(
      [salma]="Salma"
      [youssef]="Youssef"
      [nadia]="Nadia"
      [rami]="Rami"
      [omar]="Omar"
      [layla]="Layla"
    )
    declare -A MM_LAST_NAMES=(
      [salma]="Ben Amor"
      [youssef]="Trabelsi"
      [nadia]="Chaari"
      [rami]="Hammami"
      [omar]="Jebali"
      [layla]="Mansouri"
    )
    # Set server to display full names instead of usernames
    curl -s -X PUT "${MM_URL}/api/v4/config/patch" \
      -H "Authorization: Bearer ${MM_TOKEN}" \
      -H "Content-Type: application/json" \
      -d '{"TeamSettings":{"TeammateNameDisplay":"full_name"}}' > /dev/null 2>&1 || true
    for agent in salma youssef nadia rami omar layla; do
      tok="${MM_AGENT_TOKEN[$agent]:-}"
      [[ -z "$tok" ]] && continue
      curl -s -X PUT "${MM_URL}/api/v4/users/me/patch" \
        -H "Authorization: Bearer ${tok}" \
        -H "Content-Type: application/json" \
        -d "{\"first_name\":\"${MM_DISPLAY_NAMES[$agent]}\",\"last_name\":\"${MM_LAST_NAMES[$agent]}\",\"nickname\":\"${MM_DISPLAY_NAMES[$agent]} ${MM_LAST_NAMES[$agent]}\"}" \
        > /dev/null 2>&1 || true
    done
    export BISB_MM_NAMES_INITIALIZED=1
  fi

  log_info "Chat backend: Mattermost (${MM_URL})"
else
  log_info "Chat backend: Slack"
fi
