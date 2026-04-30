#!/usr/bin/env bats
# end_to_end.bats — end-to-end integration tests for the phased-dispatch pipeline.
#
# Covers the full plan → decompose → ack → dispatch-tasklist → merge flow.
# Uses tests/bin/claude mock — no real LLM calls.
#
# Hard cap: 12 test cases.

load 'helpers/build-kit-tree.bash'

HOST_REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
export HOST_REPO_ROOT

setup_file() {
    HOST_AGENT_REFS_SNAPSHOT_FILE="$(mktemp "${TMPDIR:-/tmp}/end-to-end-host-agent-refs.XXXXXX")"
    git -C "$HOST_REPO_ROOT" for-each-ref --format='%(refname)' refs/heads/agent > "$HOST_AGENT_REFS_SNAPSHOT_FILE"
    export HOST_AGENT_REFS_SNAPSHOT_FILE
}

setup() {
    KIT_TMPDIR="$(mktemp -d)"
    build_kit_tree "$KIT_TMPDIR"

    # Copy schemas into kit tree (validation scripts reference src/schemas/)
    local source_kit="${BATS_TEST_DIRNAME%/tests}"
    if [[ -d "$source_kit/src/schemas" ]]; then
        mkdir -p "$KIT_TREE/src"
        cp -r "$source_kit/src/schemas" "$KIT_TREE/src/"
    fi

    # Isolated state homes
    FIXTURE_ROOT="$KIT_TMPDIR/state"
    NPS_TASKLISTS_HOME="$FIXTURE_ROOT/task-lists"
    NPS_PLANS_HOME="$FIXTURE_ROOT/plans"
    export NPS_TASKLISTS_HOME NPS_PLANS_HOME

    run_spawner setup coder-01 coder

    # Minimal git repo for merge tests
    REPO="$KIT_TMPDIR/repo"
    git init "$REPO" -b main 2>/dev/null
    git -C "$REPO" config user.email "test@example.com"
    git -C "$REPO" config user.name "Test"
    touch "$REPO/file.txt"
    git -C "$REPO" add .
    git -C "$REPO" commit -m "initial" 2>/dev/null
}

teardown() {
    git -C "${REPO:-/dev/null}" worktree prune 2>/dev/null || true
    rm -rf "${KIT_TMPDIR:-}"
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

_run_e2e() {
    NPS_AGENTS_HOME="$KIT_AGENTS" \
    NPS_WORKTREES_HOME="$KIT_WORKTREES" \
    NPS_LOGS_HOME="$KIT_LOGS" \
    NPS_PLANS_HOME="$NPS_PLANS_HOME" \
    NPS_TASKLISTS_HOME="$NPS_TASKLISTS_HOME" \
    "$KIT_SCRIPTS/spawn-agent.sh" "$@"
}

run_dt() {
    (
        cd "$REPO" || exit 1
        NPS_AGENTS_HOME="$KIT_AGENTS" \
        NPS_WORKTREES_HOME="$KIT_WORKTREES" \
        NPS_LOGS_HOME="$KIT_LOGS" \
        NPS_PLANS_HOME="$NPS_PLANS_HOME" \
        NPS_TASKLISTS_HOME="$NPS_TASKLISTS_HOME" \
        "$KIT_SCRIPTS/spawn-agent.sh" dispatch-tasklist "$@"
    )
}

_run_merge() {
    NPS_AGENTS_HOME="$KIT_AGENTS" \
    NPS_WORKTREES_HOME="$KIT_WORKTREES" \
    NPS_LOGS_HOME="$KIT_LOGS" \
    NPS_TASKLISTS_HOME="$NPS_TASKLISTS_HOME" \
    "$KIT_SCRIPTS/spawn-agent.sh" merge "$@"
}

# Seed a plan.md in NPS_PLANS_HOME/{plan_id}/plan.md
_seed_plan() {
    local plan_id="$1"
    mkdir -p "$NPS_PLANS_HOME/$plan_id"
    cat > "$NPS_PLANS_HOME/$plan_id/plan.md" <<EOF
---
plan_id: $plan_id
title: E2E test plan
status: pending
created_at: 2026-01-01T00:00:00Z
---

E2E test plan body.
EOF
}

# Build decompose input JSON for a plan (reads plan.md from NPS_PLANS_HOME)
_decompose_input() {
    local plan_id="$1"
    python3 - "$plan_id" "$NPS_PLANS_HOME/$plan_id/plan.md" <<'PYEOF'
import json, sys
plan_id, plan_file = sys.argv[1], sys.argv[2]
print(json.dumps({
    "plan": open(plan_file).read(),
    "context": {"files": [], "knowledge": [], "branch": "main"},
    "prior_version": None, "prior_state": None, "pushback": None,
}))
PYEOF
}

_set_decomposer_cmd() {
    local decomposer_cmd="$1"
    python3 - "$KIT_TREE/config.json" "$decomposer_cmd" <<'PYEOF'
import json, sys
config_file, decomposer_cmd = sys.argv[1:]
d = json.load(open(config_file))
d["decomposer_cmd"] = decomposer_cmd
with open(config_file, "w") as f:
    json.dump(d, f, indent=2)
    f.write("\n")
PYEOF
}

# Assert all nodes in plan's state file have the expected status.
_assert_all_status() {
    local plan_id="$1" expected="$2"
    run python3 - "$NPS_TASKLISTS_HOME/$plan_id/task-list-state.json" "$expected" <<'PYEOF'
import json, sys
state = json.load(open(sys.argv[1]))
bad = [(n, v['status']) for n, v in state['node_states'].items()
       if v['status'] != sys.argv[2]]
if bad:
    for n, s in bad: print(f"  {n}: {s} (expected {sys.argv[2]})", file=sys.stderr)
    sys.exit(1)
print('ok')
PYEOF
    [ "$status" -eq 0 ]
}

# Assert escalation.jsonl contains an event with the given dispatcher_acted value.
_assert_escalation_acted() {
    local plan_id="$1" acted="$2"
    run python3 - "$NPS_TASKLISTS_HOME/$plan_id/escalation.jsonl" "$acted" <<'PYEOF'
import json, sys
log_path, target = sys.argv[1], sys.argv[2]
found = any(json.loads(l).get('dispatcher_acted') == target
            for l in open(log_path) if l.strip())
if not found:
    print(f"No event with dispatcher_acted={target!r}", file=sys.stderr)
    sys.exit(1)
print('ok')
PYEOF
    [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# 1. Decompose step: writes pending/v1.json with correct plan_id
# ---------------------------------------------------------------------------

@test "decompose: pending/v1.json written with matching plan_id" {
    _seed_plan "plan-e2e-001"
    run _run_e2e decompose <<< "$(_decompose_input plan-e2e-001)"
    [ "$status" -eq 0 ]
    [ -f "$NPS_TASKLISTS_HOME/plan-e2e-001/pending/v1.json" ]
    run python3 -c "
import json
d = json.load(open('$NPS_TASKLISTS_HOME/plan-e2e-001/pending/v1.json'))
assert d['plan_id'] == 'plan-e2e-001', d['plan_id']
print('ok')
"
    [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# 2. Ack step: pending/v1.json promoted to v1.json
# ---------------------------------------------------------------------------

@test "ack: pending/v1.json promoted, pending removed" {
    _seed_plan "plan-e2e-002"
    _run_e2e decompose <<< "$(_decompose_input plan-e2e-002)" > /dev/null
    run _run_e2e ack plan-e2e-002 1
    [ "$status" -eq 0 ]
    [ -f "$NPS_TASKLISTS_HOME/plan-e2e-002/v1.json" ]
    [ ! -f "$NPS_TASKLISTS_HOME/plan-e2e-002/pending/v1.json" ]
}

# ---------------------------------------------------------------------------
# 3. Ack --reject: pending stays, dispatch exits 2
# ---------------------------------------------------------------------------

@test "ack --reject: pending/v1.json stays, dispatch-tasklist exits 2" {
    _seed_plan "plan-e2e-003"
    _run_e2e decompose <<< "$(_decompose_input plan-e2e-003)" > /dev/null
    run _run_e2e ack --reject plan-e2e-003 1
    [ "$status" -eq 0 ]
    [ -f "$NPS_TASKLISTS_HOME/plan-e2e-003/pending/v1.json" ]
    [ ! -f "$NPS_TASKLISTS_HOME/plan-e2e-003/v1.json" ]

    run run_dt plan-e2e-003
    [ "$status" -eq 2 ]
}

# ---------------------------------------------------------------------------
# 4. Full happy path: decompose → ack → dispatch → all nodes green
# ---------------------------------------------------------------------------

@test "happy path: decompose → ack → dispatch → all nodes completed" {
    _seed_plan "plan-e2e-004"
    _run_e2e decompose <<< "$(_decompose_input plan-e2e-004)" > /dev/null
    _run_e2e ack plan-e2e-004 1 > /dev/null

    run run_dt plan-e2e-004
    [ "$status" -eq 0 ]

    _assert_all_status plan-e2e-004 completed
}

# ---------------------------------------------------------------------------
# 5. osi_acked escalation event written after successful dispatch
# ---------------------------------------------------------------------------

@test "happy path: escalation.jsonl has osi_acked event from ack step" {
    _seed_plan "plan-e2e-005"
    _run_e2e decompose <<< "$(_decompose_input plan-e2e-005)" > /dev/null
    _run_e2e ack plan-e2e-005 1 > /dev/null
    run_dt plan-e2e-005 > /dev/null

    _assert_escalation_acted plan-e2e-005 osi_acked
}

# ---------------------------------------------------------------------------
# 6. Merge blocked when state has non-terminal node
# ---------------------------------------------------------------------------

@test "merge blocked: cmd_merge exits 1 when node not yet completed" {
    local plan_id="plan-e2e-006"
    local task_id="task-e2e-20260101-000006"
    local branch="agent/coder-01/${task_id}"
    local worktree="$KIT_WORKTREES/${task_id}"

    git -C "$REPO" worktree add -b "$branch" "$worktree" 2>/dev/null

    mkdir -p "$KIT_AGENTS/coder-01/done"
    printf '{"task_id":"%s","agent_id":"coder-01","branch":"%s","worktree":"%s","original_scope":"%s","status":"success","target_branch":"main"}\n' \
        "$task_id" "$branch" "$worktree" "$REPO" \
        > "$KIT_AGENTS/coder-01/done/${task_id}.branch.json"

    # result.json with plan_id so merge-hold check is triggered
    cat > "$KIT_AGENTS/coder-01/done/${task_id}.result.json" <<EOF
{"_ncp":1,"type":"result","value":"done","probability":1.0,"alternatives":[],
 "payload":{"plan_id":"$plan_id","_nop":1,"id":"$task_id","status":"completed",
  "from":"urn:nps:agent:example.com:coder-01",
  "picked_up_at":"2026-01-01T00:00:00Z","completed_at":"2026-01-01T00:01:00Z"}}
EOF

    # State with one node still pending
    mkdir -p "$NPS_TASKLISTS_HOME/$plan_id"
    cat > "$NPS_TASKLISTS_HOME/$plan_id/task-list-state.json" <<EOF
{"schema_version":1,"plan_id":"$plan_id","active_version":1,
 "superseded_versions":[],"merge_hold":true,
 "node_states":{"node-a":{"status":"pending","task_id":null,
   "started_at":null,"completed_at":null,"result_path":null,"retries":0}},
 "updated_at":"2026-01-01T00:00:00Z"}
EOF

    run _run_merge "$task_id" --no-push
    [ "$status" -eq 1 ]
    echo "$output" | grep -qi "not fully green\|non-terminal\|merge-hold"
}

# ---------------------------------------------------------------------------
# 7. Pushback: dispatch exits non-zero, blocked state written
# ---------------------------------------------------------------------------

@test "pushback: dispatch exits non-zero, node status=blocked" {
    _seed_plan "plan-e2e-007"
    _run_e2e decompose <<< "$(_decompose_input plan-e2e-007)" > /dev/null
    _run_e2e ack plan-e2e-007 1 > /dev/null

    MOCK_CLAUDE_MODE=pushback run run_dt plan-e2e-007
    [ "$status" -ne 0 ]

    run python3 -c "
import json
s = json.load(open('$NPS_TASKLISTS_HOME/plan-e2e-007/task-list-state.json'))
blocked = [n for n, v in s['node_states'].items() if v['status'] == 'blocked']
assert blocked, 'expected a blocked node'
print('ok')
"
    [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# 8. Pushback: escalation event is decomposer_failed/pushback_unsupported
#    (trivial decomposer refuses re-emission; escalates to OSer)
# ---------------------------------------------------------------------------

@test "pushback: escalation.jsonl has decomposer_failed/pushback_unsupported event" {
    _seed_plan "plan-e2e-008"
    _run_e2e decompose <<< "$(_decompose_input plan-e2e-008)" > /dev/null
    _run_e2e ack plan-e2e-008 1 > /dev/null
    MOCK_CLAUDE_MODE=pushback run_dt plan-e2e-008 > /dev/null || true

    run python3 - "$NPS_TASKLISTS_HOME/plan-e2e-008/escalation.jsonl" <<'PYEOF'
import json, sys
events = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
pb_events = [e for e in events if e.get('dispatcher_acted') == 'decomposer_failed'
             and e.get('pushback_reason') == 'pushback_unsupported']
assert pb_events, f"no decomposer_failed/pushback_unsupported event in {events}"
print('ok')
PYEOF
    [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# 9. Pushback: trivial decomposer refusal means no pending/v2.json written
# ---------------------------------------------------------------------------

@test "pushback: no pending/v2.json when trivial decomposer refuses re-invocation" {
    _seed_plan "plan-e2e-009"
    _run_e2e decompose <<< "$(_decompose_input plan-e2e-009)" > /dev/null
    _run_e2e ack plan-e2e-009 1 > /dev/null
    MOCK_CLAUDE_MODE=pushback run_dt plan-e2e-009 > /dev/null || true

    [ ! -f "$NPS_TASKLISTS_HOME/plan-e2e-009/pending/v2.json" ]
}

# ---------------------------------------------------------------------------
# 10. Pushback: custom decomposer success preserves worker reason
# ---------------------------------------------------------------------------

@test "pushback success: escalation logs invoked_decomposer with worker reason" {
    _seed_plan "plan-e2e-010"
    _run_e2e decompose <<< "$(_decompose_input plan-e2e-010)" > /dev/null
    _run_e2e ack plan-e2e-010 1 > /dev/null
    _set_decomposer_cmd "$BATS_TEST_DIRNAME/fixtures/decomposer-pushback-success.py"

    MOCK_CLAUDE_MODE=pushback run_dt plan-e2e-010 > /dev/null || true

    run python3 - "$NPS_TASKLISTS_HOME/plan-e2e-010/escalation.jsonl" <<'PYEOF'
import json, sys
events = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
matches = [
    e for e in events
    if e.get("dispatcher_acted") == "invoked_decomposer"
    and e.get("pushback_reason") == "scope_insufficient"
    and e.get("prior_version") == 1
    and e.get("decomposer_output_version") == 2
]
assert matches, f"no positive pushback invoked_decomposer event in {events}"
print("ok")
PYEOF
    [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# 11. Pushback: custom decomposer writes pending/v2.json
# ---------------------------------------------------------------------------

@test "pushback success: pending/v2.json written with matching plan_id" {
    _seed_plan "plan-e2e-011"
    _run_e2e decompose <<< "$(_decompose_input plan-e2e-011)" > /dev/null
    _run_e2e ack plan-e2e-011 1 > /dev/null
    _set_decomposer_cmd "$BATS_TEST_DIRNAME/fixtures/decomposer-pushback-success.py"

    MOCK_CLAUDE_MODE=pushback run_dt plan-e2e-011 > /dev/null || true

    run python3 - "$NPS_TASKLISTS_HOME/plan-e2e-011/pending/v2.json" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["plan_id"] == "plan-e2e-011", d["plan_id"]
assert d["version_id"] == 2, d["version_id"]
assert d["prior_version"] == 1, d["prior_version"]
assert d["pushback_reason"] == "scope_insufficient", d["pushback_reason"]
print("ok")
PYEOF
    [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# 12. Host agent refs unchanged by dispatch-tasklist runs
# ---------------------------------------------------------------------------

@test "host agent refs unchanged by dispatch-tasklist runs" {
    local current_refs="$KIT_TMPDIR/host-agent-refs.after"
    git -C "$HOST_REPO_ROOT" for-each-ref --format='%(refname)' refs/heads/agent > "$current_refs"

    run diff -u "$HOST_AGENT_REFS_SNAPSHOT_FILE" "$current_refs"
    [ "$status" -eq 0 ]
}
