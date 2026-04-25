#!/usr/bin/env bats
# cmd_ack.bats — unit/integration tests for spawn-agent.sh ack command.
#
# Tests the OSer gate between Decompose and Dispatch:
#   - Approve path: POSIX-atomic rename pending/v{N}.json → v{N}.json
#   - Reject path: keeps pending, writes escalation event
#   - Mid-drain guard: refuses ack when version != active_version + 1
#   - Safety checks: missing plan, missing pending, already-acked
#   - --as <nid> identity override
#   - --help output
#
# Each test builds an isolated fixture tree under BATS_TMPDIR using inline
# heredocs. No dependency on cmd_decompose (#66) — task-list-state.json and
# pending/ files are written directly.

load 'helpers/build-kit-tree.bash'

setup() {
    KIT_TMPDIR="$(mktemp -d)"
    build_kit_tree "$KIT_TMPDIR"

    # Copy src/schemas into the kit tree so validate_schema.py can find them
    # (build_kit_tree only copies scripts/ and templates/).
    local source_kit="${BATS_TEST_DIRNAME%/tests}"
    if [[ -d "$source_kit/src/schemas" ]]; then
        mkdir -p "$KIT_TREE/src"
        cp -r "$source_kit/src/schemas" "$KIT_TREE/src/"
    fi

    # Override plan/task-list homes to an isolated fixture root
    FIXTURE_ROOT="$KIT_TMPDIR/state"
    NPS_PLANS_HOME="$FIXTURE_ROOT/plans"
    NPS_TASKLISTS_HOME="$FIXTURE_ROOT/task-lists"
    export NPS_PLANS_HOME NPS_TASKLISTS_HOME

    PLAN_ID="plan-test-20260424-120000"

    # Create a minimal plan.md so safety check passes
    mkdir -p "$NPS_PLANS_HOME/$PLAN_ID"
    cat > "$NPS_PLANS_HOME/$PLAN_ID/plan.md" <<'EOF'
---
plan_id: plan-test-20260424-120000
title: Test plan
status: acked
---
Test plan body.
EOF
}

teardown() {
    rm -rf "${KIT_TMPDIR:-}"
}

# ---------------------------------------------------------------------------
# Helper: run spawn-agent.sh ack with isolated env.
# ---------------------------------------------------------------------------
run_ack() {
    NPS_AGENTS_HOME="$KIT_AGENTS" \
    NPS_WORKTREES_HOME="$KIT_WORKTREES" \
    NPS_LOGS_HOME="$KIT_LOGS" \
    NPS_PLANS_HOME="$NPS_PLANS_HOME" \
    NPS_TASKLISTS_HOME="$NPS_TASKLISTS_HOME" \
    GIT_AUTHOR_EMAIL="osi@test.local" \
    GIT_COMMITTER_EMAIL="osi@test.local" \
    "$KIT_SCRIPTS/spawn-agent.sh" ack "$@"
}

# ---------------------------------------------------------------------------
# Helper: write a valid pending task-list file and optional state file.
# ---------------------------------------------------------------------------
_write_pending() {
    local version="$1"
    local prior_version="${2:-null}"
    local tl_dir="$NPS_TASKLISTS_HOME/$PLAN_ID"
    mkdir -p "$tl_dir/pending"
    cat > "$tl_dir/pending/v${version}.json" <<EOF
{
  "_ncp": 1,
  "type": "task_list",
  "schema_version": 1,
  "plan_id": "$PLAN_ID",
  "version_id": $version,
  "created_at": "2026-04-24T12:45:00Z",
  "created_by": "urn:nps:agent:example.com:decomposer-01",
  "prior_version": $prior_version,
  "pushback_reason": null,
  "dag": {
    "nodes": [
      {
        "id": "node-1",
        "action": "do-something",
        "agent": "urn:nps:agent:example.com:coder-01",
        "input_from": [],
        "input_mapping": {},
        "scope": ["src/"],
        "budget_npt": 8000,
        "timeout_ms": 600000,
        "retry_policy": {"max_retries": 1, "backoff_ms": 5000},
        "condition": null,
        "success_criteria": {}
      }
    ],
    "edges": []
  }
}
EOF
}

_write_state() {
    local active_version="$1"
    local tl_dir="$NPS_TASKLISTS_HOME/$PLAN_ID"
    mkdir -p "$tl_dir"
    cat > "$tl_dir/task-list-state.json" <<EOF
{
  "schema_version": 1,
  "plan_id": "$PLAN_ID",
  "active_version": $active_version,
  "superseded_versions": [],
  "node_states": {},
  "merge_hold": true,
  "updated_at": "2026-04-24T12:00:00Z"
}
EOF
}

_write_invalid_pending() {
    local version="$1"
    local tl_dir="$NPS_TASKLISTS_HOME/$PLAN_ID"
    mkdir -p "$tl_dir/pending"
    # Missing required fields — will fail task-list schema validation
    cat > "$tl_dir/pending/v${version}.json" <<EOF
{
  "_ncp": 1,
  "type": "task_list",
  "schema_version": 1,
  "plan_id": "$PLAN_ID"
}
EOF
}

# ---------------------------------------------------------------------------
# --help
# ---------------------------------------------------------------------------

@test "ack --help prints usage for approve, reject, and mid-drain guard" {
    run run_ack --help

    [ "$status" -eq 0 ]
    echo "$output" | grep -q "spawn-agent.sh ack <plan-id> <version>"
    echo "$output" | grep -q "\-\-reject"
    echo "$output" | grep -q "mid-drain\|skip\|active_version"
}

# ---------------------------------------------------------------------------
# Approve path — happy path
# ---------------------------------------------------------------------------

@test "approve: renames pending/v1.json → v1.json, exits 0, stdout is acked path" {
    _write_pending 1
    # No state file → active_version defaults to 0, v1 is allowed

    run run_ack "$PLAN_ID" 1

    [ "$status" -eq 0 ]

    # Pending gone; acked present
    [ ! -f "$NPS_TASKLISTS_HOME/$PLAN_ID/pending/v1.json" ]
    [ -f "$NPS_TASKLISTS_HOME/$PLAN_ID/v1.json" ]

    # stdout is the absolute acked path (pipeline-friendly)
    echo "$output" | grep -qF "$NPS_TASKLISTS_HOME/$PLAN_ID/v1.json"
}

@test "approve: escalation event written with correct fields" {
    _write_pending 1

    run run_ack "$PLAN_ID" 1

    [ "$status" -eq 0 ]

    local log="$NPS_TASKLISTS_HOME/$PLAN_ID/escalation.jsonl"
    [ -f "$log" ]

    run python3 - "$log" <<'PYEOF'
import json, sys
with open(sys.argv[1]) as f:
    lines = [l.strip() for l in f if l.strip()]
assert lines, "escalation.jsonl is empty"
ev = json.loads(lines[-1])
assert ev["schema_version"] == 1
assert ev["dispatcher_acted"] == "osi_acked"
assert ev["osi_ack_verdict"] == "approve"
assert ev["decomposer_output_version"] == 1
assert ev["escalation_level"] == "version"
assert ev["plan_id"] is not None
assert ev["osi_ack_at"] is not None
assert ev["osi_ack_by"] is not None
print("ok")
PYEOF
    [ "$status" -eq 0 ]
}

@test "approve: prior_version null when task-list prior_version is null" {
    _write_pending 1 null

    run run_ack "$PLAN_ID" 1

    [ "$status" -eq 0 ]

    local log="$NPS_TASKLISTS_HOME/$PLAN_ID/escalation.jsonl"
    run python3 - "$log" <<'PYEOF'
import json, sys
with open(sys.argv[1]) as f:
    lines = [l.strip() for l in f if l.strip()]
ev = json.loads(lines[-1])
assert ev["prior_version"] is None, f"expected null, got {ev['prior_version']!r}"
print("ok")
PYEOF
    [ "$status" -eq 0 ]
}

@test "approve: prior_version from task-list when set" {
    _write_pending 2 1

    # State has active_version=1 so v2 is the expected next
    _write_state 1

    run run_ack "$PLAN_ID" 2

    [ "$status" -eq 0 ]

    local log="$NPS_TASKLISTS_HOME/$PLAN_ID/escalation.jsonl"
    run python3 - "$log" <<'PYEOF'
import json, sys
with open(sys.argv[1]) as f:
    lines = [l.strip() for l in f if l.strip()]
ev = json.loads(lines[-1])
assert ev["prior_version"] == 1, f"expected 1, got {ev['prior_version']!r}"
assert ev["decomposer_output_version"] == 2
print("ok")
PYEOF
    [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Approve path — --as <nid> override
# ---------------------------------------------------------------------------

@test "approve --as <nid>: escalation event captures the NID" {
    _write_pending 1

    local nid="urn:nps:agent:example.com:opus-overseer"

    run run_ack --as "$nid" "$PLAN_ID" 1

    [ "$status" -eq 0 ]

    local log="$NPS_TASKLISTS_HOME/$PLAN_ID/escalation.jsonl"
    run python3 - "$log" "$nid" <<'PYEOF'
import json, sys
log_path, expected_nid = sys.argv[1], sys.argv[2]
with open(log_path) as f:
    lines = [l.strip() for l in f if l.strip()]
ev = json.loads(lines[-1])
assert ev["osi_ack_by"] == expected_nid, f"expected {expected_nid!r}, got {ev['osi_ack_by']!r}"
print("ok")
PYEOF
    [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Reject path
# ---------------------------------------------------------------------------

@test "reject: pending file stays in place, exits 0" {
    _write_pending 1

    run run_ack --reject "$PLAN_ID" 1

    [ "$status" -eq 0 ]

    # Pending must still be there
    [ -f "$NPS_TASKLISTS_HOME/$PLAN_ID/pending/v1.json" ]
    # Acked must NOT exist
    [ ! -f "$NPS_TASKLISTS_HOME/$PLAN_ID/v1.json" ]
}

@test "reject: escalation event verdict=reject, no pushback_reason when --reason omitted" {
    _write_pending 1

    run run_ack --reject "$PLAN_ID" 1

    [ "$status" -eq 0 ]

    local log="$NPS_TASKLISTS_HOME/$PLAN_ID/escalation.jsonl"
    [ -f "$log" ]

    run python3 - "$log" <<'PYEOF'
import json, sys
with open(sys.argv[1]) as f:
    lines = [l.strip() for l in f if l.strip()]
ev = json.loads(lines[-1])
assert ev["osi_ack_verdict"] == "reject"
assert ev["dispatcher_acted"] == "osi_acked"
assert ev["pushback_reason"] is None
print("ok")
PYEOF
    [ "$status" -eq 0 ]
}

@test "reject --reason: reason captured in pushback_reason field" {
    _write_pending 1

    run run_ack --reject --reason "scope is too broad — split into smaller tasks" "$PLAN_ID" 1

    [ "$status" -eq 0 ]

    local log="$NPS_TASKLISTS_HOME/$PLAN_ID/escalation.jsonl"
    run python3 - "$log" <<'PYEOF'
import json, sys
with open(sys.argv[1]) as f:
    lines = [l.strip() for l in f if l.strip()]
ev = json.loads(lines[-1])
assert ev["osi_ack_verdict"] == "reject"
assert ev["pushback_reason"] == "scope is too broad — split into smaller tasks", \
    f"got: {ev['pushback_reason']!r}"
print("ok")
PYEOF
    [ "$status" -eq 0 ]
}

@test "reject --as <nid>: audit captures the NID" {
    _write_pending 1

    local nid="urn:nps:agent:example.com:opus-overseer"

    run run_ack --reject --as "$nid" "$PLAN_ID" 1

    [ "$status" -eq 0 ]

    local log="$NPS_TASKLISTS_HOME/$PLAN_ID/escalation.jsonl"
    run python3 - "$log" "$nid" <<'PYEOF'
import json, sys
log_path, expected_nid = sys.argv[1], sys.argv[2]
with open(log_path) as f:
    lines = [l.strip() for l in f if l.strip()]
ev = json.loads(lines[-1])
assert ev["osi_ack_by"] == expected_nid
print("ok")
PYEOF
    [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Schema validation (approve path)
# ---------------------------------------------------------------------------

@test "schema-invalid pending: fails without rename, exits non-zero" {
    # Only runs if python3 and jsonschema are available; skip gracefully if not
    if ! python3 -c "import jsonschema" 2>/dev/null; then
        skip "jsonschema not installed — skipping schema validation test"
    fi

    _write_invalid_pending 1

    run run_ack "$PLAN_ID" 1

    [ "$status" -ne 0 ]

    # Pending must remain (rename aborted)
    [ -f "$NPS_TASKLISTS_HOME/$PLAN_ID/pending/v1.json" ]
    [ ! -f "$NPS_TASKLISTS_HOME/$PLAN_ID/v1.json" ]
}

# ---------------------------------------------------------------------------
# Mid-drain guard
# ---------------------------------------------------------------------------

@test "mid-drain guard: acking v3 while active_version=1 fails with clear message" {
    # v3 exists as pending; active_version=1 → next_allowed=2, v3 skips
    _write_pending 3 2
    _write_state 1

    run run_ack "$PLAN_ID" 3

    [ "$status" -ne 0 ]
    echo "$output" | grep -qi "skip\|version.*2\|cannot"
}

@test "mid-drain guard: acking v2 while active_version=1 succeeds" {
    _write_pending 2 1
    _write_state 1

    run run_ack "$PLAN_ID" 2

    [ "$status" -eq 0 ]
    [ -f "$NPS_TASKLISTS_HOME/$PLAN_ID/v2.json" ]
}

@test "mid-drain guard: acking v1 while active_version=1 fails as already-acked" {
    _write_pending 1
    _write_state 1

    run run_ack "$PLAN_ID" 1

    [ "$status" -ne 0 ]
    echo "$output" | grep -qi "already\|historical"
}

@test "mid-drain guard: acking v2 while active_version=2 fails as already-acked" {
    _write_pending 2 1
    _write_state 2

    run run_ack "$PLAN_ID" 2

    [ "$status" -ne 0 ]
    echo "$output" | grep -qi "already\|historical"
}

@test "mid-drain guard: no state file allows v1 (treats active_version as 0)" {
    _write_pending 1
    # No _write_state call → state file absent

    run run_ack "$PLAN_ID" 1

    [ "$status" -eq 0 ]
    [ -f "$NPS_TASKLISTS_HOME/$PLAN_ID/v1.json" ]
}

# ---------------------------------------------------------------------------
# Safety checks
# ---------------------------------------------------------------------------

@test "missing pending file: fails with clear error" {
    # No _write_pending call

    run run_ack "$PLAN_ID" 1

    [ "$status" -ne 0 ]
    echo "$output" | grep -qi "not found\|pending"
}

@test "already-acked version: fails when v{N}.json exists outside pending/" {
    # Create the acked file directly (simulates prior successful ack)
    mkdir -p "$NPS_TASKLISTS_HOME/$PLAN_ID"
    echo '{}' > "$NPS_TASKLISTS_HOME/$PLAN_ID/v1.json"
    # No pending file

    run run_ack "$PLAN_ID" 1

    [ "$status" -ne 0 ]
    echo "$output" | grep -qi "already acked\|already"
}

@test "missing plan.md: fails cleanly" {
    # Remove the plan.md created in setup
    rm -f "$NPS_PLANS_HOME/$PLAN_ID/plan.md"

    _write_pending 1

    run run_ack "$PLAN_ID" 1

    [ "$status" -ne 0 ]
    echo "$output" | grep -qi "plan\|not found"
}

@test "multiple pending versions: acts only on specified version, warns about higher" {
    # Both v1 and v2 pending; ack only v1
    _write_pending 1 null
    _write_pending 2 1

    run run_ack "$PLAN_ID" 1

    [ "$status" -eq 0 ]

    # v1 acked
    [ -f "$NPS_TASKLISTS_HOME/$PLAN_ID/v1.json" ]
    # v2 still pending
    [ -f "$NPS_TASKLISTS_HOME/$PLAN_ID/pending/v2.json" ]

    # Warning about higher pending version
    echo "$output" | grep -qi "higher\|1 higher\|pending"
}
