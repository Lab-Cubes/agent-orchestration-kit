#!/usr/bin/env bats
# dispatch_tasklist.bats — integration tests for spawn-agent.sh dispatch-tasklist.
#
# Tests the DAG walk introduced in #63a across the five canonical graph shapes.
# Fixture task-lists live in tests/fixtures/task-lists/; all use the mock Claude
# CLI (tests/bin/claude) so no real LLM calls are made.
#
# TODO(#66): Once the Decomposer is complete, add tests that drive the full
# Plan → Decompose → ack → dispatch-tasklist pipeline end-to-end.
#
# Hard cap: 12 test cases.

load 'helpers/build-kit-tree.bash'

HOST_REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
export HOST_REPO_ROOT

setup_file() {
    HOST_AGENT_REFS_SNAPSHOT_FILE="$(mktemp "${TMPDIR:-/tmp}/dispatch-tasklist-host-agent-refs.XXXXXX")"
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

    # Provision workers used across fixtures
    run_spawner setup coder-01 coder
    run_spawner setup coder-02 coder
    run_spawner setup coder-03 coder

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
    git -C "${REPO:-/dev/null}" worktree prune 2>/dev/null || true
    rm -rf "${KIT_TMPDIR:-}"
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Run dispatch-tasklist with all isolated-env overrides.
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

# Place a fixture as an acked task-list vN.json for a plan.
_write_acked() {
    local plan_id="$1" version="$2" fixture_file="$3"
    local tl_dir="$NPS_TASKLISTS_HOME/$plan_id"
    mkdir -p "$tl_dir"
    cp "$fixture_file" "$tl_dir/v${version}.json"
}

# Assert all nodes in plan's state file have status=completed.
_assert_all_completed() {
    local plan_id="$1"
    run python3 - "$NPS_TASKLISTS_HOME/$plan_id/task-list-state.json" <<'PYEOF'
import json, sys
state = json.load(open(sys.argv[1]))
bad = [(n, v['status']) for n, v in state['node_states'].items() if v['status'] != 'completed']
if bad:
    for n, s in bad: print(f"  {n}: {s}", file=sys.stderr)
    sys.exit(1)
print('ok')
PYEOF
    [ "$status" -eq 0 ]
}

_assert_task_result_plan_id() {
    local plan_id="$1"
    run python3 - "$NPS_TASKLISTS_HOME/$plan_id/task-list-state.json" "$KIT_AGENTS" "$plan_id" <<'PYEOF'
import json, os, sys
state_file, agents_home, plan_id = sys.argv[1:]
state = json.load(open(state_file))
task_ids = [
    ns.get("task_id")
    for ns in state["node_states"].values()
    if ns.get("task_id")
]
assert task_ids, "expected at least one dispatched task_id"
for task_id in task_ids:
    found = False
    for worker in os.listdir(agents_home):
        result_file = os.path.join(agents_home, worker, "done", f"{task_id}.result.json")
        if not os.path.isfile(result_file):
            continue
        found = True
        result = json.load(open(result_file))
        actual = result.get("payload", {}).get("plan_id")
        assert actual == plan_id, f"{task_id}: expected plan_id {plan_id!r}, got {actual!r}"
    assert found, f"{task_id}: result file not found"
print("ok")
PYEOF
    [ "$status" -eq 0 ]
}

_assert_task_intent_success_criteria() {
    local plan_id="$1"
    run python3 - "$NPS_TASKLISTS_HOME/$plan_id/task-list-state.json" "$KIT_AGENTS" <<'PYEOF'
import json, os, sys
state_file, agents_home = sys.argv[1:]
state = json.load(open(state_file))
task_ids = [
    ns.get("task_id")
    for ns in state["node_states"].values()
    if ns.get("task_id")
]
assert task_ids, "expected at least one dispatched task_id"
for task_id in task_ids:
    found = False
    for worker in os.listdir(agents_home):
        for state_dir in ("inbox", "active", "done", "blocked"):
            intent_file = os.path.join(agents_home, worker, state_dir, f"{task_id}.intent.json")
            if not os.path.isfile(intent_file):
                continue
            found = True
            intent = json.load(open(intent_file))
            actual = intent.get("payload", {}).get("success_criteria")
            assert actual == {"tests": ["unit.test.ts"], "commits": ">=1"}, actual
    assert found, f"{task_id}: intent file not found"
print("ok")
PYEOF
    [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# 1. Single-task happy path
# ---------------------------------------------------------------------------

@test "single-task: node-a completes, state=completed, exit 0" {
    local tl_dir="$NPS_TASKLISTS_HOME/plan-single"
    mkdir -p "$tl_dir"
    python3 - "$FIXTURES_DIR/single-task.json" "$tl_dir/v1.json" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
d["dag"]["nodes"][0]["success_criteria"] = {
    "tests": ["unit.test.ts"],
    "commits": ">=1",
}
with open(sys.argv[2], "w") as f:
    json.dump(d, f, indent=2)
    f.write("\n")
PYEOF

    run run_dt plan-single
    [ "$status" -eq 0 ]

    _assert_all_completed plan-single
    _assert_task_result_plan_id plan-single
    _assert_task_intent_success_criteria plan-single
}

# ---------------------------------------------------------------------------
# 2. Linear-3 (A → B → C)
# ---------------------------------------------------------------------------

@test "linear-3: all three nodes complete in sequence, exit 0" {
    _write_acked plan-linear 1 "$FIXTURES_DIR/linear-3.json"

    run run_dt plan-linear
    [ "$status" -eq 0 ]

    _assert_all_completed plan-linear
}

# ---------------------------------------------------------------------------
# 3. Fan-out (root → leaf-a, leaf-b, leaf-c in parallel)
# ---------------------------------------------------------------------------

@test "fan-out: root then three parallel leaves all complete, exit 0" {
    _write_acked plan-fanout 1 "$FIXTURES_DIR/fan-out.json"

    run run_dt plan-fanout
    [ "$status" -eq 0 ]

    _assert_all_completed plan-fanout
}

# ---------------------------------------------------------------------------
# 4. Fan-in (root-a, root-b, root-c → merger)
# ---------------------------------------------------------------------------

@test "fan-in: three parallel roots then merger all complete, exit 0" {
    _write_acked plan-fanin 1 "$FIXTURES_DIR/fan-in.json"

    run run_dt plan-fanin
    [ "$status" -eq 0 ]

    _assert_all_completed plan-fanin
}

# ---------------------------------------------------------------------------
# 5. Diamond (root → branch-a, branch-b → terminal)
# ---------------------------------------------------------------------------

@test "diamond: all four nodes complete through two parallel branches, exit 0" {
    _write_acked plan-diamond 1 "$FIXTURES_DIR/diamond.json"

    run run_dt plan-diamond
    [ "$status" -eq 0 ]

    _assert_all_completed plan-diamond
}

# ---------------------------------------------------------------------------
# 6. Failed node: downstream stays pending, exit 1
# ---------------------------------------------------------------------------

@test "failed node: downstream stays pending, dispatcher exits 1" {
    _write_acked plan-fail 1 "$FIXTURES_DIR/linear-3.json"

    # All claude invocations fail (is_error:true → status:failed)
    export MOCK_CLAUDE_MODE=error
    run run_dt plan-fail
    unset MOCK_CLAUDE_MODE
    [ "$status" -eq 1 ]

    # node-a failed; node-b and node-c must not have been dispatched
    run python3 - "$NPS_TASKLISTS_HOME/plan-fail/task-list-state.json" <<'PYEOF'
import json, sys
s = json.load(open(sys.argv[1]))
ns = s['node_states']
assert ns['node-a']['status'] == 'failed',   f"node-a: {ns['node-a']['status']}"
assert ns['node-b']['status'] == 'pending',  f"node-b: {ns['node-b']['status']}"
assert ns['node-c']['status'] == 'pending',  f"node-c: {ns['node-c']['status']}"
print('ok')
PYEOF
    [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# 7. Kit no-lifecycle failure: no retry, escalation preserves kit code
# ---------------------------------------------------------------------------

@test "#177 no-lifecycle kit error: node fails without retry and escalation names code" {
    local tl_dir="$NPS_TASKLISTS_HOME/plan-no-lifecycle"
    mkdir -p "$tl_dir"
    python3 - "$FIXTURES_DIR/single-task.json" "$tl_dir/v1.json" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
d["plan_id"] = "plan-no-lifecycle"
d["dag"]["nodes"][0]["retry_policy"]["max_retries"] = 1
with open(sys.argv[2], "w") as f:
    json.dump(d, f, indent=2)
    f.write("\n")
PYEOF

    export MOCK_CLAUDE_MODE=no_claim
    run run_dt plan-no-lifecycle
    unset MOCK_CLAUDE_MODE

    [ "$status" -eq 1 ]
    echo "$output" | grep -q "KIT-DISPATCH-NO-LIFECYCLE"

    run python3 - "$NPS_TASKLISTS_HOME/plan-no-lifecycle/task-list-state.json" "$KIT_AGENTS" <<'PYEOF'
import json, os, sys
state_file, agents_home = sys.argv[1:]
s = json.load(open(state_file))
node = s["node_states"]["node-a"]
assert node["status"] == "failed", node
assert node.get("retries", 0) == 0, node
assert node["task_id"], node
assert node.get("result_path") is None, node
tid = node["task_id"]
assert os.path.isfile(os.path.join(agents_home, "coder-01", "done", f"{tid}.unclaimed.intent.json")), tid
assert not os.path.exists(os.path.join(agents_home, "coder-01", "done", f"{tid}.result.json")), tid
print("ok")
PYEOF
    [ "$status" -eq 0 ]

    run python3 - "$NPS_TASKLISTS_HOME/plan-no-lifecycle/escalation.jsonl" <<'PYEOF'
import json, sys
events = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
matches = [
    e for e in events
    if e.get("dispatcher_acted") == "escalated_to_oser"
    and e.get("pushback_reason") == "KIT-DISPATCH-NO-LIFECYCLE"
]
assert matches, events
print("ok")
PYEOF
    [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# 8. Concurrent flock reject: second invocation exits 1
# ---------------------------------------------------------------------------

@test "concurrent flock: second dispatch-tasklist exits 1 while first holds lock" {
    _write_acked plan-lock 1 "$FIXTURES_DIR/single-task.json"

    local plan_dir="$NPS_TASKLISTS_HOME/plan-lock"
    local lock_file="$plan_dir/.dispatcher.lock"
    local lock_ready="$KIT_TMPDIR/lock-ready"

    # Acquire the dispatcher lock in a background Python process
    python3 - "$lock_file" "$lock_ready" <<'PYEOF' &
import fcntl, sys, time, os
os.makedirs(os.path.dirname(os.path.abspath(sys.argv[1])), exist_ok=True)
lf = open(sys.argv[1], 'w')
fcntl.flock(lf, fcntl.LOCK_EX)
open(sys.argv[2], 'w').close()   # signal: lock held
time.sleep(30)
PYEOF
    local lock_pid=$!

    # Wait up to 5s for lock to be held
    local i=0
    while [[ ! -f "$lock_ready" ]] && (( i < 50 )); do
        sleep 0.1
        (( i += 1 ))
    done

    run run_dt plan-lock
    local dt_status="$status"

    kill "$lock_pid" 2>/dev/null || true
    wait "$lock_pid" 2>/dev/null || true

    [ "$dt_status" -eq 1 ]
    echo "$output" | grep -qi "another dispatcher\|already running"
}

# ---------------------------------------------------------------------------
# 8. --version auto-select: highest acked vN.json
# ---------------------------------------------------------------------------

@test "--version auto-select: highest acked version is dispatched" {
    local tl_dir="$NPS_TASKLISTS_HOME/plan-autosel"
    mkdir -p "$tl_dir"

    # v1 stays as-is (version_id=1); v3 gets version_id=3
    cp "$FIXTURES_DIR/single-task.json" "$tl_dir/v1.json"
    python3 - "$FIXTURES_DIR/single-task.json" "$tl_dir/v3.json" 3 <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
d['version_id'] = int(sys.argv[3])
with open(sys.argv[2], 'w') as f:
    json.dump(d, f, indent=2)
PYEOF

    # No --version flag → auto-selects v3 (highest)
    run run_dt plan-autosel
    [ "$status" -eq 0 ]

    # State active_version must equal the version_id baked into v3.json
    run python3 - "$tl_dir/task-list-state.json" <<'PYEOF'
import json, sys
s = json.load(open(sys.argv[1]))
assert s['active_version'] == 3, f"expected 3, got {s['active_version']}"
print('ok')
PYEOF
    [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# 9. --version N explicit override
# ---------------------------------------------------------------------------

@test "--version N: explicit flag dispatches specified version, not the latest" {
    local tl_dir="$NPS_TASKLISTS_HOME/plan-explicit"
    mkdir -p "$tl_dir"

    # v1 (version_id=1) and v2 (version_id=2) both acked
    cp "$FIXTURES_DIR/single-task.json" "$tl_dir/v1.json"
    python3 - "$FIXTURES_DIR/single-task.json" "$tl_dir/v2.json" 2 <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
d['version_id'] = int(sys.argv[3])
with open(sys.argv[2], 'w') as f:
    json.dump(d, f, indent=2)
PYEOF

    # Explicitly request v1 (not the latest v2)
    run run_dt plan-explicit --version 1
    [ "$status" -eq 0 ]

    # State active_version=1, not 2
    run python3 - "$tl_dir/task-list-state.json" <<'PYEOF'
import json, sys
s = json.load(open(sys.argv[1]))
assert s['active_version'] == 1, f"expected 1, got {s['active_version']}"
print('ok')
PYEOF
    [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# 10. Schema-invalid task-list: exit 2, no workers spawned
# ---------------------------------------------------------------------------

@test "schema-invalid task-list: parse failure exits 2, no intent files written" {
    # Structurally broken: missing dag key — Python parse step throws KeyError
    local tl_dir="$NPS_TASKLISTS_HOME/plan-invalid"
    mkdir -p "$tl_dir"
    printf '{"_ncp":1,"type":"task_list","schema_version":1,"version_id":1}\n' \
        > "$tl_dir/v1.json"

    run run_dt plan-invalid
    [ "$status" -eq 2 ]

    # No intents written to any worker inbox
    local total=0
    for worker in coder-01 coder-02 coder-03; do
        local n
        n=$(find "$KIT_AGENTS/$worker/inbox" -maxdepth 1 -name '*.intent.json' 2>/dev/null | wc -l)
        total=$(( total + n ))
    done
    [ "$total" -eq 0 ]
}

# ---------------------------------------------------------------------------
# 11. Empty DAG: exit 2, no workers spawned
# ---------------------------------------------------------------------------

@test "empty DAG task-list: exits 2, no intent files written" {
    local tl_dir="$NPS_TASKLISTS_HOME/plan-empty"
    mkdir -p "$tl_dir"
    python3 - "$FIXTURES_DIR/single-task.json" "$tl_dir/v1.json" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
d["plan_id"] = "plan-empty"
d["dag"]["nodes"] = []
d["dag"]["edges"] = []
with open(sys.argv[2], "w") as f:
    json.dump(d, f, indent=2)
    f.write("\n")
PYEOF

    run run_dt plan-empty
    [ "$status" -eq 2 ]
    echo "$output" | grep -q "task-list DAG has no nodes"

    local total=0
    for worker in coder-01 coder-02 coder-03; do
        local n
        n=$(find "$KIT_AGENTS/$worker/inbox" -maxdepth 1 -name '*.intent.json' 2>/dev/null | wc -l)
        total=$(( total + n ))
    done
    [ "$total" -eq 0 ]
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
