#!/usr/bin/env bats
# test_missing_coverage.bats — tests for issue #40: cmd_merge, result.json
# schema, malformed intent, and sequential dispatch. #88: atomic-mv claim lock.

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

@test "#40 cmd_merge: fails cleanly on squash-merge conflict" {
    export MOCK_CLAUDE_MODE=happy

    local scope_repo="$KIT_TREE/conflict-repo"
    _init_repo "$scope_repo"
    git -C "$scope_repo" config user.email "t@t.local"
    git -C "$scope_repo" config user.name "t"

    # Commit a file on main that will become the conflict base
    echo "base" > "$scope_repo/conflict.txt"
    git -C "$scope_repo" add conflict.txt
    git -C "$scope_repo" -c user.email=t@t.local -c user.name=t commit -m "add conflict.txt" -q

    run_spawner setup coder-01 coder
    run_spawner dispatch coder-01 "conflict test" \
        --scope "$scope_repo" --category code --time-limit 60

    local branch_file task_id worktree
    branch_file=$(ls "$KIT_AGENTS/coder-01/done/"*.branch.json 2>/dev/null | head -1)
    [ -f "$branch_file" ]
    task_id=$(python3 -c "import json; print(json.load(open('$branch_file'))['task_id'])")
    worktree=$(python3 -c "import json; print(json.load(open('$branch_file'))['worktree'])")

    # Worker commits a change on the worktree branch
    echo "worker-line" > "$worktree/conflict.txt"
    git -C "$worktree" add conflict.txt
    git -C "$worktree" -c user.email=t@t.local -c user.name=t commit -m "worker change" -q

    # Conflicting commit on main after the branch point
    echo "main-conflicting-line" > "$scope_repo/conflict.txt"
    git -C "$scope_repo" add conflict.txt
    git -C "$scope_repo" -c user.email=t@t.local -c user.name=t commit -m "conflicting main change" -q

    run run_spawner merge "$task_id" --no-push
    [ "$status" -ne 0 ]
}

@test "#40 cmd_merge: fails with clear error when git identity missing" {
    export MOCK_CLAUDE_MODE=happy

    local scope_repo="$KIT_TREE/identity-repo"
    _init_repo "$scope_repo"
    git -C "$scope_repo" config user.email "t@t.local"
    git -C "$scope_repo" config user.name "t"

    run_spawner setup coder-01 coder
    run_spawner dispatch coder-01 "identity test" \
        --scope "$scope_repo" --category code --time-limit 60

    local branch_file task_id worktree
    branch_file=$(ls "$KIT_AGENTS/coder-01/done/"*.branch.json 2>/dev/null | head -1)
    [ -f "$branch_file" ]
    task_id=$(python3 -c "import json; print(json.load(open('$branch_file'))['task_id'])")
    worktree=$(python3 -c "import json; print(json.load(open('$branch_file'))['worktree'])")

    echo "test" > "$worktree/file.txt"
    git -C "$worktree" add file.txt
    git -C "$worktree" -c user.email=t@t.local -c user.name=t commit -m "worker commit" -q

    # Remove local git identity; use an isolated HOME so global config can't rescue it
    git -C "$scope_repo" config --local --unset user.email 2>/dev/null || true
    git -C "$scope_repo" config --local --unset user.name 2>/dev/null || true
    mkdir -p "$KIT_TMPDIR/no-git-home"

    run env HOME="$KIT_TMPDIR/no-git-home" GIT_CONFIG_NOSYSTEM=1 \
        NPS_AGENTS_HOME="$KIT_AGENTS" NPS_WORKTREES_HOME="$KIT_WORKTREES" \
        NPS_LOGS_HOME="$KIT_LOGS" \
        "$KIT_SCRIPTS/spawn-agent.sh" merge "$task_id" --no-push
    [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# result.json schema
# ---------------------------------------------------------------------------

@test "#40 result.json: fallback has all required NOP fields" {
    export MOCK_CLAUDE_MODE=claim_no_result

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

@test "#205 result.json: mismatched payload.id marks error and fires failed hook" {
    export MOCK_CLAUDE_MODE=mismatched_result_id

    cat > "$KIT_HOOKS/on-task-completed.sh" <<HOOK
#!/usr/bin/env bash
touch "$KIT_TMPDIR/completed-hook-fired"
HOOK
    chmod +x "$KIT_HOOKS/on-task-completed.sh"
    cat > "$KIT_HOOKS/on-task-failed.sh" <<HOOK
#!/usr/bin/env bash
touch "$KIT_TMPDIR/failed-hook-fired"
HOOK
    chmod +x "$KIT_HOOKS/on-task-failed.sh"

    run_spawner setup coder-01 coder
    run_spawner dispatch coder-01 "mismatched result id" --category code --time-limit 60

    local status_field
    status_field=$(tail -n1 "$KIT_LOGS/dispatch-costs.csv" | awk -F',' '{gsub(/"/, "", $12); print $12}')
    [ "$status_field" = "error" ]
    [ -f "$KIT_TMPDIR/failed-hook-fired" ]
    [ ! -f "$KIT_TMPDIR/completed-hook-fired" ]
}

@test "#205 result.json: mismatched payload.from marks error and fires failed hook" {
    export MOCK_CLAUDE_MODE=mismatched_result_from

    cat > "$KIT_HOOKS/on-task-completed.sh" <<HOOK
#!/usr/bin/env bash
touch "$KIT_TMPDIR/completed-hook-fired"
HOOK
    chmod +x "$KIT_HOOKS/on-task-completed.sh"
    cat > "$KIT_HOOKS/on-task-failed.sh" <<HOOK
#!/usr/bin/env bash
touch "$KIT_TMPDIR/failed-hook-fired"
HOOK
    chmod +x "$KIT_HOOKS/on-task-failed.sh"

    run_spawner setup coder-01 coder
    run_spawner dispatch coder-01 "mismatched result sender" --category code --time-limit 60

    local status_field
    status_field=$(tail -n1 "$KIT_LOGS/dispatch-costs.csv" | awk -F',' '{gsub(/"/, "", $12); print $12}')
    [ "$status_field" = "error" ]
    [ -f "$KIT_TMPDIR/failed-hook-fired" ]
    [ ! -f "$KIT_TMPDIR/completed-hook-fired" ]
}

@test "#90 result.json: worker-written result missing required fields surfaces error status" {
    export MOCK_CLAUDE_MODE=malformed_result_missing_fields

    run_spawner setup coder-01 coder
    run_spawner dispatch coder-01 "malformed result" --category code --time-limit 60

    local status_field
    status_field=$(tail -n1 "$KIT_LOGS/dispatch-costs.csv" | awk -F',' '{gsub(/"/, "", $12); print $12}')
    [ "$status_field" = "error" ]
}

@test "#90 result.json: worker-written invalid JSON surfaces error status" {
    export MOCK_CLAUDE_MODE=malformed_result_invalid_json

    run_spawner setup coder-01 coder
    run_spawner dispatch coder-01 "invalid json result" --category code --time-limit 60

    local status_field
    status_field=$(tail -n1 "$KIT_LOGS/dispatch-costs.csv" | awk -F',' '{gsub(/"/, "", $12); print $12}')
    [ "$status_field" = "error" ]
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

# ---------------------------------------------------------------------------
# Concurrent dispatch — atomic-mv claim lock (#88)
# ---------------------------------------------------------------------------

@test "#88 concurrent dispatch: atomic-mv claim lock — exactly one winner" {
    local task_id="task-race-88-$$"
    local inbox="$KIT_AGENTS/coder-01/inbox"
    local active="$KIT_AGENTS/coder-01/active"
    local intent="$inbox/${task_id}.intent.json"
    local exit_a="$KIT_TMPDIR/race-exit-a"
    local exit_b="$KIT_TMPDIR/race-exit-b"

    run_spawner setup coder-01 coder

    # Pre-place a minimal NOP intent directly in inbox/ — bypassing cmd_dispatch
    # so both claimants see the SAME pending file (not two unique dispatches).
    cat > "$intent" << INTENT
{"_ncp":1,"type":"intent","intent":"race-test","confidence":1.0,"payload":{"_nop":1,"id":"${task_id}","from":"urn:nps:agent:test.localhost:overseer","to":"urn:nps:agent:test.localhost:coder-01","created_at":"2026-01-01T00:00:00Z","priority":"normal","category":"code","mailbox":{"base":"./"},"context":{},"constraints":{"model":"sonnet","time_limit":60,"scope":[],"budget_cgn":1000}}}
INTENT

    # Race: two subshells both attempt the claim rename concurrently.
    # POSIX rename(2) is atomic — exactly one will win regardless of timing.
    (mv "$intent" "$active/${task_id}.intent.json" 2>/dev/null \
        && echo 0 > "$exit_a" || echo 1 > "$exit_a") &
    (mv "$intent" "$active/${task_id}.intent.json" 2>/dev/null \
        && echo 0 > "$exit_b" || echo 1 > "$exit_b") &
    wait

    local code_a code_b
    code_a=$(cat "$exit_a")
    code_b=$(cat "$exit_b")

    # Exactly one mv succeeded (exit 0), the other saw "no such file" (exit 1)
    [ $((code_a + code_b)) -eq 1 ]

    # Exactly one intent file landed in active/
    local active_count
    active_count=$(ls "$active/"*.intent.json 2>/dev/null | wc -l | tr -d ' ')
    [ "$active_count" -eq 1 ]

    # The inbox is now empty — file was moved, not copied
    [ ! -f "$intent" ]
}
