#!/usr/bin/env bats
# decompose.bats — integration tests for spawn-agent.sh decompose command.
#
# Tests the Plan → Decomposer → pending task-list pipeline:
#   - Happy path: trivial.py creates pending/v1.json, stdout is path
#   - Schema validation: pending file conforms to task-list schema
#   - Error paths: bad stdin JSON, missing plan_id, non-zero decomposer exit
#   - Schema-violation output: schema_violation escalation event
#   - DAG validation: NOP-TASK-DAG-TOO-LARGE and NOP-TASK-DAG-CYCLE
#   - Pushback path: prior_version=1 → v2.json, invoked_decomposer event
#   - Config override: custom decomposer_cmd honoured from config.json
#
# Schema validation (cmd_decompose always runs it) requires the jsonschema
# Python package. Tests that exercise a successful Decomposer invocation skip
# when jsonschema is absent.
#
# Each test builds an isolated fixture tree under BATS_TMPDIR using helpers.

load 'helpers/build-kit-tree.bash'

PLAN_ID="plan-test-20260425-120000"

setup() {
    KIT_TMPDIR="$(mktemp -d)"
    build_kit_tree "$KIT_TMPDIR"

    # Copy src/schemas into the kit tree so validate_schema.py can find them
    # (build_kit_tree copies scripts/ and templates/ but not src/).
    local source_kit="${BATS_TEST_DIRNAME%/tests}"
    if [[ -d "$source_kit/src/schemas" ]]; then
        mkdir -p "$KIT_TREE/src"
        cp -r "$source_kit/src/schemas" "$KIT_TREE/src/"
    fi

    NPS_TASKLISTS_HOME="$KIT_TMPDIR/task-lists"
    export NPS_TASKLISTS_HOME
}

teardown() {
    rm -rf "${KIT_TMPDIR:-}"
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Invoke spawn-agent.sh decompose without stdin (for --help).
run_decompose() {
    NPS_AGENTS_HOME="$KIT_AGENTS" \
    NPS_WORKTREES_HOME="$KIT_WORKTREES" \
    NPS_LOGS_HOME="$KIT_LOGS" \
    NPS_TASKLISTS_HOME="$NPS_TASKLISTS_HOME" \
    "$KIT_SCRIPTS/spawn-agent.sh" decompose "$@"
}

# Invoke spawn-agent.sh decompose with input from a file piped to stdin.
run_decompose_from() {
    local input_file="$1"; shift
    NPS_AGENTS_HOME="$KIT_AGENTS" \
    NPS_WORKTREES_HOME="$KIT_WORKTREES" \
    NPS_LOGS_HOME="$KIT_LOGS" \
    NPS_TASKLISTS_HOME="$NPS_TASKLISTS_HOME" \
    "$KIT_SCRIPTS/spawn-agent.sh" decompose "$@" < "$input_file"
}

# Write a standard DecomposeInput JSON to $KIT_TMPDIR/fixture.json.
# Args: [plan_id] [prior_version_int_or_null]
_write_fixture() {
    local plan_id="${1:-$PLAN_ID}"
    local prior_version="${2:-null}"
    local file="$KIT_TMPDIR/fixture.json"
    python3 - "$file" "$plan_id" "$prior_version" <<'PYEOF'
import json, sys
file, plan_id, prior_str = sys.argv[1], sys.argv[2], sys.argv[3]
prior = int(prior_str) if prior_str != 'null' else None
json.dump({
    "plan": "---\nplan_id: " + plan_id + "\ntitle: Test plan\nstatus: pending\n---\nBody.",
    "context": {"files": [], "knowledge": [], "branch": "main"},
    "prior_version": prior, "prior_state": None, "pushback": None,
}, open(file, 'w'), indent=2)
PYEOF
    echo "$file"
}

# Write a schema-valid TaskListMessage JSON to the given output path.
# Args: output_path node_count [add_cycle=false]
_write_mock_task_list() {
    local out_path="$1"
    local node_count="${2:-1}"
    local add_cycle="${3:-false}"
    python3 - "$out_path" "$node_count" "$add_cycle" <<'PYEOF'
import json, sys
out_path, node_count, add_cycle = sys.argv[1], int(sys.argv[2]), sys.argv[3] == 'true'

def node(i):
    return {
        "id": f"node-{i}", "action": "act",
        "agent": "urn:nps:agent:test.localhost:coder-01",
        "input_from": [], "input_mapping": {}, "scope": ["."],
        "budget_npt": 1000, "timeout_ms": 60000,
        "retry_policy": {"max_retries": 0, "backoff_ms": 0},
        "condition": None, "success_criteria": {},
    }

nodes = [node(i) for i in range(node_count)]
edges = ([{"from": "node-0", "to": "node-1"}, {"from": "node-1", "to": "node-0"}]
         if add_cycle and node_count >= 2 else [])

json.dump({
    "_ncp": 1, "type": "task_list", "schema_version": 1,
    "plan_id": "plan-test-20260425-120000", "version_id": 1,
    "created_at": "2026-04-25T12:00:00Z",
    "created_by": "urn:nps:agent:test.localhost:mock-decomposer",
    "prior_version": None, "pushback_reason": None,
    "dag": {"nodes": nodes, "edges": edges},
}, open(out_path, 'w'))
PYEOF
}

# Patch decomposer_cmd in $KIT_TREE/config.json.
_override_decomposer() {
    local cmd="$1"
    python3 - "$KIT_TREE/config.json" "$cmd" <<'PYEOF'
import json, sys
path, cmd = sys.argv[1], sys.argv[2]
d = json.load(open(path))
d["decomposer_cmd"] = cmd
json.dump(d, open(path, 'w'), indent=2)
PYEOF
}

# Print the last line of escalation.jsonl for $PLAN_ID.
_last_event() {
    local log="$NPS_TASKLISTS_HOME/$PLAN_ID/escalation.jsonl"
    python3 - "$log" <<'PYEOF'
import json, sys
lines = [l.strip() for l in open(sys.argv[1]) if l.strip()]
assert lines, f"escalation.jsonl is empty: {sys.argv[1]}"
print(lines[-1])
PYEOF
}

# Skip if jsonschema is absent (cmd_decompose schema validation requires it).
_require_jsonschema() {
    if ! python3 -c "import jsonschema" 2>/dev/null; then
        skip "jsonschema not installed — required for cmd_decompose schema gate"
    fi
}

# ---------------------------------------------------------------------------
# 1 — --help
# ---------------------------------------------------------------------------

@test "decompose --help: prints usage and exits 0" {
    run run_decompose --help

    [ "$status" -eq 0 ]
    echo "$output" | grep -q "decompose"
    echo "$output" | grep -q "pending"
    echo "$output" | grep -q "prior_version"
}

# ---------------------------------------------------------------------------
# 2 — Trivial happy path: pending file created
# ---------------------------------------------------------------------------

@test "trivial decomposer: pending/v1.json created on success" {
    _require_jsonschema
    local fixture
    fixture=$(_write_fixture)

    run run_decompose_from "$fixture"

    [ "$status" -eq 0 ]
    [ -f "$NPS_TASKLISTS_HOME/$PLAN_ID/pending/v1.json" ]
}

# ---------------------------------------------------------------------------
# 3 — Trivial happy path: stdout is path
# ---------------------------------------------------------------------------

@test "trivial decomposer: stdout is absolute path of pending/v1.json" {
    _require_jsonschema
    local fixture
    fixture=$(_write_fixture)

    run run_decompose_from "$fixture"

    [ "$status" -eq 0 ]
    echo "$output" | grep -qF "$NPS_TASKLISTS_HOME/$PLAN_ID/pending/v1.json"
}

# ---------------------------------------------------------------------------
# 4 — Schema validation passes on trivial output
# ---------------------------------------------------------------------------

@test "trivial decomposer: pending file passes task-list schema validation" {
    _require_jsonschema
    local fixture
    fixture=$(_write_fixture)

    run run_decompose_from "$fixture"
    [ "$status" -eq 0 ]

    run python3 "$KIT_SCRIPTS/lib/validate_schema.py" \
        "$KIT_TREE/src/schemas/task-list.schema.json" \
        "$NPS_TASKLISTS_HOME/$PLAN_ID/pending/v1.json"
    [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# 5 — Malformed JSON stdin
# ---------------------------------------------------------------------------

@test "malformed JSON stdin: exits 2, no pending file written" {
    printf 'not valid json\n' > "$KIT_TMPDIR/bad.json"

    run run_decompose_from "$KIT_TMPDIR/bad.json"

    [ "$status" -eq 2 ]
    [ ! -f "$NPS_TASKLISTS_HOME/$PLAN_ID/pending/v1.json" ]
}

# ---------------------------------------------------------------------------
# 6 — Missing plan_id in frontmatter
# ---------------------------------------------------------------------------

@test "missing plan_id in frontmatter: exits 2, no pending file" {
    python3 - "$KIT_TMPDIR/no-planid.json" <<'PYEOF'
import json, sys
json.dump({
    "plan": "---\ntitle: No plan_id here\n---\nBody.",
    "context": {}, "prior_version": None, "prior_state": None, "pushback": None,
}, open(sys.argv[1], 'w'))
PYEOF

    run run_decompose_from "$KIT_TMPDIR/no-planid.json"

    [ "$status" -eq 2 ]
    [ ! -f "$NPS_TASKLISTS_HOME/$PLAN_ID/pending/v1.json" ]
}

# ---------------------------------------------------------------------------
# 7 — Non-zero decomposer exit
# ---------------------------------------------------------------------------

@test "non-zero decomposer exit: exits 1, decomposer_failed/non_zero_exit event" {
    cat > "$KIT_TMPDIR/fail.py" <<'PYEOF'
#!/usr/bin/env python3
import sys
print("mock: simulated failure", file=sys.stderr)
sys.exit(1)
PYEOF
    chmod +x "$KIT_TMPDIR/fail.py"
    _override_decomposer "python3 $KIT_TMPDIR/fail.py"

    local fixture
    fixture=$(_write_fixture)
    run run_decompose_from "$fixture"

    [ "$status" -eq 1 ]
    [ ! -f "$NPS_TASKLISTS_HOME/$PLAN_ID/pending/v1.json" ]

    local ev
    ev=$(_last_event)
    run python3 - "$ev" <<'PYEOF'
import json, sys
ev = json.loads(sys.argv[1])
assert ev["dispatcher_acted"] == "decomposer_failed", ev
assert ev["pushback_reason"] == "non_zero_exit", ev
print("ok")
PYEOF
    [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# 8 — Schema-violation output (valid JSON, missing required fields)
# ---------------------------------------------------------------------------

@test "schema-violation output: exits 1, decomposer_failed/schema_violation event" {
    _require_jsonschema

    cat > "$KIT_TMPDIR/bad-schema.py" <<'PYEOF'
#!/usr/bin/env python3
import json
# Exits 0 but output is missing required task-list fields
print(json.dumps({"type": "task_list", "_ncp": 1, "schema_version": 1}))
PYEOF
    chmod +x "$KIT_TMPDIR/bad-schema.py"
    _override_decomposer "python3 $KIT_TMPDIR/bad-schema.py"

    local fixture
    fixture=$(_write_fixture)
    run run_decompose_from "$fixture"

    [ "$status" -eq 1 ]
    [ ! -f "$NPS_TASKLISTS_HOME/$PLAN_ID/pending/v1.json" ]

    local ev
    ev=$(_last_event)
    run python3 - "$ev" <<'PYEOF'
import json, sys
ev = json.loads(sys.argv[1])
assert ev["dispatcher_acted"] == "decomposer_failed", ev
assert ev["pushback_reason"] == "schema_violation", ev
print("ok")
PYEOF
    [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# 9 — DAG-too-large (33 nodes)
# ---------------------------------------------------------------------------

@test "DAG-too-large: exits 1, decomposer_failed/NOP-TASK-DAG-TOO-LARGE event" {
    _require_jsonschema

    local dag_file="$KIT_TMPDIR/dag-too-large.json"
    _write_mock_task_list "$dag_file" 33

    # Heredoc uses $dag_file expansion — note unquoted PYEOF
    cat > "$KIT_TMPDIR/too-large.py" <<PYEOF
#!/usr/bin/env python3
print(open('$dag_file').read())
PYEOF
    chmod +x "$KIT_TMPDIR/too-large.py"
    _override_decomposer "python3 $KIT_TMPDIR/too-large.py"

    local fixture
    fixture=$(_write_fixture)
    run run_decompose_from "$fixture"

    [ "$status" -eq 1 ]
    [ ! -f "$NPS_TASKLISTS_HOME/$PLAN_ID/pending/v1.json" ]

    local ev
    ev=$(_last_event)
    run python3 - "$ev" <<'PYEOF'
import json, sys
ev = json.loads(sys.argv[1])
assert ev["dispatcher_acted"] == "decomposer_failed", ev
assert ev["pushback_reason"] == "NOP-TASK-DAG-TOO-LARGE", ev
print("ok")
PYEOF
    [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# 10 — DAG-cycle (node-0 → node-1 → node-0)
# ---------------------------------------------------------------------------

@test "DAG-cycle: exits 1, decomposer_failed/NOP-TASK-DAG-CYCLE event" {
    _require_jsonschema

    local dag_file="$KIT_TMPDIR/dag-cycle.json"
    _write_mock_task_list "$dag_file" 2 true

    cat > "$KIT_TMPDIR/cycle.py" <<PYEOF
#!/usr/bin/env python3
print(open('$dag_file').read())
PYEOF
    chmod +x "$KIT_TMPDIR/cycle.py"
    _override_decomposer "python3 $KIT_TMPDIR/cycle.py"

    local fixture
    fixture=$(_write_fixture)
    run run_decompose_from "$fixture"

    [ "$status" -eq 1 ]
    [ ! -f "$NPS_TASKLISTS_HOME/$PLAN_ID/pending/v1.json" ]

    local ev
    ev=$(_last_event)
    run python3 - "$ev" <<'PYEOF'
import json, sys
ev = json.loads(sys.argv[1])
assert ev["dispatcher_acted"] == "decomposer_failed", ev
assert ev["pushback_reason"] == "NOP-TASK-DAG-CYCLE", ev
print("ok")
PYEOF
    [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# 11 — Pushback path (prior_version=1 → v2.json)
# ---------------------------------------------------------------------------

@test "pushback path: prior_version=1 yields v2.json, invoked_decomposer with version 2" {
    _require_jsonschema
    local fixture
    fixture=$(_write_fixture "$PLAN_ID" 1)

    run run_decompose_from "$fixture"

    [ "$status" -eq 0 ]
    [ -f "$NPS_TASKLISTS_HOME/$PLAN_ID/pending/v2.json" ]
    [ ! -f "$NPS_TASKLISTS_HOME/$PLAN_ID/pending/v1.json" ]

    local ev
    ev=$(_last_event)
    run python3 - "$ev" <<'PYEOF'
import json, sys
ev = json.loads(sys.argv[1])
assert ev["dispatcher_acted"] == "invoked_decomposer", ev
assert ev["decomposer_output_version"] == 2, ev
print("ok")
PYEOF
    [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# 12 — Config override: custom decomposer_cmd used
# ---------------------------------------------------------------------------

@test "config override: custom decomposer_cmd in config.json is used" {
    _require_jsonschema

    local sentinel_file="$KIT_TMPDIR/sentinel.json"
    _write_mock_task_list "$sentinel_file" 1

    cat > "$KIT_TMPDIR/sentinel.py" <<PYEOF
#!/usr/bin/env python3
print(open('$sentinel_file').read())
PYEOF
    chmod +x "$KIT_TMPDIR/sentinel.py"
    _override_decomposer "python3 $KIT_TMPDIR/sentinel.py"

    local fixture
    fixture=$(_write_fixture)
    run run_decompose_from "$fixture"

    [ "$status" -eq 0 ]
    [ -f "$NPS_TASKLISTS_HOME/$PLAN_ID/pending/v1.json" ]

    # Pending file should carry the sentinel created_by from the mock decomposer
    run python3 - "$NPS_TASKLISTS_HOME/$PLAN_ID/pending/v1.json" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
assert "mock-decomposer" in d["created_by"], f"created_by={d['created_by']!r}"
print("ok")
PYEOF
    [ "$status" -eq 0 ]
}
