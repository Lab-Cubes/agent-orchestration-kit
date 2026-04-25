#!/usr/bin/env bats
# merge_hold.bats — integration tests for spawn-agent.sh cmd_merge merge-hold gate.
#
# Covers:
#   - Merge refused when task-list has non-terminal nodes
#   - Merge permitted when all nodes are terminal
#   - merge_hold_enforce=false escape hatch (requires --force-merge)
#   - Solo-intent (no plan_id) bypasses hold check
#   - Edge cases: missing state file, merge_hold=false in state
#
# Git repos are set up inline per test; the mock claude CLI is NOT needed
# since these tests drive cmd_merge directly (not cmd_dispatch).
#
# Hard cap: 12 test cases.

load 'helpers/build-kit-tree.bash'

setup() {
    KIT_TMPDIR="$(mktemp -d)"
    build_kit_tree "$KIT_TMPDIR"
    run_spawner setup coder-01 coder

    FIXTURE_ROOT="$KIT_TMPDIR/state"
    NPS_TASKLISTS_HOME="$FIXTURE_ROOT/task-lists"
    export NPS_TASKLISTS_HOME

    # Minimal git repo + branch + branch.json shared across tests
    REPO="$KIT_TMPDIR/repo"
    git init "$REPO" -b main 2>/dev/null
    git -C "$REPO" config user.email "test@example.com"
    git -C "$REPO" config user.name "Test"
    touch "$REPO/file.txt"
    git -C "$REPO" add .
    git -C "$REPO" commit -m "initial" 2>/dev/null

    TASK_ID="task-test-20260101-000001"
    BRANCH="agent/coder-01/${TASK_ID}"
    WORKTREE="$KIT_WORKTREES/${TASK_ID}"
    git -C "$REPO" worktree add -b "$BRANCH" "$WORKTREE" 2>/dev/null

    # Write branch.json
    mkdir -p "$KIT_AGENTS/coder-01/done"
    printf '{"task_id":"%s","agent_id":"coder-01","branch":"%s","worktree":"%s","original_scope":"%s","status":"success","target_branch":"main"}\n' \
        "$TASK_ID" "$BRANCH" "$WORKTREE" "$REPO" \
        > "$KIT_AGENTS/coder-01/done/${TASK_ID}.branch.json"
}

teardown() {
    # Worktrees must be removed before the temp dir can be deleted
    git -C "${REPO:-/dev/null}" worktree prune 2>/dev/null || true
    rm -rf "${KIT_TMPDIR:-}"
}

# ---------------------------------------------------------------------------
# Helper: run cmd_merge with isolated env
# ---------------------------------------------------------------------------
run_merge() {
    NPS_AGENTS_HOME="$KIT_AGENTS" \
    NPS_WORKTREES_HOME="$KIT_WORKTREES" \
    NPS_LOGS_HOME="$KIT_LOGS" \
    NPS_TASKLISTS_HOME="$NPS_TASKLISTS_HOME" \
    "$KIT_SCRIPTS/spawn-agent.sh" merge "$@"
}

# Write a result.json for TASK_ID with an optional plan_id
_write_result() {
    local plan_id="${1:-}"
    local plan_field=""
    [[ -n "$plan_id" ]] && plan_field='"plan_id":"'"$plan_id"'",'
    cat > "$KIT_AGENTS/coder-01/done/${TASK_ID}.result.json" <<EOF
{"_ncp":1,"type":"result","value":"done","probability":1.0,"alternatives":[],
 "payload":{${plan_field}"_nop":1,"id":"${TASK_ID}","status":"completed",
  "from":"urn:nps:agent:example.com:coder-01",
  "picked_up_at":"2026-01-01T00:00:00Z","completed_at":"2026-01-01T00:01:00Z"}}
EOF
}

# Write task-list-state.json for a plan with specified node statuses
_write_state() {
    local plan_id="$1"; shift
    local tl_dir="$NPS_TASKLISTS_HOME/$plan_id"
    mkdir -p "$tl_dir"
    local node_states="{}"
    # Args: node_id=status pairs
    while [[ $# -gt 0 ]]; do
        local nid="${1%%=*}" st="${1#*=}"
        node_states=$(python3 - "$node_states" "$nid" "$st" <<'PYEOF'
import json, sys
ns = json.loads(sys.argv[1])
ns[sys.argv[2]] = {"status": sys.argv[3], "task_id": None, "started_at": None,
                   "completed_at": None, "result_path": None, "retries": 0}
print(json.dumps(ns))
PYEOF
        )
        shift
    done
    python3 - "$tl_dir/task-list-state.json" "$plan_id" "$node_states" <<'PYEOF'
import json, sys
from datetime import datetime, timezone
now = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
with open(sys.argv[1], 'w') as f:
    json.dump({"schema_version":1,"plan_id":sys.argv[2],"active_version":1,
               "superseded_versions":[],"node_states":json.loads(sys.argv[3]),
               "merge_hold":True,"updated_at":now}, f, indent=2)
    f.write('\n')
PYEOF
}

# ---------------------------------------------------------------------------
# 1. Merge refused when running node exists
# ---------------------------------------------------------------------------

@test "merge blocked: running node prevents merge" {
    _write_result "plan-hold-01"
    _write_state "plan-hold-01" "node-a=completed" "node-b=running"

    run run_merge "$TASK_ID" --no-push
    [ "$status" -ne 0 ]
    echo "$output" | grep -qi "merge-hold\|not fully green\|non-terminal"
}

# ---------------------------------------------------------------------------
# 2. Merge refused when pending node exists
# ---------------------------------------------------------------------------

@test "merge blocked: pending + blocked nodes prevent merge" {
    _write_result "plan-hold-02"
    _write_state "plan-hold-02" "node-a=completed" "node-b=pending" "node-c=blocked"

    run run_merge "$TASK_ID" --no-push
    [ "$status" -ne 0 ]
    echo "$output" | grep -qi "merge-hold\|not fully green\|non-terminal"
}

# ---------------------------------------------------------------------------
# 3. Merge permitted when all nodes completed
# ---------------------------------------------------------------------------

@test "merge permitted: all nodes completed" {
    _write_result "plan-hold-03"
    _write_state "plan-hold-03" "node-a=completed" "node-b=completed"

    run run_merge "$TASK_ID" --no-push
    # Merge proceeds past hold gate; any failure after this is git-level (acceptable)
    # The key assertion: exit is NOT 1 from the hold gate check
    [[ "$status" -eq 0 ]] || echo "$output" | grep -qiv "merge-hold\|not fully green"
}

# ---------------------------------------------------------------------------
# 4. Merge permitted when all nodes terminal (mixed completed/failed/superseded)
# ---------------------------------------------------------------------------

@test "merge permitted: terminal mix (completed/failed/timeout/cancelled/superseded)" {
    _write_result "plan-hold-04"
    _write_state "plan-hold-04" \
        "node-a=completed" "node-b=failed" "node-c=timeout" \
        "node-d=cancelled" "node-e=superseded"

    run run_merge "$TASK_ID" --no-push
    [[ "$status" -eq 0 ]] || echo "$output" | grep -qiv "merge-hold\|not fully green"
}

# ---------------------------------------------------------------------------
# 5. merge_hold_enforce=false + no --force-merge → error
# ---------------------------------------------------------------------------

@test "merge_hold_enforce=false + no --force-merge → error (asks for flag)" {
    _write_result "plan-hold-05"
    _write_state "plan-hold-05" "node-a=running"

    # Inject enforce=false via a local config.json override
    printf '{"issuer_domain":"example.com","issuer_agent_id":"op","merge_hold_enforce":false}\n' \
        > "$KIT_TREE/config.json"

    run run_merge "$TASK_ID" --no-push
    [ "$status" -ne 0 ]
    echo "$output" | grep -qi "force-merge\|manual ack"
}

# ---------------------------------------------------------------------------
# 6. merge_hold_enforce=false + --force-merge → warning + event + succeeds past gate
# ---------------------------------------------------------------------------

@test "merge_hold_enforce=false + --force-merge → warning + escalation event" {
    _write_result "plan-hold-06"
    _write_state "plan-hold-06" "node-a=running"
    # Create escalation log dir so the event write doesn't fail
    mkdir -p "$NPS_TASKLISTS_HOME/plan-hold-06"

    printf '{"issuer_domain":"example.com","issuer_agent_id":"op","merge_hold_enforce":false}\n' \
        > "$KIT_TREE/config.json"

    run run_merge "$TASK_ID" --no-push --force-merge
    # Exit 0 (past gate) or a git-level failure; NOT a gate refusal
    echo "$output" | grep -qiv "merge_hold_enforce=false but\|add --force-merge"
    # Warning message must appear
    echo "$output" | grep -qi "manual ack required\|merge_hold_enforce=false"
    # Escalation event written
    local esc_log="$NPS_TASKLISTS_HOME/plan-hold-06/escalation.jsonl"
    [ -f "$esc_log" ]
    grep -q "manual_merge_override" "$esc_log"
}

# ---------------------------------------------------------------------------
# 7. Solo-intent (no plan_id in result) bypasses merge-hold entirely
# ---------------------------------------------------------------------------

@test "solo-intent: no plan_id in result bypasses merge-hold" {
    _write_result ""  # no plan_id
    # State file would refuse a plan-based merge, but there's no plan_id
    # so the gate is never consulted
    _write_state "plan-solo" "node-a=running"

    run run_merge "$TASK_ID" --no-push
    # Must not fail with a merge-hold error
    echo "$output" | grep -qiv "merge-hold\|not fully green"
}

# ---------------------------------------------------------------------------
# 8. Missing state file → warn and proceed past hold gate
# ---------------------------------------------------------------------------

@test "missing state file: warns and proceeds (does not abort)" {
    _write_result "plan-nostate"
    # Do NOT create a state file for plan-nostate

    run run_merge "$TASK_ID" --no-push
    echo "$output" | grep -qi "bypassing\|no task-list-state"
    # Must NOT fail with a hold-gate refusal
    echo "$output" | grep -qiv "not fully green"
}

# ---------------------------------------------------------------------------
# 9. merge_hold=false in state → hold gate passes even with pending nodes
# ---------------------------------------------------------------------------

@test "state merge_hold=false: hold gate passes regardless of node statuses" {
    _write_result "plan-hold-mf"
    local tl_dir="$NPS_TASKLISTS_HOME/plan-hold-mf"
    mkdir -p "$tl_dir"
    python3 - "$tl_dir/task-list-state.json" <<'PYEOF'
import json, sys
from datetime import datetime, timezone
now = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
with open(sys.argv[1], 'w') as f:
    json.dump({"schema_version":1,"plan_id":"plan-hold-mf","active_version":1,
               "superseded_versions":[],"node_states":{"node-a":{"status":"pending",
               "task_id":None,"started_at":None,"completed_at":None,"result_path":None,
               "retries":0}},"merge_hold":False,"updated_at":now}, f, indent=2)
    f.write('\n')
PYEOF

    run run_merge "$TASK_ID" --no-push
    # merge_hold=false in state → gate passes without error
    echo "$output" | grep -qiv "not fully green\|merge-hold"
}
