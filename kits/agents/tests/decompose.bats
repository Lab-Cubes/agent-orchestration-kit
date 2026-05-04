#!/usr/bin/env bats
# decompose.bats — integration tests for spawn-agent.sh decompose command.
#
# Tests the Plan → Decomposer → pending task-list pipeline:
#   - Happy path: trivial.py creates pending/v1.json, stdout is path
#   - Schema validation: pending file conforms to task-list schema
#   - Error paths: bad stdin JSON, missing plan_id, non-zero decomposer exit
#   - Schema-violation output: schema_violation escalation event
#   - DAG validation: NOP-TASK-DAG-TOO-LARGE and NOP-TASK-DAG-CYCLE
#   - Pushback path: prior_version=1 → trivial decomposer refuses (exit 2), decomposer_failed/pushback_unsupported event
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

    run_spawner setup coder-01 coder
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
# Args: output_path node_count [add_cycle=false] [plan_id] [version_id] [prior_version_or_null] [semantic_variant]
_write_mock_task_list() {
    local out_path="$1"
    local node_count="${2:-1}"
    local add_cycle="${3:-false}"
    local plan_id="${4:-$PLAN_ID}"
    local version_id="${5:-1}"
    local prior_version="${6:-null}"
    local semantic_variant="${7:-}"
    python3 - "$out_path" "$node_count" "$add_cycle" "$plan_id" "$version_id" "$prior_version" "$semantic_variant" <<'PYEOF'
import json, sys
out_path = sys.argv[1]
node_count = int(sys.argv[2])
add_cycle = sys.argv[3] == 'true'
plan_id = sys.argv[4]
version_id = int(sys.argv[5])
prior_version = None if sys.argv[6] == 'null' else int(sys.argv[6])
semantic_variant = sys.argv[7]

def node(i):
    return {
        "id": f"node-{i}", "action": "act",
        "agent": "urn:nps:agent:test.localhost:coder-01",
        "input_from": [], "input_mapping": {}, "scope": ["."],
        "budget_cgn": 1000, "timeout_ms": 60000,
        "retry_policy": {"max_retries": 0, "backoff_ms": 0},
        "condition": None, "success_criteria": {},
    }

nodes = [node(i) for i in range(node_count)]
edges = ([{"from": "node-0", "to": "node-1"}, {"from": "node-1", "to": "node-0"}]
         if add_cycle and node_count >= 2 else [])

if semantic_variant == "duplicate_node_id" and len(nodes) >= 2:
    nodes[1]["id"] = nodes[0]["id"]
elif semantic_variant == "edge_phantom":
    edges.append({"from": "node-0", "to": "node-missing"})
elif semantic_variant == "input_from_phantom" and nodes:
    nodes[0]["input_from"] = ["node-missing"]
elif semantic_variant == "agent_not_set_up" and nodes:
    nodes[0]["agent"] = "urn:nps:agent:test.localhost:missing-01"
elif semantic_variant == "budget_excessive" and nodes:
    nodes[0]["budget_cgn"] = 200001
elif semantic_variant == "scope_empty" and nodes:
    nodes[0]["scope"] = []
elif semantic_variant == "scope_dot" and nodes:
    nodes[0]["scope"] = ["."]

json.dump({
    "_ncp": 1, "type": "task_list", "schema_version": 1,
    "plan_id": plan_id, "version_id": version_id,
    "created_at": "2026-04-25T12:00:00Z",
    "created_by": "urn:nps:agent:test.localhost:mock-decomposer",
    "prior_version": prior_version, "pushback_reason": None,
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
    echo "$output" | grep -q "KIT-DECOMP-PLAN-MISMATCH"
    echo "$output" | grep -q "KIT-DECOMP-VERSION-MISMATCH"
    echo "$output" | grep -q "KIT-DECOMP-PRIOR-VERSION-MISMATCH"
    echo "$output" | grep -q "KIT-DECOMP-NODE-ID-DUPLICATE"
    echo "$output" | grep -q "KIT-DECOMP-EDGE-PHANTOM"
    echo "$output" | grep -q "KIT-DECOMP-INPUT-FROM-PHANTOM"
    echo "$output" | grep -q "KIT-DECOMP-AGENT-NOT-SET-UP"
    echo "$output" | grep -q "KIT-DECOMP-BUDGET-EXCESSIVE"
    echo "$output" | grep -q "KIT-DECOMP-SCOPE-EMPTY"
    echo "$output" | grep -q "scope == \\[\"\\.\"\\]"
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
# 10 — Semantic validation: plan_id mismatch
# ---------------------------------------------------------------------------

@test "semantic validation: plan_id mismatch exits 1 with KIT-DECOMP-PLAN-MISMATCH" {
    _require_jsonschema

    local semantic_file="$KIT_TMPDIR/wrong-plan.json"
    _write_mock_task_list "$semantic_file" 1 false "plan-wrong-20260425-120000" 1 null

    cat > "$KIT_TMPDIR/wrong-plan.py" <<PYEOF
#!/usr/bin/env python3
print(open('$semantic_file').read())
PYEOF
    chmod +x "$KIT_TMPDIR/wrong-plan.py"
    _override_decomposer "python3 $KIT_TMPDIR/wrong-plan.py"

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
assert ev["pushback_reason"] == "KIT-DECOMP-PLAN-MISMATCH", ev
print("ok")
PYEOF
    [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# 11 — Semantic validation: version_id mismatch
# ---------------------------------------------------------------------------

@test "semantic validation: version_id mismatch exits 1 with KIT-DECOMP-VERSION-MISMATCH" {
    _require_jsonschema

    local semantic_file="$KIT_TMPDIR/wrong-version.json"
    _write_mock_task_list "$semantic_file" 1 false "$PLAN_ID" 2 null

    cat > "$KIT_TMPDIR/wrong-version.py" <<PYEOF
#!/usr/bin/env python3
print(open('$semantic_file').read())
PYEOF
    chmod +x "$KIT_TMPDIR/wrong-version.py"
    _override_decomposer "python3 $KIT_TMPDIR/wrong-version.py"

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
assert ev["pushback_reason"] == "KIT-DECOMP-VERSION-MISMATCH", ev
print("ok")
PYEOF
    [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# 12 — Semantic validation: prior_version mismatch
# ---------------------------------------------------------------------------

@test "semantic validation: prior_version mismatch exits 1 with KIT-DECOMP-PRIOR-VERSION-MISMATCH" {
    _require_jsonschema

    local semantic_file="$KIT_TMPDIR/wrong-prior-version.json"
    _write_mock_task_list "$semantic_file" 1 false "$PLAN_ID" 2 null

    cat > "$KIT_TMPDIR/wrong-prior-version.py" <<PYEOF
#!/usr/bin/env python3
print(open('$semantic_file').read())
PYEOF
    chmod +x "$KIT_TMPDIR/wrong-prior-version.py"
    _override_decomposer "python3 $KIT_TMPDIR/wrong-prior-version.py"

    local fixture
    fixture=$(_write_fixture "$PLAN_ID" 1)
    run run_decompose_from "$fixture"

    [ "$status" -eq 1 ]
    [ ! -f "$NPS_TASKLISTS_HOME/$PLAN_ID/pending/v2.json" ]

    local ev
    ev=$(_last_event)
    run python3 - "$ev" <<'PYEOF'
import json, sys
ev = json.loads(sys.argv[1])
assert ev["dispatcher_acted"] == "decomposer_failed", ev
assert ev["pushback_reason"] == "KIT-DECOMP-PRIOR-VERSION-MISMATCH", ev
print("ok")
PYEOF
    [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# 13 — Semantic validation: duplicate node id
# ---------------------------------------------------------------------------

@test "semantic validation: duplicate node id exits 1 with KIT-DECOMP-NODE-ID-DUPLICATE" {
    _require_jsonschema

    local semantic_file="$KIT_TMPDIR/duplicate-node-id.json"
    _write_mock_task_list "$semantic_file" 2 false "$PLAN_ID" 1 null duplicate_node_id

    cat > "$KIT_TMPDIR/duplicate-node-id.py" <<PYEOF
#!/usr/bin/env python3
print(open('$semantic_file').read())
PYEOF
    chmod +x "$KIT_TMPDIR/duplicate-node-id.py"
    _override_decomposer "python3 $KIT_TMPDIR/duplicate-node-id.py"

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
assert ev["pushback_reason"] == "KIT-DECOMP-NODE-ID-DUPLICATE", ev
print("ok")
PYEOF
    [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# 14 — Semantic validation: edge references missing node id
# ---------------------------------------------------------------------------

@test "semantic validation: phantom edge exits 1 with KIT-DECOMP-EDGE-PHANTOM" {
    _require_jsonschema

    local semantic_file="$KIT_TMPDIR/edge-phantom.json"
    _write_mock_task_list "$semantic_file" 1 false "$PLAN_ID" 1 null edge_phantom

    cat > "$KIT_TMPDIR/edge-phantom.py" <<PYEOF
#!/usr/bin/env python3
print(open('$semantic_file').read())
PYEOF
    chmod +x "$KIT_TMPDIR/edge-phantom.py"
    _override_decomposer "python3 $KIT_TMPDIR/edge-phantom.py"

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
assert ev["pushback_reason"] == "KIT-DECOMP-EDGE-PHANTOM", ev
print("ok")
PYEOF
    [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# 15 — Semantic validation: input_from references missing node id
# ---------------------------------------------------------------------------

@test "semantic validation: phantom input_from exits 1 with KIT-DECOMP-INPUT-FROM-PHANTOM" {
    _require_jsonschema

    local semantic_file="$KIT_TMPDIR/input-from-phantom.json"
    _write_mock_task_list "$semantic_file" 1 false "$PLAN_ID" 1 null input_from_phantom

    cat > "$KIT_TMPDIR/input-from-phantom.py" <<PYEOF
#!/usr/bin/env python3
print(open('$semantic_file').read())
PYEOF
    chmod +x "$KIT_TMPDIR/input-from-phantom.py"
    _override_decomposer "python3 $KIT_TMPDIR/input-from-phantom.py"

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
assert ev["pushback_reason"] == "KIT-DECOMP-INPUT-FROM-PHANTOM", ev
print("ok")
PYEOF
    [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# 16 — Semantic validation: agent references missing worker
# ---------------------------------------------------------------------------

@test "semantic validation: agent not set up exits 1 with KIT-DECOMP-AGENT-NOT-SET-UP" {
    _require_jsonschema

    local semantic_file="$KIT_TMPDIR/agent-not-set-up.json"
    _write_mock_task_list "$semantic_file" 1 false "$PLAN_ID" 1 null agent_not_set_up

    cat > "$KIT_TMPDIR/agent-not-set-up.py" <<PYEOF
#!/usr/bin/env python3
print(open('$semantic_file').read())
PYEOF
    chmod +x "$KIT_TMPDIR/agent-not-set-up.py"
    _override_decomposer "python3 $KIT_TMPDIR/agent-not-set-up.py"

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
assert ev["pushback_reason"] == "KIT-DECOMP-AGENT-NOT-SET-UP", ev
print("ok")
PYEOF
    [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# 17 — Semantic validation: budget exceeds max_budget_cgn_per_node
# ---------------------------------------------------------------------------

@test "semantic validation: budget excessive exits 1 with KIT-DECOMP-BUDGET-EXCESSIVE" {
    _require_jsonschema

    local semantic_file="$KIT_TMPDIR/budget-excessive.json"
    _write_mock_task_list "$semantic_file" 1 false "$PLAN_ID" 1 null budget_excessive

    cat > "$KIT_TMPDIR/budget-excessive.py" <<PYEOF
#!/usr/bin/env python3
print(open('$semantic_file').read())
PYEOF
    chmod +x "$KIT_TMPDIR/budget-excessive.py"
    _override_decomposer "python3 $KIT_TMPDIR/budget-excessive.py"

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
assert ev["pushback_reason"] == "KIT-DECOMP-BUDGET-EXCESSIVE", ev
print("ok")
PYEOF
    [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# 18 — Semantic validation: empty scope
# ---------------------------------------------------------------------------

@test "semantic validation: empty scope exits 1 with KIT-DECOMP-SCOPE-EMPTY" {
    _require_jsonschema

    local semantic_file="$KIT_TMPDIR/scope-empty.json"
    _write_mock_task_list "$semantic_file" 1 false "$PLAN_ID" 1 null scope_empty

    cat > "$KIT_TMPDIR/scope-empty.py" <<PYEOF
#!/usr/bin/env python3
print(open('$semantic_file').read())
PYEOF
    chmod +x "$KIT_TMPDIR/scope-empty.py"
    _override_decomposer "python3 $KIT_TMPDIR/scope-empty.py"

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
assert ev["pushback_reason"] == "KIT-DECOMP-SCOPE-EMPTY", ev
print("ok")
PYEOF
    [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# 19 — Semantic validation: scope "." warning only
# ---------------------------------------------------------------------------

@test "semantic validation: scope ['.'] passes with stderr warning" {
    _require_jsonschema

    local semantic_file="$KIT_TMPDIR/scope-dot.json"
    _write_mock_task_list "$semantic_file" 1 false "$PLAN_ID" 1 null scope_dot

    cat > "$KIT_TMPDIR/scope-dot.py" <<PYEOF
#!/usr/bin/env python3
print(open('$semantic_file').read())
PYEOF
    chmod +x "$KIT_TMPDIR/scope-dot.py"
    _override_decomposer "python3 $KIT_TMPDIR/scope-dot.py"

    local fixture
    fixture=$(_write_fixture)
    run run_decompose_from "$fixture"

    [ "$status" -eq 0 ]
    [ -f "$NPS_TASKLISTS_HOME/$PLAN_ID/pending/v1.json" ]
    echo "$output" | grep -q "warning: node 'node-0' uses scope \\['\\.'\\]"
}

# ---------------------------------------------------------------------------
# 20 — DAG-cycle (node-0 → node-1 → node-0)
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
# 21 — Pushback path: trivial decomposer refuses re-emission, escalates
# ---------------------------------------------------------------------------

@test "pushback path: prior_version=1 causes trivial decomposer refusal, decomposer_failed/pushback_unsupported event" {
    local fixture
    fixture=$(_write_fixture "$PLAN_ID" 1)

    run run_decompose_from "$fixture"

    # cmd_decompose must exit non-zero; no pending file written
    [ "$status" -ne 0 ]
    [ ! -f "$NPS_TASKLISTS_HOME/$PLAN_ID/pending/v2.json" ]

    local ev
    ev=$(_last_event)
    run python3 - "$ev" <<'PYEOF'
import json, sys
ev = json.loads(sys.argv[1])
assert ev["dispatcher_acted"] == "decomposer_failed", f"dispatcher_acted={ev['dispatcher_acted']!r}"
assert ev["pushback_reason"] == "pushback_unsupported", f"pushback_reason={ev['pushback_reason']!r}"
print("ok")
PYEOF
    [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# 22 — Config override: custom decomposer_cmd used
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
