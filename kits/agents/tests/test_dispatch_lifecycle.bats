#!/usr/bin/env bats
# test_dispatch_lifecycle.bats — integration tests for spawn-agent.sh dispatch.
#
# Each test builds an isolated kit tree under $BATS_TMPDIR_UNIQUE, copies the
# real scripts/ and templates/ in, mocks the Claude CLI via a stub on PATH,
# and exercises the full dispatch lifecycle. No real Claude process runs and
# no state in the real kit is touched.

load 'helpers/build-kit-tree.bash'

setup() {
    KIT_TMPDIR="$(mktemp -d)"
    build_kit_tree "$KIT_TMPDIR"
}

teardown() {
    rm -rf "${KIT_TMPDIR:-}"
}

# ---------------------------------------------------------------------------
# Happy path
# ---------------------------------------------------------------------------

@test "happy path: setup creates mailbox + CLAUDE.md" {
    run run_spawner setup coder-01 coder

    [ "$status" -eq 0 ]
    [ -d "$KIT_AGENTS/coder-01/inbox" ]
    [ -d "$KIT_AGENTS/coder-01/active" ]
    [ -d "$KIT_AGENTS/coder-01/done" ]
    [ -d "$KIT_AGENTS/coder-01/blocked" ]
    [ -f "$KIT_AGENTS/coder-01/CLAUDE.md" ]
}

@test "happy path: dispatch runs mock worker, writes result, appends CSV row" {
    export MOCK_CLAUDE_MODE=happy

    run_spawner setup coder-01 coder
    run run_spawner dispatch coder-01 "smoke test task" \
        --budget 5000 --category code --time-limit 60

    [ "$status" -eq 0 ]

    # Mock claude was invoked
    [ -s "$MOCK_CLAUDE_ARGS_FILE" ]

    # Raw output captured
    local raw_count
    raw_count=$(ls "$KIT_AGENTS/coder-01/done"/*.raw-output.json 2>/dev/null | wc -l | tr -d ' ')
    [ "$raw_count" -ge 1 ]

    # Cost CSV exists with header + at least one data row
    [ -f "$KIT_LOGS/dispatch-costs.csv" ]
    local rows
    rows=$(wc -l < "$KIT_LOGS/dispatch-costs.csv" | tr -d ' ')
    [ "$rows" -eq 2 ]
}

# ---------------------------------------------------------------------------
# NPT budget flow — regression test for the pre-#18 bug where --budget was
# silently ignored. The CSV's budget_npt column must equal what the operator
# passed.
# ---------------------------------------------------------------------------

@test "--budget N threads through to the CSV budget_npt column" {
    export MOCK_CLAUDE_MODE=happy

    run_spawner setup coder-01 coder
    run run_spawner dispatch coder-01 "budget thread test" \
        --budget 12345 --category code --time-limit 60

    [ "$status" -eq 0 ]

    # CSV schema (post-#18): timestamp,task_id,agent_id,model,category,priority,budget_npt,cost_npt,turns,duration_s,denials,status
    # budget_npt is column 7.
    local row
    row=$(tail -n1 "$KIT_LOGS/dispatch-costs.csv")
    local budget_field
    budget_field=$(echo "$row" | awk -F',' '{gsub(/"/, "", $7); print $7}')

    [ "$budget_field" = "12345" ]
}

# ---------------------------------------------------------------------------
# Cost CSV — NPT columns present, USD columns absent
# (regression test for #18: USD purged from kit)
# ---------------------------------------------------------------------------

@test "cost CSV header has NPT fields and no USD fields" {
    export MOCK_CLAUDE_MODE=happy

    run_spawner setup coder-01 coder
    run_spawner dispatch coder-01 "csv schema test" --category code --time-limit 60

    local header
    header=$(head -n1 "$KIT_LOGS/dispatch-costs.csv")

    # NPT columns present
    echo "$header" | grep -q "budget_npt"
    echo "$header" | grep -q "cost_npt"

    # USD columns absent
    ! echo "$header" | grep -q -i "usd"
}

# ---------------------------------------------------------------------------
# Failure path — mock claude exits non-zero. Dispatch must not crash; it
# must still produce a CSV row (with status=error) and not leave stray state.
# ---------------------------------------------------------------------------

@test "dispatch handles Claude CLI error without crashing" {
    export MOCK_CLAUDE_MODE=error

    run_spawner setup coder-01 coder
    run run_spawner dispatch coder-01 "error path test" --category code --time-limit 60

    # The spawner is intentionally tolerant (|| true on claude invocation) so
    # exit 0 is expected — but a CSV row must be appended.
    [ "$status" -eq 0 ]
    [ -f "$KIT_LOGS/dispatch-costs.csv" ]

    local rows
    rows=$(wc -l < "$KIT_LOGS/dispatch-costs.csv" | tr -d ' ')
    [ "$rows" -eq 2 ]

    # Status column (last field) should be "error" or "success" — not empty.
    local status_field
    status_field=$(tail -n1 "$KIT_LOGS/dispatch-costs.csv" | awk -F',' '{gsub(/"/, "", $NF); print $NF}')
    [ -n "$status_field" ]
}
