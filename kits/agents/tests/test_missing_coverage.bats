#!/usr/bin/env bats
# test_missing_coverage.bats — tests for issue #40: cmd_merge, result.json
# schema, malformed intent, and sequential dispatch.

load 'helpers/build-kit-tree.bash'

setup() {
    KIT_TMPDIR="$(mktemp -d)"
    build_kit_tree "$KIT_TMPDIR"
}

teardown() {
    rm -rf "${KIT_TMPDIR:-}"
}

_init_repo() {
    local repo="$1"
    mkdir -p "$repo"
    git -C "$repo" init -q -b main
    git -C "$repo" -c user.email=t@t.local -c user.name=t commit --allow-empty -m init -q
}

# ---------------------------------------------------------------------------
# cmd_merge
# ---------------------------------------------------------------------------

@test "#40 cmd_merge: happy path squash-merges worktree branch" {
    export MOCK_CLAUDE_MODE=happy

    local scope_repo="$KIT_TREE/merge-repo"
    _init_repo "$scope_repo"
    git -C "$scope_repo" config user.email "t@t.local"
    git -C "$scope_repo" config user.name "t"

    run_spawner setup coder-01 coder
    run_spawner dispatch coder-01 "merge happy path" \
        --scope "$scope_repo" --category code --time-limit 60

    local branch_file
    branch_file=$(ls "$KIT_AGENTS/coder-01/done/"*.branch.json 2>/dev/null | head -1)
    [ -f "$branch_file" ]

    local task_id branch worktree
    task_id=$(python3 -c "import json; print(json.load(open('$branch_file'))['task_id'])")
    branch=$(python3 -c "import json; print(json.load(open('$branch_file'))['branch'])")
    worktree=$(python3 -c "import json; print(json.load(open('$branch_file'))['worktree'])")

    echo "test content" > "$worktree/test-file.txt"
    git -C "$worktree" add test-file.txt
    git -C "$worktree" -c user.email=t@t.local -c user.name=t commit -m "worker commit" -q

    run run_spawner merge "$task_id" --no-push
    [ "$status" -eq 0 ]

    git -C "$scope_repo" log --oneline main | grep -q "squash(coder-01)"
}

@test "#40 cmd_merge: fails with missing branch metadata" {
    run run_spawner merge "task-nonexistent-20260101-000000"
    [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# result.json schema
# ---------------------------------------------------------------------------

@test "#40 result.json: fallback has all required NOP fields" {
    export MOCK_CLAUDE_MODE=happy

    run_spawner setup coder-01 coder
    run_spawner dispatch coder-01 "schema check" --category code --time-limit 60

    local result_file
    result_file=$(ls "$KIT_AGENTS/coder-01/done/"*.result.json 2>/dev/null | head -1)
    [ -f "$result_file" ]

    run python3 -c "
import json
d = json.load(open('$result_file'))
assert d['_ncp'] == 1
assert d['type'] == 'result'
assert 'value' in d
assert 'probability' in d
p = d['payload']
assert p['_nop'] == 1
assert 'id' in p
assert p['status'] in ('completed','failed','timeout','blocked','cancelled')
assert 'from' in p
assert 'picked_up_at' in p
assert 'completed_at' in p
print('ok')
"
    [ "$status" -eq 0 ]
}

@test "#40 result.json: payload.id matches intent task id" {
    export MOCK_CLAUDE_MODE=happy

    run_spawner setup coder-01 coder
    run_spawner dispatch coder-01 "id match" --category code --time-limit 60

    local result_file
    result_file=$(ls "$KIT_AGENTS/coder-01/done/"*.result.json 2>/dev/null | head -1)
    [ -f "$result_file" ]

    local expected_id
    expected_id=$(basename "$result_file" .result.json)

    run python3 -c "
import json
d = json.load(open('$result_file'))
assert d['payload']['id'] == '$expected_id'
print('ok')
"
    [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Sequential dispatch uniqueness
# ---------------------------------------------------------------------------

@test "#40 sequential dispatches create unique task ids" {
    export MOCK_CLAUDE_MODE=happy

    run_spawner setup coder-01 coder
    run_spawner dispatch coder-01 "task one" --category code --time-limit 60
    sleep 1
    run_spawner dispatch coder-01 "task two" --category code --time-limit 60

    local count
    count=$(ls "$KIT_AGENTS/coder-01/done/"*.result.json 2>/dev/null | wc -l | tr -d ' ')
    [ "$count" -eq 2 ]

    local csv_rows
    csv_rows=$(wc -l < "$KIT_LOGS/dispatch-costs.csv" | tr -d ' ')
    [ "$csv_rows" -eq 3 ]
}
