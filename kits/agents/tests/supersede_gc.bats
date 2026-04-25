#!/usr/bin/env bats
# supersede_gc.bats — integration tests for spawn-agent.sh supersede-gc.
#
# Covers:
#   - --list shows superseded worktrees with branch and age
#   - --list with no worktrees prints empty message
#   - Default (no flags) = --list
#   - --dry-run prints without removing
#   - --older-than=999 skips recent worktrees
#   - --older-than=0 removes worktrees older than 0 days
#   - Safety: non-superseded branches never removed
#   - --plan-id scopes list to matching plan
#   - --plan-id scopes removal; other plan untouched
#   - Escalation event appended after removal
#   - --dry-run does not write escalation event
#   - --help shows all four flags
#
# Hard cap: 12 test cases.

load 'helpers/build-kit-tree.bash'

setup() {
    KIT_TMPDIR="$(mktemp -d)"
    build_kit_tree "$KIT_TMPDIR"

    REPOS_DIR="$KIT_TMPDIR/repos"
    mkdir -p "$REPOS_DIR"

    FIXTURE_ROOT="$KIT_TMPDIR/state"
    NPS_TASKLISTS_HOME="$FIXTURE_ROOT/task-lists"
    export NPS_TASKLISTS_HOME
}

teardown() {
    for repo in "$REPOS_DIR"/*/; do
        [[ -d "$repo" ]] && git -C "$repo" worktree prune 2>/dev/null || true
    done
    rm -rf "${KIT_TMPDIR:-}"
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

run_gc() {
    NPS_AGENTS_HOME="$KIT_AGENTS" \
    NPS_WORKTREES_HOME="$KIT_WORKTREES" \
    NPS_LOGS_HOME="$KIT_LOGS" \
    NPS_TASKLISTS_HOME="$NPS_TASKLISTS_HOME" \
    "$KIT_SCRIPTS/spawn-agent.sh" supersede-gc "$@"
}

# Create a git repo + worktree on a superseded/ branch.
# Sets: _REPO  _BRANCH  _WORKTREE
_make_superseded_wt() {
    local plan_id="$1" version="${2:-1}" agent_id="${3:-coder-01}" task_id="$4"
    local branch="superseded/${plan_id}/v${version}/${agent_id}/${task_id}"
    local repo="$REPOS_DIR/${plan_id}-${task_id}"
    mkdir -p "$repo"
    git init "$repo" -b main -q 2>/dev/null
    git -C "$repo" config user.email "test@example.com"
    git -C "$repo" config user.name "Test"
    touch "$repo/f.txt"
    git -C "$repo" add .
    git -C "$repo" commit -qm "init" 2>/dev/null
    git -C "$repo" worktree add -b "$branch" "$KIT_WORKTREES/${task_id}" 2>/dev/null
    _REPO="$repo"
    _BRANCH="$branch"
    _WORKTREE="$KIT_WORKTREES/${task_id}"
}

# Create a worktree on an active agent/ branch (never superseded).
_make_active_wt() {
    local agent_id="${1:-coder-01}" task_id="$2"
    local branch="agent/${agent_id}/${task_id}"
    local repo="$REPOS_DIR/active-${task_id}"
    mkdir -p "$repo"
    git init "$repo" -b main -q 2>/dev/null
    git -C "$repo" config user.email "test@example.com"
    git -C "$repo" config user.name "Test"
    touch "$repo/f.txt"
    git -C "$repo" add .
    git -C "$repo" commit -qm "init" 2>/dev/null
    git -C "$repo" worktree add -b "$branch" "$KIT_WORKTREES/${task_id}" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Tests (12 cases)
# ---------------------------------------------------------------------------

@test "--list shows superseded worktree with branch and age" {
    _make_superseded_wt "plan-abc" 1 coder-01 t-001
    run run_gc --list
    [ "$status" -eq 0 ]
    [[ "$output" == *"superseded/plan-abc/v1/coder-01/t-001"* ]]
    [[ "$output" == *"age="* ]]
}

@test "--list with no superseded worktrees prints empty message" {
    run run_gc --list
    [ "$status" -eq 0 ]
    [[ "$output" == *"no superseded worktrees"* ]]
}

@test "default (no flags) behaves as --list" {
    _make_superseded_wt "plan-def" 1 coder-01 t-002
    run run_gc
    [ "$status" -eq 0 ]
    [[ "$output" == *"superseded/plan-def/v1/coder-01/t-002"* ]]
}

@test "--dry-run with --older-than=0 prints removal message without removing" {
    _make_superseded_wt "plan-ghi" 1 coder-01 t-003
    touch -m -t 202001010000 "$KIT_WORKTREES/t-003"
    run run_gc --older-than=0 --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"[dry-run]"* ]]
    [[ "$output" == *"t-003"* ]]
    [[ -d "$KIT_WORKTREES/t-003" ]]
}

@test "--older-than=999 skips recently-created worktree" {
    _make_superseded_wt "plan-jkl" 1 coder-01 t-004
    run run_gc --older-than=999
    [ "$status" -eq 0 ]
    [[ -d "$KIT_WORKTREES/t-004" ]]
}

@test "--older-than=0 removes worktrees older than 0 days" {
    _make_superseded_wt "plan-mno" 1 coder-01 t-005
    touch -m -t 202001010000 "$KIT_WORKTREES/t-005"
    run run_gc --older-than=0
    [ "$status" -eq 0 ]
    [[ ! -d "$KIT_WORKTREES/t-005" ]]
}

@test "safety: non-superseded branch never removed even with --older-than=0" {
    _make_active_wt coder-01 t-006
    touch -m -t 202001010000 "$KIT_WORKTREES/t-006"
    run run_gc --older-than=0
    [ "$status" -eq 0 ]
    [[ -d "$KIT_WORKTREES/t-006" ]]
}

@test "--plan-id scopes list to matching plan only" {
    _make_superseded_wt "plan-p1" 1 coder-01 t-007
    _make_superseded_wt "plan-p2" 1 coder-01 t-008
    run run_gc --list --plan-id=plan-p1
    [ "$status" -eq 0 ]
    [[ "$output" == *"t-007"* ]]
    [[ "$output" != *"t-008"* ]]
}

@test "--plan-id scopes removal to matching plan; other plan untouched" {
    _make_superseded_wt "plan-q1" 1 coder-01 t-009
    _make_superseded_wt "plan-q2" 1 coder-01 t-010
    touch -m -t 202001010000 "$KIT_WORKTREES/t-009"
    touch -m -t 202001010000 "$KIT_WORKTREES/t-010"
    run run_gc --older-than=0 --plan-id=plan-q1
    [ "$status" -eq 0 ]
    [[ ! -d "$KIT_WORKTREES/t-009" ]]
    [[ -d "$KIT_WORKTREES/t-010" ]]
}

@test "escalation event written to plan escalation.jsonl after removal" {
    _make_superseded_wt "plan-evt" 1 coder-01 t-011
    touch -m -t 202001010000 "$KIT_WORKTREES/t-011"
    run run_gc --older-than=0
    [ "$status" -eq 0 ]
    local log="$NPS_TASKLISTS_HOME/plan-evt/escalation.jsonl"
    [[ -f "$log" ]]
    grep -q '"dispatcher_acted": "supersede_gc"' "$log"
}

@test "--dry-run does not write escalation event" {
    _make_superseded_wt "plan-noevt" 1 coder-01 t-012
    touch -m -t 202001010000 "$KIT_WORKTREES/t-012"
    run run_gc --older-than=0 --dry-run
    [ "$status" -eq 0 ]
    [[ ! -f "$NPS_TASKLISTS_HOME/plan-noevt/escalation.jsonl" ]]
}

@test "--help lists all four flags" {
    run run_gc --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"--list"* ]]
    [[ "$output" == *"--older-than"* ]]
    [[ "$output" == *"--dry-run"* ]]
    [[ "$output" == *"--plan-id"* ]]
}
