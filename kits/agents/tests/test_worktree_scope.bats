#!/usr/bin/env bats
# test_worktree_scope.bats — worktree isolation boundary tests.
#
# Verifies that dispatch correctly creates (or skips) git worktree isolation
# depending on the scope path, and that skipping worktree isolation when scope
# is a non-git subdir inside an outer repo allows a worker to commit directly
# to that outer repo's current branch (the vulnerability).

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

# Build the outer-repo / subdir shape used across several tests.
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

    mkdir -p "$SCOPE_DIR"
}

# ---------------------------------------------------------------------------
# Test 1: git-repo scope → worktree IS created (baseline / sanity check)
# ---------------------------------------------------------------------------

@test "scope pointing directly at a git repo root creates a worktree" {
    _make_outer_repo

    export MOCK_CLAUDE_MODE=happy
    run_spawner dispatch researcher-01 "research task" \
        --scope "$OUTER_REPO" --budget 5000 --time-limit 60

    # At least one entry in worktrees/ confirms isolation was set up
    local wt_count
    wt_count=$(find "$KIT_WORKTREES" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
    [ "$wt_count" -ge 1 ]
}

# ---------------------------------------------------------------------------
# Test 2: non-git subdir scope → no worktree created (confirms setup gap)
# ---------------------------------------------------------------------------

@test "scope pointing at a non-git subdir inside a git repo skips worktree creation" {
    _make_outer_repo

    export MOCK_CLAUDE_MODE=happy
    run_spawner dispatch researcher-01 "research task" \
        --scope "$SCOPE_DIR" --budget 5000 --time-limit 60

    # Worktrees dir must be empty — no isolation was set up
    local wt_count
    wt_count=$(find "$KIT_WORKTREES" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
    [ "$wt_count" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Test 3: real harm — worker commits to outer repo's HEAD via non-git scope
#
# This is the proof-of-harm test. The mock worker writes a file into SCOPE_DIR
# and runs git commit there. Because git traverses parent directories to find
# .git, the commit lands on OUTER_REPO's current branch — not in an isolated
# worktree branch. If this test passes, the vulnerability is confirmed real.
# ---------------------------------------------------------------------------

@test "worker with non-git subdir scope can commit directly to outer repo HEAD" {
    _make_outer_repo

    export MOCK_CLAUDE_MODE=commit_to_scope
    export MOCK_COMMIT_DIR="$SCOPE_DIR"

    run_spawner dispatch researcher-01 "research task" \
        --scope "$SCOPE_DIR" --budget 5000 --time-limit 60

    # The commit must appear on outer-repo's main branch (not in a worktree branch)
    git -C "$OUTER_REPO" log --oneline | grep -q "scope-escape-commit"
}
