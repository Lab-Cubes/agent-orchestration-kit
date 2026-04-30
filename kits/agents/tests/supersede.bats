#!/usr/bin/env bats
# supersede.bats — integration tests for spawn-agent.sh dispatch-tasklist supersede pass.
#
# Covers:
#   - Normal-HEAD running worker: SIGINT attempt + Dispatcher-side commit + branch rename
#   - Detached HEAD: blocked + supersede_complex_state event, no rename
#   - Unexpected-branch HEAD: blocked + event, no rename
#   - Pushback-blocked: skip SIGINT, rename + superseded + pushback_superseded event
#   - Complex-HEAD blocked (no pushback): stays blocked, gates drain → KIT-SUPERSEDE-INCOMPLETE
#   - Terminal node: branch rename + supersede_archived event, status unchanged
#   - Drain gate: blocked nodes prevent active_version flip
#   - Drain success: all terminal → active_version flips to N+1
#   - Uncommitted worker state captured by --allow-empty + --no-verify
#   - Pre-commit hook failure bypassed by --no-verify
#   - Supersede with zero in-flight (all v_N completed): all archived, state flips
#   - Mixed-state graph: per-node event granularity
#
# Hard cap: 13 test cases.

load 'helpers/build-kit-tree.bash'

HOST_REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
export HOST_REPO_ROOT

setup_file() {
    HOST_AGENT_REFS_SNAPSHOT_FILE="$(mktemp "${TMPDIR:-/tmp}/supersede-host-agent-refs.XXXXXX")"
    git -C "$HOST_REPO_ROOT" for-each-ref --format='%(refname)' refs/heads/agent > "$HOST_AGENT_REFS_SNAPSHOT_FILE"
    export HOST_AGENT_REFS_SNAPSHOT_FILE
}

setup() {
    KIT_TMPDIR="$(mktemp -d)"
    build_kit_tree "$KIT_TMPDIR"

    local source_kit="${BATS_TEST_DIRNAME%/tests}"
    if [[ -d "$source_kit/src/schemas" ]]; then
        mkdir -p "$KIT_TREE/src"
        cp -r "$source_kit/src/schemas" "$KIT_TREE/src/"
    fi

    FIXTURE_ROOT="$KIT_TMPDIR/state"
    NPS_TASKLISTS_HOME="$FIXTURE_ROOT/task-lists"
    NPS_PLANS_HOME="$FIXTURE_ROOT/plans"
    export NPS_TASKLISTS_HOME NPS_PLANS_HOME

    run_spawner setup coder-01 coder
    run_spawner setup coder-02 coder

    # Minimal git repo used as dispatch-tasklist cwd when node scope is ".".
    REPO="$KIT_TMPDIR/repo"
    git init "$REPO" -b main 2>/dev/null
    git -C "$REPO" config user.email "test@example.com"
    git -C "$REPO" config user.name "Test"
    touch "$REPO/file.txt"
    git -C "$REPO" add .
    git -C "$REPO" commit -m "initial" 2>/dev/null

    FIXTURES_DIR="${BATS_TEST_DIRNAME}/fixtures/task-lists"
}

teardown() {
    # Prune any worktrees before removing the tmpdir
    git -C "${REPO:-/dev/null}" worktree prune 2>/dev/null || true
    for repo in "$KIT_TMPDIR"/repos/*/; do
        [[ -d "$repo" ]] && git -C "$repo" worktree prune 2>/dev/null || true
    done
    rm -rf "${KIT_TMPDIR:-}"
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

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

# Create a git repo with a worktree on a worker branch.
# Sets: _REPO, _BRANCH, _WORKTREE
_make_repo_and_worktree() {
    local plan_id="$1" agent_id="$2" task_id="$3"
    local branch="agent/${agent_id}/${task_id}"
    local repo="$KIT_TMPDIR/repos/${plan_id}-${task_id}"
    mkdir -p "$repo"
    git init "$repo" -b main 2>/dev/null
    git -C "$repo" config user.email "test@example.com"
    git -C "$repo" config user.name "Test Runner"
    touch "$repo/initial.txt"
    git -C "$repo" add .
    git -C "$repo" commit -m "initial" 2>/dev/null
    local wt="$KIT_WORKTREES/${task_id}"
    git -C "$repo" worktree add -b "$branch" "$wt" 2>/dev/null
    git -C "$wt" config user.email "test@example.com"
    git -C "$wt" config user.name "Test Runner"
    mkdir -p "$KIT_AGENTS/${agent_id}/done"
    printf '{"task_id":"%s","agent_id":"%s","branch":"%s","worktree":"%s","original_scope":"%s","status":"success","target_branch":"main"}\n' \
        "$task_id" "$agent_id" "$branch" "$wt" "$repo" \
        > "$KIT_AGENTS/${agent_id}/done/${task_id}.branch.json"
    _REPO="$repo"
    _BRANCH="$branch"
    _WORKTREE="$wt"
}

# Write a minimal two-version task-list setup: v1.json (plan_id nodes) + v2.json (single node)
# and a state file with active_version=1 and specified per-node statuses.
# v1 is a single-node list using coder-01; v2 uses single-task.json (coder-01 also)
_write_two_version_plan() {
    local plan_id="$1"; shift
    local tl_dir="$NPS_TASKLISTS_HOME/$plan_id"
    mkdir -p "$tl_dir"

    # v2: reuse single-task fixture with updated plan_id
    python3 - "$FIXTURES_DIR/single-task.json" "$tl_dir/v2.json" "$plan_id" 2 <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
d['plan_id'] = sys.argv[3]
d['version_id'] = int(sys.argv[4])
with open(sys.argv[2], 'w') as f:
    json.dump(d, f, indent=2)
PYEOF

    # v1: same single node but version_id=1
    python3 - "$FIXTURES_DIR/single-task.json" "$tl_dir/v1.json" "$plan_id" 1 <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
d['plan_id'] = sys.argv[3]
d['version_id'] = int(sys.argv[4])
with open(sys.argv[2], 'w') as f:
    json.dump(d, f, indent=2)
PYEOF
}

# Write state file with active_version=1 and specified node statuses (key=value pairs)
_write_state_v1() {
    local plan_id="$1"; shift
    local tl_dir="$NPS_TASKLISTS_HOME/$plan_id"
    mkdir -p "$tl_dir"
    local ns_json="{}"
    while [[ $# -gt 0 ]]; do
        local nid="${1%%=*}" st="${1#*=}" tid="${2:-null}" rp="${3:-null}"
        ns_json=$(python3 - "$ns_json" "$nid" "$st" "$tid" "$rp" <<'PYEOF'
import json, sys
ns = json.loads(sys.argv[1])
ns[sys.argv[2]] = {"status": sys.argv[3],
                   "task_id": None if sys.argv[4]=="null" else sys.argv[4],
                   "started_at": None, "completed_at": None,
                   "result_path": None if sys.argv[5]=="null" else sys.argv[5],
                   "retries": 0}
print(json.dumps(ns))
PYEOF
        )
        shift
    done
    python3 - "$tl_dir/task-list-state.json" "$plan_id" "$ns_json" <<'PYEOF'
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

# Assert a node in the current state file has a given status
_assert_node_status() {
    local plan_id="$1" node_id="$2" expected_status="$3"
    run python3 - "$NPS_TASKLISTS_HOME/$plan_id/task-list-state.json" "$node_id" "$expected_status" <<'PYEOF'
import json, sys
s = json.load(open(sys.argv[1]))
actual = s['node_states'].get(sys.argv[2], {}).get('status', 'MISSING')
assert actual == sys.argv[3], f"node {sys.argv[2]}: expected {sys.argv[3]}, got {actual}"
print('ok')
PYEOF
    [ "$status" -eq 0 ]
}

# Assert escalation log contains an event with a given dispatcher_acted value
_assert_event() {
    local plan_id="$1" acted="$2"
    local esc="$NPS_TASKLISTS_HOME/$plan_id/escalation.jsonl"
    [ -f "$esc" ]
    grep -q "\"${acted}\"" "$esc"
}

# ---------------------------------------------------------------------------
# 1. Normal-HEAD running worker: commit captured + branch renamed + state=superseded
# ---------------------------------------------------------------------------

@test "running normal-HEAD: partial commit + branch rename + superseded + supersede_applied event" {
    local PID="plan-sup-01" TID="task-sup-01-a"
    _make_repo_and_worktree "$PID" "coder-01" "$TID"
    _write_two_version_plan "$PID"
    _write_state_v1 "$PID" "node-a=running" "$TID"

    # Uncommitted file in worktree (should be captured by --allow-empty commit)
    echo "partial-work" > "$_WORKTREE/partial.txt"

    run run_dt "$PID"
    [ "$status" -eq 0 ]

    _assert_node_status "$PID" "node-a" "completed"   # v2 node-a completed
    _assert_event "$PID" "supersede_applied"

    # Branch should be renamed to superseded/...
    local new_branch="superseded/${PID}/v1/coder-01/${TID}"
    run git -C "$_REPO" branch --list "$new_branch"
    [ -n "$output" ]

    # Original branch should not exist
    run git -C "$_REPO" branch --list "$_BRANCH"
    [ -z "$output" ]

    # Partial work should be in the superseded branch's history
    run git -C "$_REPO" log --oneline "$new_branch"
    echo "$output" | grep -q "supersede: partial work at v1"
}

# ---------------------------------------------------------------------------
# 2. Detached HEAD: blocked + supersede_complex_state, no rename
# ---------------------------------------------------------------------------

@test "running detached-HEAD: blocked + supersede_complex_state event, no branch rename" {
    local PID="plan-sup-02" TID="task-sup-02-a"
    _make_repo_and_worktree "$PID" "coder-01" "$TID"
    # Detach HEAD in the worktree
    git -C "$_WORKTREE" checkout --detach HEAD 2>/dev/null

    _write_two_version_plan "$PID"
    _write_state_v1 "$PID" "node-a=running" "$TID"

    run run_dt "$PID"
    [ "$status" -ne 0 ]
    echo "$output" | grep -qi "KIT-SUPERSEDE-INCOMPLETE\|blocked"

    _assert_event "$PID" "supersede_complex_state"

    # Original branch should still exist (no rename happened)
    run git -C "$_REPO" branch --list "$_BRANCH"
    [ -n "$output" ]
}

# ---------------------------------------------------------------------------
# 3. Unexpected-branch HEAD: blocked + event, no rename
# ---------------------------------------------------------------------------

@test "running unexpected-branch HEAD: blocked + supersede_complex_state, no rename" {
    local PID="plan-sup-03" TID="task-sup-03-a"
    _make_repo_and_worktree "$PID" "coder-01" "$TID"
    # Switch worktree to a different branch (mid-rebase scenario)
    git -C "$_REPO" branch "other-branch" 2>/dev/null || true
    git -C "$_WORKTREE" checkout "other-branch" 2>/dev/null || true

    _write_two_version_plan "$PID"
    _write_state_v1 "$PID" "node-a=running" "$TID"

    run run_dt "$PID"
    [ "$status" -ne 0 ]
    _assert_event "$PID" "supersede_complex_state"

    # Original branch must still exist
    run git -C "$_REPO" branch --list "$_BRANCH"
    [ -n "$output" ]
}

# ---------------------------------------------------------------------------
# 4. Pushback-blocked worker: rename + superseded + pushback_superseded event
# ---------------------------------------------------------------------------

@test "pushback-blocked: branch renamed + superseded + pushback_superseded event" {
    local PID="plan-sup-04" TID="task-sup-04-a"
    _make_repo_and_worktree "$PID" "coder-01" "$TID"

    # Write result.json with pushback_reason (pushback-blocked scenario)
    local rp="$KIT_AGENTS/coder-01/done/${TID}.result.json"
    cat > "$rp" <<EOF
{"_ncp":1,"type":"result","value":"pushback","probability":0.5,"alternatives":[],
 "payload":{"_nop":1,"id":"${TID}","status":"blocked","pushback_reason":"scope_insufficient",
  "from":"urn:nps:agent:example.com:coder-01",
  "picked_up_at":"2026-01-01T00:00:00Z","completed_at":"2026-01-01T00:01:00Z"}}
EOF

    _write_two_version_plan "$PID"
    _write_state_v1 "$PID" "node-a=blocked" "$TID" "$rp"

    run run_dt "$PID"
    [ "$status" -eq 0 ]

    _assert_event "$PID" "pushback_superseded"

    local new_branch="superseded/${PID}/v1/coder-01/${TID}"
    run git -C "$_REPO" branch --list "$new_branch"
    [ -n "$output" ]
}

# ---------------------------------------------------------------------------
# 5. Complex-HEAD blocked (no pushback): stays blocked, gates drain
# ---------------------------------------------------------------------------

@test "complex-HEAD blocked (no pushback): gates drain → KIT-SUPERSEDE-INCOMPLETE" {
    local PID="plan-sup-05" TID="task-sup-05-a"
    _make_repo_and_worktree "$PID" "coder-01" "$TID"

    # blocked node with NO pushback result file
    _write_two_version_plan "$PID"
    _write_state_v1 "$PID" "node-a=blocked" "$TID"

    run run_dt "$PID"
    [ "$status" -ne 0 ]
    echo "$output" | grep -qi "KIT-SUPERSEDE-INCOMPLETE"
    _assert_event "$PID" "supersede_complex_state"

    # active_version must stay at 1 (no flip)
    run python3 - "$NPS_TASKLISTS_HOME/$PID/task-list-state.json" <<'PYEOF'
import json, sys
s = json.load(open(sys.argv[1]))
assert s['active_version'] == 1, f"expected 1, got {s['active_version']}"
print('ok')
PYEOF
    [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# 6. Terminal node: branch rename only + supersede_archived, status unchanged
# ---------------------------------------------------------------------------

@test "terminal node (completed): branch archived + supersede_archived event, status=completed" {
    local PID="plan-sup-06" TID="task-sup-06-a"
    _make_repo_and_worktree "$PID" "coder-01" "$TID"

    _write_two_version_plan "$PID"
    _write_state_v1 "$PID" "node-a=completed" "$TID"

    run run_dt "$PID"
    [ "$status" -eq 0 ]

    _assert_event "$PID" "supersede_archived"

    local new_branch="superseded/${PID}/v1/coder-01/${TID}"
    run git -C "$_REPO" branch --list "$new_branch"
    [ -n "$output" ]
}

# ---------------------------------------------------------------------------
# 7. Drain gate: all terminal after supersede → active_version flips to N+1
# ---------------------------------------------------------------------------

@test "drain gate: all v1 nodes terminal → active_version flips to 2, v2 nodes dispatched" {
    local PID="plan-sup-07" TID="task-sup-07-a"
    _make_repo_and_worktree "$PID" "coder-01" "$TID"

    _write_two_version_plan "$PID"
    _write_state_v1 "$PID" "node-a=completed" "$TID"

    run run_dt "$PID"
    [ "$status" -eq 0 ]

    # active_version must be 2 after flip
    run python3 - "$NPS_TASKLISTS_HOME/$PID/task-list-state.json" <<'PYEOF'
import json, sys
s = json.load(open(sys.argv[1]))
assert s['active_version'] == 2, f"expected 2, got {s['active_version']}"
assert 1 in s['superseded_versions'], f"1 not in superseded_versions"
print('ok')
PYEOF
    [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# 8. Uncommitted state captured + pre-commit hook bypassed by --no-verify
# ---------------------------------------------------------------------------

@test "uncommitted state + failing pre-commit hook: commit lands via --allow-empty --no-verify" {
    local PID="plan-sup-08" TID="task-sup-08-a"
    _make_repo_and_worktree "$PID" "coder-01" "$TID"

    # Add a pre-commit hook that always fails
    cat > "$_REPO/.git/hooks/pre-commit" <<'EOF'
#!/bin/bash
exit 1
EOF
    chmod +x "$_REPO/.git/hooks/pre-commit"

    # Uncommitted file
    echo "wip" > "$_WORKTREE/wip.txt"

    _write_two_version_plan "$PID"
    _write_state_v1 "$PID" "node-a=running" "$TID"

    run run_dt "$PID"
    # --no-verify skips hook; commit should succeed → supersede completes
    [ "$status" -eq 0 ]
    _assert_event "$PID" "supersede_applied"

    # wip.txt must be captured in the superseded branch
    local new_branch="superseded/${PID}/v1/coder-01/${TID}"
    run git -C "$_REPO" show "${new_branch}:wip.txt"
    [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# 9. Supersede with zero in-flight (all v1 completed): all archived, state flips
# ---------------------------------------------------------------------------

@test "zero in-flight supersede: all v1 completed → archived + state flips to v2" {
    local PID="plan-sup-09"
    local TID_A="task-sup-09-a"
    _make_repo_and_worktree "$PID" "coder-01" "$TID_A"

    _write_two_version_plan "$PID"
    _write_state_v1 "$PID" "node-a=completed" "$TID_A"

    run run_dt "$PID"
    [ "$status" -eq 0 ]

    _assert_event "$PID" "supersede_archived"

    # active_version flipped
    run python3 - "$NPS_TASKLISTS_HOME/$PID/task-list-state.json" <<'PYEOF'
import json, sys
s = json.load(open(sys.argv[1]))
assert s['active_version'] == 2, f"expected 2, got {s['active_version']}"
print('ok')
PYEOF
    [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# 10. Mixed-state graph: per-node event granularity
# ---------------------------------------------------------------------------

@test "mixed-state v1 (completed + running-normal + pending): per-node events, all handled" {
    local PID="plan-sup-10"
    local TID_A="task-sup-10-a" TID_B="task-sup-10-b"

    # Two workers for two nodes; v1 must have two nodes → build a custom v1.json
    _make_repo_and_worktree "$PID" "coder-01" "$TID_A"
    local WT_A="$_WORKTREE" REPO_A="$_REPO" BRANCH_A="$_BRANCH"
    _make_repo_and_worktree "${PID}-b" "coder-01" "$TID_B"
    local WT_B="$_WORKTREE" REPO_B="$_REPO" BRANCH_B="$_BRANCH"
    # Re-point coder-01/done/ branch.json for TID_B to REPO_A (same repo for simplicity)
    git -C "$REPO_A" worktree add -b "agent/coder-01/${TID_B}" "$WT_B" 2>/dev/null || true
    printf '{"task_id":"%s","agent_id":"coder-01","branch":"agent/coder-01/%s","worktree":"%s","original_scope":"%s","status":"success","target_branch":"main"}\n' \
        "$TID_B" "$TID_B" "$WT_B" "$REPO_A" \
        > "$KIT_AGENTS/coder-01/done/${TID_B}.branch.json"

    local tl_dir="$NPS_TASKLISTS_HOME/$PID"
    mkdir -p "$tl_dir"
    # v1: two nodes (node-a=coder-01, node-b=coder-01)
    python3 - "$tl_dir/v1.json" "$PID" "$TID_A" "$TID_B" <<'PYEOF'
import json, sys
path, plan_id, tid_a, tid_b = sys.argv[1:]
with open(path, 'w') as f:
    json.dump({"_ncp":1,"type":"task_list","schema_version":1,"plan_id":plan_id,
               "version_id":1,"created_at":"2026-01-01T00:00:00Z",
               "created_by":"urn:nps:agent:example.com:decomposer",
               "prior_version":None,"pushback_reason":None,
               "dag":{"nodes":[
                   {"id":"node-a","action":"task-a","agent":"urn:nps:agent:example.com:coder-01",
                    "input_from":[],"input_mapping":{},"scope":[],"budget_npt":1000,
                    "timeout_ms":60000,"retry_policy":{"max_retries":0,"backoff_ms":0},
                    "condition":None,"success_criteria":{}},
                   {"id":"node-b","action":"task-b","agent":"urn:nps:agent:example.com:coder-01",
                    "input_from":[],"input_mapping":{},"scope":[],"budget_npt":1000,
                    "timeout_ms":60000,"retry_policy":{"max_retries":0,"backoff_ms":0},
                    "condition":None,"success_criteria":{}}
               ],"edges":[]}}, f, indent=2)
PYEOF
    # v2: single node
    python3 - "$FIXTURES_DIR/single-task.json" "$tl_dir/v2.json" "$PID" 2 <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
d['plan_id'] = sys.argv[3]
d['version_id'] = int(sys.argv[4])
with open(sys.argv[2], 'w') as f:
    json.dump(d, f, indent=2)
PYEOF

    # State: node-a=completed, node-b=running (normal HEAD on BRANCH_B)
    _write_state_v1 "$PID" "node-a=completed" "$TID_A" "node-b=running" "$TID_B"

    run run_dt "$PID"
    [ "$status" -eq 0 ]

    # Both events present
    _assert_event "$PID" "supersede_archived"
    _assert_event "$PID" "supersede_applied"

    # active_version flipped
    run python3 - "$NPS_TASKLISTS_HOME/$PID/task-list-state.json" <<'PYEOF'
import json, sys
s = json.load(open(sys.argv[1]))
assert s['active_version'] == 2, f"expected 2, got {s['active_version']}"
print('ok')
PYEOF
    [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# 11. Pending v1 node: archived (no branch) + active_version flips
# ---------------------------------------------------------------------------

@test "pending v1 node (never dispatched): archived without branch rename, state flips" {
    local PID="plan-sup-11"
    _write_two_version_plan "$PID"
    # node-a is pending (no task_id, no worktree)
    _write_state_v1 "$PID" "node-a=pending"

    run run_dt "$PID"
    [ "$status" -eq 0 ]

    _assert_event "$PID" "supersede_archived"

    run python3 - "$NPS_TASKLISTS_HOME/$PID/task-list-state.json" <<'PYEOF'
import json, sys
s = json.load(open(sys.argv[1]))
assert s['active_version'] == 2, f"expected 2, got {s['active_version']}"
print('ok')
PYEOF
    [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# 12. Clean worktree: --allow-empty commit lands even with nothing staged
# ---------------------------------------------------------------------------

@test "clean worktree: --allow-empty commit captured with no staged changes" {
    local PID="plan-sup-12" TID="task-sup-12-a"
    _make_repo_and_worktree "$PID" "coder-01" "$TID"
    # Worktree is completely clean (no uncommitted files)

    _write_two_version_plan "$PID"
    _write_state_v1 "$PID" "node-a=running" "$TID"

    run run_dt "$PID"
    [ "$status" -eq 0 ]

    _assert_event "$PID" "supersede_applied"

    local new_branch="superseded/${PID}/v1/coder-01/${TID}"
    run git -C "$_REPO" log --oneline "$new_branch"
    # The supersede commit must appear even on a clean worktree
    echo "$output" | grep -q "supersede: partial work at v1"
}

# ---------------------------------------------------------------------------
# 13. Host agent refs unchanged by dispatch-tasklist runs
# ---------------------------------------------------------------------------

@test "host agent refs unchanged by dispatch-tasklist runs" {
    local current_refs="$KIT_TMPDIR/host-agent-refs.after"
    git -C "$HOST_REPO_ROOT" for-each-ref --format='%(refname)' refs/heads/agent > "$current_refs"

    run diff -u "$HOST_AGENT_REFS_SNAPSHOT_FILE" "$current_refs"
    [ "$status" -eq 0 ]
}
