#!/usr/bin/env bats
# test_worktree_scope.bats — worktree isolation boundary tests.
#
# Verifies that dispatch correctly creates (and properly maps) git worktree
# isolation for any scope that lives inside a git repo — including non-git
# subdirectories that do not have a .git entry directly under them.
#
# The fix for #43 replaced a direct-child .git check with git rev-parse
# --show-toplevel (detect) and --show-prefix (map the subdir into the worktree).
# Tests 1-3 cover the core boundary; tests 4-7 cover the mapping and isolation.

load 'helpers/build-kit-tree.bash'

setup() {
    KIT_TMPDIR="$(mktemp -d)"
    build_kit_tree "$KIT_TMPDIR"
    run_spawner setup researcher-01 researcher
}

teardown() {
    rm -rf "${KIT_TMPDIR:-}"
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Build the standard outer-repo / subdir shape (one level deep).
# Sets OUTER_REPO and SCOPE_DIR in the caller's env.
_make_outer_repo() {
    OUTER_REPO="$KIT_TMPDIR/outer-repo"
    SCOPE_DIR="$OUTER_REPO/subdir"

    git init "$OUTER_REPO" -b main
    git -C "$OUTER_REPO" config user.email "test@test.local"
    git -C "$OUTER_REPO" config user.name "Test Runner"

    # Initial commit so HEAD exists and git commit works
    touch "$OUTER_REPO/existing-file.txt"
    git -C "$OUTER_REPO" add .
    git -C "$OUTER_REPO" commit -m "initial"

    # Create subdir AFTER the commit so it is not tracked on any branch.
    # This exercises the mkdir -p guard in the fix.
    mkdir -p "$SCOPE_DIR"
}

# Build a three-level-deep outer-repo / a/b/c shape.
# Sets OUTER_REPO and SCOPE_DIR in the caller's env.
_make_deep_outer_repo() {
    OUTER_REPO="$KIT_TMPDIR/outer-deep"
    SCOPE_DIR="$OUTER_REPO/a/b/c"

    git init "$OUTER_REPO" -b main
    git -C "$OUTER_REPO" config user.email "test@test.local"
    git -C "$OUTER_REPO" config user.name "Test Runner"

    touch "$OUTER_REPO/root-file.txt"
    git -C "$OUTER_REPO" add .
    git -C "$OUTER_REPO" commit -m "initial"

    mkdir -p "$SCOPE_DIR"
}

# ---------------------------------------------------------------------------
# Test 1: git-repo root scope → worktree IS created (regression / baseline)
# ---------------------------------------------------------------------------

@test "scope pointing directly at a git repo root creates a worktree" {
    _make_outer_repo

    export MOCK_CLAUDE_MODE=happy
    run_spawner dispatch researcher-01 "research task" \
        --scope "$OUTER_REPO" --budget 5000 --time-limit 60

    local wt_count
    wt_count=$(find "$KIT_WORKTREES" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
    [ "$wt_count" -ge 1 ]
}

# ---------------------------------------------------------------------------
# Test 2: non-git subdir scope → worktree IS created (fix verification)
#
# Before fix: the direct-child .git check missed subdirs, so wt_count == 0.
# After fix:  rev-parse detects the outer repo, so wt_count == 1.
# ---------------------------------------------------------------------------

@test "after fix: non-git subdir scope also creates a worktree" {
    _make_outer_repo

    export MOCK_CLAUDE_MODE=happy
    run_spawner dispatch researcher-01 "research task" \
        --scope "$SCOPE_DIR" --budget 5000 --time-limit 60

    local wt_count
    wt_count=$(find "$KIT_WORKTREES" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
    [ "$wt_count" -eq 1 ]
}

# ---------------------------------------------------------------------------
# Test 3: non-git subdir scope maps --add-dir to the correct subdir
#
# The fix must pass --add-dir $worktree/subdir, not --add-dir $worktree.
# A worker landing at the worktree root instead of the subdir would operate
# on files outside the intended scope.
# ---------------------------------------------------------------------------

@test "after fix: non-git subdir scope passes --add-dir pointing at the subdir inside the worktree" {
    _make_outer_repo

    export MOCK_CLAUDE_MODE=happy
    run_spawner dispatch researcher-01 "research task" \
        --scope "$SCOPE_DIR" --budget 5000 --time-limit 60

    # Locate the worktree created for this task
    local wt_path
    wt_path=$(find "$KIT_WORKTREES" -mindepth 1 -maxdepth 1 -type d | head -1)
    [ -n "$wt_path" ]

    # --add-dir must point at $wt_path/subdir, not the worktree root
    grep -qF -- "--add-dir $wt_path/subdir" "$MOCK_CLAUDE_ARGS_FILE"
}

# ---------------------------------------------------------------------------
# Test 4: subdir is created inside the worktree even when absent from HEAD
#
# subdir was mkdir-ed after the initial commit, so it is untracked. When the
# fix creates the worktree branch from HEAD, subdir does not exist there.
# The fix must mkdir -p it so the worker can operate in the expected location.
# ---------------------------------------------------------------------------

@test "after fix: scope subdir is created inside the worktree even when absent from the new branch" {
    _make_outer_repo

    export MOCK_CLAUDE_MODE=happy
    run_spawner dispatch researcher-01 "research task" \
        --scope "$SCOPE_DIR" --budget 5000 --time-limit 60

    local wt_path
    wt_path=$(find "$KIT_WORKTREES" -mindepth 1 -maxdepth 1 -type d | head -1)
    [ -n "$wt_path" ]

    # subdir must have been created inside the worktree
    [ -d "$wt_path/subdir" ]
}

# ---------------------------------------------------------------------------
# Test 5: commit via the worker's --add-dir lands on agent branch, not HEAD
#
# The commit_to_add_dir mock mode parses its own argv to find the --add-dir
# value and commits there. After the fix the --add-dir path is inside the
# isolated worktree, so the commit lands on the agent's branch and does NOT
# appear on the outer repo's main branch.
# ---------------------------------------------------------------------------

@test "after fix: commit in worker scope lands on agent branch not outer-repo HEAD" {
    _make_outer_repo

    export MOCK_CLAUDE_MODE=commit_to_add_dir
    run_spawner dispatch researcher-01 "research task" \
        --scope "$SCOPE_DIR" --budget 5000 --time-limit 60

    # The commit must NOT appear on outer-repo's main branch
    ! git -C "$OUTER_REPO" log --oneline main | grep -q "scope-escape-commit"

    # The commit MUST appear in the worktree (agent's branch)
    local wt_path
    wt_path=$(find "$KIT_WORKTREES" -mindepth 1 -maxdepth 1 -type d | head -1)
    [ -n "$wt_path" ]
    git -C "$wt_path" log --oneline | grep -q "scope-escape-commit"
}

# ---------------------------------------------------------------------------
# Test 6: deeply nested scope (outer-repo/a/b/c) maps correctly
#
# --show-prefix handles any depth. This test ensures the path mapping works
# for a three-level nested subdir, not just the one-level case.
# ---------------------------------------------------------------------------

@test "after fix: deeply nested non-git scope creates a worktree and maps path correctly" {
    _make_deep_outer_repo

    export MOCK_CLAUDE_MODE=happy
    run_spawner dispatch researcher-01 "research task" \
        --scope "$SCOPE_DIR" --budget 5000 --time-limit 60

    # Worktree must have been created
    local wt_count
    wt_count=$(find "$KIT_WORKTREES" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
    [ "$wt_count" -eq 1 ]

    local wt_path
    wt_path=$(find "$KIT_WORKTREES" -mindepth 1 -maxdepth 1 -type d | head -1)

    # --add-dir must reference the full nested subpath inside the worktree
    grep -qF -- "--add-dir $wt_path/a/b/c" "$MOCK_CLAUDE_ARGS_FILE"

    # The nested directory must have been created in the worktree
    [ -d "$wt_path/a/b/c" ]
}

# ---------------------------------------------------------------------------
# Test 7: default branch name is used for non-git subdir scope
#
# Regression: branch naming must work correctly when scope is a subdir, not
# just when it is the repo root. The branch should follow the agent/<id>/<tid>
# pattern and the branch must be reachable from the outer repo.
# ---------------------------------------------------------------------------

@test "after fix: non-git subdir scope uses default agent/<id>/<task-id> branch name" {
    _make_outer_repo

    export MOCK_CLAUDE_MODE=happy
    run_spawner dispatch researcher-01 "branch-name check" \
        --scope "$SCOPE_DIR" --budget 5000 --time-limit 60

    # Exactly one agent/researcher-01/* branch must exist on the outer repo
    local agent_count
    agent_count=$(git -C "$OUTER_REPO" for-each-ref --format='%(refname:short)' \
        'refs/heads/agent/researcher-01/*' 2>/dev/null | wc -l | tr -d ' ')
    [ "$agent_count" -eq 1 ]
}
