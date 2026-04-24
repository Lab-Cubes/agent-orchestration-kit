#!/usr/bin/env bats
# schemas.bats — smoke tests for phased-dispatch JSON Schema documents.
#
# Validates the architecture.md §4 example instances against the four schemas
# in src/schemas/. Requires python3 + jsonschema>=4.18 to be installed.
#
# Install deps:
#   pip install "jsonschema[format-nongpl]>=4.18"
#
# Run:
#   bats kits/agents/tests/schemas.bats

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
SCHEMA_DIR="$REPO_ROOT/kits/agents/src/schemas"
FIXTURES_DIR="$REPO_ROOT/kits/agents/tests/fixtures/schemas"
VALIDATOR="$REPO_ROOT/kits/agents/scripts/lib/validate_schema.py"

setup() {
    # Fail fast if jsonschema is not importable — tell the reader how to fix it.
    if ! python3 -c "import jsonschema" 2>/dev/null; then
        echo "SKIP: jsonschema package not installed." >&2
        echo "Install with: pip install \"jsonschema[format-nongpl]>=4.18\"" >&2
        skip
    fi
}

# ---------------------------------------------------------------------------
# task-list.schema.json
# ---------------------------------------------------------------------------

@test "task-list: valid instance (architecture.md §4.2 example) passes" {
    run python3 "$VALIDATOR" \
        "$SCHEMA_DIR/task-list.schema.json" \
        "$FIXTURES_DIR/task-list-valid.json"

    [ "$status" -eq 0 ]
}

@test "task-list: extra field in dag object triggers additionalProperties rejection" {
    run python3 "$VALIDATOR" \
        "$SCHEMA_DIR/task-list.schema.json" \
        "$FIXTURES_DIR/task-list-bad-enum.json"

    [ "$status" -eq 1 ]
}

@test "task-list: missing required fields (version_id, dag, etc.) fails" {
    run python3 "$VALIDATOR" \
        "$SCHEMA_DIR/task-list.schema.json" \
        "$FIXTURES_DIR/task-list-missing-required.json"

    [ "$status" -eq 1 ]
}

# ---------------------------------------------------------------------------
# task-list-state.schema.json
# ---------------------------------------------------------------------------

@test "task-list-state: valid instance (architecture.md §4.3 example) passes" {
    run python3 "$VALIDATOR" \
        "$SCHEMA_DIR/task-list-state.schema.json" \
        "$FIXTURES_DIR/task-list-state-valid.json"

    [ "$status" -eq 0 ]
}

@test "task-list-state: invalid NodeState.status enum value fails" {
    run python3 "$VALIDATOR" \
        "$SCHEMA_DIR/task-list-state.schema.json" \
        "$FIXTURES_DIR/task-list-state-bad-status.json"

    [ "$status" -eq 1 ]
}

# ---------------------------------------------------------------------------
# escalation-event.schema.json
# ---------------------------------------------------------------------------

@test "escalation-event: valid instance (architecture.md §4.4 example) passes" {
    run python3 "$VALIDATOR" \
        "$SCHEMA_DIR/escalation-event.schema.json" \
        "$FIXTURES_DIR/escalation-event-valid.json"

    [ "$status" -eq 0 ]
}

@test "escalation-event: invalid osi_ack_verdict enum value fails" {
    run python3 "$VALIDATOR" \
        "$SCHEMA_DIR/escalation-event.schema.json" \
        "$FIXTURES_DIR/escalation-event-bad-verdict.json"

    [ "$status" -eq 1 ]
}

# ---------------------------------------------------------------------------
# plan-frontmatter.schema.json
# ---------------------------------------------------------------------------

@test "plan-frontmatter: valid instance (architecture.md §4.1 frontmatter as JSON) passes" {
    run python3 "$VALIDATOR" \
        "$SCHEMA_DIR/plan-frontmatter.schema.json" \
        "$FIXTURES_DIR/plan-frontmatter-valid.json"

    [ "$status" -eq 0 ]
}

@test "plan-frontmatter: invalid status enum value fails" {
    run python3 "$VALIDATOR" \
        "$SCHEMA_DIR/plan-frontmatter.schema.json" \
        "$FIXTURES_DIR/plan-frontmatter-bad-status.json"

    [ "$status" -eq 1 ]
}

# ---------------------------------------------------------------------------
# task-list fixture corpus (tests/fixtures/task-lists/)
# ---------------------------------------------------------------------------

@test "task-list fixtures: all five canonical shapes validate against schema" {
    local tl_fixtures="$REPO_ROOT/kits/agents/tests/fixtures/task-lists"
    local schema="$SCHEMA_DIR/task-list.schema.json"
    local failed=0
    for f in "$tl_fixtures"/*.json; do
        if ! python3 "$VALIDATOR" "$schema" "$f" 2>/dev/null; then
            echo "FAIL: $f" >&3
            failed=$(( failed + 1 ))
        fi
    done
    [ "$failed" -eq 0 ]
}

# ---------------------------------------------------------------------------
# plan-frontmatter (continued)
# ---------------------------------------------------------------------------

@test "plan-frontmatter: missing required field (title) fails" {
    run python3 -c "
import json, tempfile, os, sys
d = json.load(open('$FIXTURES_DIR/plan-frontmatter-valid.json'))
del d['title']
tmp = tempfile.NamedTemporaryFile(mode='w', suffix='.json', delete=False)
json.dump(d, tmp)
tmp.close()
print(tmp.name)
"
    [ "$status" -eq 0 ]
    local tmpfile="$output"

    run python3 "$VALIDATOR" \
        "$SCHEMA_DIR/plan-frontmatter.schema.json" \
        "$tmpfile"

    rm -f "$tmpfile"
    [ "$status" -eq 1 ]
}
