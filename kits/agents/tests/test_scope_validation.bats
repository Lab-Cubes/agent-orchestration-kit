#!/usr/bin/env bats
# test_scope_validation.bats — tests for bug #34: scope validation of
# files_changed in result.json after worker exits.

load 'helpers/build-kit-tree.bash'

setup() {
    KIT_TMPDIR="$(mktemp -d)"
    build_kit_tree "$KIT_TMPDIR"
}

teardown() {
    rm -rf "${KIT_TMPDIR:-}"
}

_init_scope_repo() {
    local repo="$1"
    mkdir -p "$repo/src"
    git -C "$repo" init -q -b main
    git -C "$repo" -c user.email=t@t.local -c user.name=t commit --allow-empty -m init -q
}

@test "#34 scope violation: files_changed outside scope triggers error status" {
    export MOCK_CLAUDE_MODE=scope_violation

    local scope_repo="$KIT_TREE/scope-repo"
    _init_scope_repo "$scope_repo"

    run_spawner setup coder-01 coder
    run run_spawner dispatch coder-01 "scope violation test" \
        --scope "$scope_repo" --category code --time-limit 60

    [ "$status" -eq 0 ]

    [ -f "$KIT_LOGS/dispatch-costs.csv" ]
    local status_field
    status_field=$(tail -n1 "$KIT_LOGS/dispatch-costs.csv" | awk -F',' '{gsub(/"/, "", $12); print $12}')
    [ "$status_field" = "error" ]

    local result_file
    result_file=$(ls "$KIT_AGENTS/coder-01/done/"*.result.json 2>/dev/null | head -1)
    [ -f "$result_file" ]

    run python3 -c "
import json
d = json.load(open('$result_file'))
assert d['payload'].get('_scope_violation') is True
assert d['payload']['status'] == 'failed'
print('ok')
"
    [ "$status" -eq 0 ]
}

@test "#34 scope clean: files_changed inside scope passes validation" {
    local scope_repo="$KIT_TREE/scope-repo"
    _init_scope_repo "$scope_repo"

    export MOCK_CLAUDE_MODE=scope_clean
    export MOCK_SCOPE_DIR="$scope_repo"

    run_spawner setup coder-01 coder
    run run_spawner dispatch coder-01 "scope clean test" \
        --scope "$scope_repo" --category code --time-limit 60

    [ "$status" -eq 0 ]

    local status_field
    status_field=$(tail -n1 "$KIT_LOGS/dispatch-costs.csv" | awk -F',' '{gsub(/"/, "", $12); print $12}')
    [ "$status_field" = "success" ]

    local result_file
    result_file=$(ls "$KIT_AGENTS/coder-01/done/"*.result.json 2>/dev/null | head -1)
    run python3 -c "
import json
d = json.load(open('$result_file'))
assert '_scope_violation' not in d['payload']
print('ok')
"
    [ "$status" -eq 0 ]
}

@test "#34 no scope: dispatch without --scope skips validation" {
    export MOCK_CLAUDE_MODE=happy

    run_spawner setup coder-01 coder
    run run_spawner dispatch coder-01 "no scope test" --category code --time-limit 60

    [ "$status" -eq 0 ]

    local status_field
    status_field=$(tail -n1 "$KIT_LOGS/dispatch-costs.csv" | awk -F',' '{gsub(/"/, "", $12); print $12}')
    [ "$status_field" = "success" ]
}
