#!/usr/bin/env bats
# test_runtime_adapter.bats — tests for #57 adapter layer + Kiro CLI adapter

load 'helpers/build-kit-tree.bash'

setup() {
    KIT_TMPDIR="$(mktemp -d)"
    build_kit_tree "$KIT_TMPDIR"
}

teardown() {
    rm -rf "${KIT_TMPDIR:-}"
}

# ---------------------------------------------------------------------------
# Adapter layer exists
# ---------------------------------------------------------------------------

@test "#57 adapter base class exists" {
    local source_kit="${BATS_TEST_DIRNAME%/tests}"
    [ -f "$source_kit/scripts/lib/adapters/__init__.py" ]
    grep -q 'class AdapterBase' "$source_kit/scripts/lib/adapters/__init__.py"
}

@test "#57 claude adapter exists and extends AdapterBase" {
    local source_kit="${BATS_TEST_DIRNAME%/tests}"
    [ -f "$source_kit/scripts/lib/adapters/claude.py" ]
    grep -q 'class ClaudeAdapter' "$source_kit/scripts/lib/adapters/claude.py"
}

@test "#57 kiro adapter exists and extends AdapterBase" {
    local source_kit="${BATS_TEST_DIRNAME%/tests}"
    [ -f "$source_kit/scripts/lib/adapters/kiro.py" ]
    grep -q 'class KiroAdapter' "$source_kit/scripts/lib/adapters/kiro.py"
}

# ---------------------------------------------------------------------------
# --runtime flag
# ---------------------------------------------------------------------------

@test "#57 --runtime kiro uses kiro-cli mock and captures output" {
    export MOCK_CLAUDE_MODE=happy

    run_spawner setup coder-01 coder
    run run_spawner dispatch coder-01 "kiro runtime test" \
        --runtime kiro --category code --time-limit 60

    [ "$status" -eq 0 ]

    # kiro-cli should have been invoked
    grep -q "kiro-cli" "$MOCK_CLAUDE_ARGS_FILE"

    # result.json should contain the worker's output (not empty)
    local result_file
    result_file=$(ls "$KIT_AGENTS/coder-01/done/"*.result.json 2>/dev/null | head -1)
    [ -f "$result_file" ]

    run python3 -c "
import json
d = json.load(open('$result_file'))
v = d.get('value', '') or d.get('payload', {}).get('value', '')
assert 'Kiro worker completed' in v or 'models.py' in v, \
    f'result value should contain mock output, got: {v!r}'
print('ok')
"
    [ "$status" -eq 0 ]
}

@test "#57 --runtime claude uses claude mock (default)" {
    export MOCK_CLAUDE_MODE=happy

    run_spawner setup coder-01 coder
    run run_spawner dispatch coder-01 "claude runtime test" \
        --category code --time-limit 60

    [ "$status" -eq 0 ]

    # CSV should have a data row
    [ -f "$KIT_LOGS/dispatch-costs.csv" ]
    local rows
    rows=$(wc -l < "$KIT_LOGS/dispatch-costs.csv" | tr -d ' ')
    [ "$rows" -eq 2 ]
}

@test "#57 --runtime invalid exits with error" {
    run_spawner setup coder-01 coder
    run run_spawner dispatch coder-01 "bad runtime test" \
        --runtime bogus --category code --time-limit 60

    [ "$status" -ne 0 ]
}

@test "#57 config.example.json has runtime field" {
    local source_kit="${BATS_TEST_DIRNAME%/tests}"
    grep -q '"runtime"' "$source_kit/config.example.json"
}

@test "#57 all files in bin/ and tests/bin/ are executable" {
    local source_kit="${BATS_TEST_DIRNAME%/tests}"
    local fail=0
    for f in "$source_kit"/bin/* "$source_kit"/tests/bin/*; do
        [ -x "$f" ] || { echo "not executable: $f"; fail=1; }
    done
    [ "$fail" -eq 0 ]
}
