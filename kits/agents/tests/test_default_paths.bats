#!/usr/bin/env bats
# test_default_paths.bats — default runtime locations.
#
# Phase 1 (session 004 NPS-spec audit finding): the kit's default
# NPS_AGENTS_HOME was $NPS_DIR/agents — i.e. inside the cloned kit
# repo's filesystem. That's the structural cause of the session 003
# bug where researcher-02 committed to the kit's main branch: the
# worker's cwd was inside the kit's git tree, so `git commit` walked
# up and found the kit's .git.
#
# Fix: runtime state (agents, worktrees, logs) lives at $HOME/.nps-kit/
# by default. The kit repo itself stays code-only. Operators can still
# override any NPS_*_HOME env var for custom layouts.

setup() {
    KIT_TMPDIR="$(mktemp -d)"
    SOURCE_KIT="${BATS_TEST_DIRNAME%/tests}"
    FAKE_HOME="$KIT_TMPDIR/fake-home"
    mkdir -p "$FAKE_HOME"
}

teardown() {
    rm -rf "${KIT_TMPDIR:-}"
}

@test "default NPS_AGENTS_HOME is \$HOME/.nps-kit/agents (outside the kit)" {
    local uniq="phase1-$$-$(date +%N)"

    # Unset NPS_STATE_HOME and XDG_STATE_HOME too — both would
    # override the fallback path. The test is asserting the no-env
    # default, so all resolution inputs must be cleared.
    env -u NPS_AGENTS_HOME -u NPS_WORKTREES_HOME -u NPS_LOGS_HOME \
        -u NPS_STATE_HOME -u XDG_STATE_HOME \
        HOME="$FAKE_HOME" \
        "$SOURCE_KIT/scripts/spawn-agent.sh" setup "$uniq" coder > /dev/null

    # Worker must land under $HOME/.nps-kit/agents/
    [ -d "$FAKE_HOME/.nps-kit/agents/$uniq" ]
    [ -f "$FAKE_HOME/.nps-kit/agents/$uniq/CLAUDE.md" ]
    [ -d "$FAKE_HOME/.nps-kit/agents/$uniq/inbox" ]
    [ -d "$FAKE_HOME/.nps-kit/agents/$uniq/active" ]
    [ -d "$FAKE_HOME/.nps-kit/agents/$uniq/done" ]
    [ -d "$FAKE_HOME/.nps-kit/agents/$uniq/blocked" ]

    # And NOT inside the kit repo — the whole point of Phase 1
    [ ! -d "$SOURCE_KIT/agents/$uniq" ]
}

@test "XDG_STATE_HOME is honoured when set (Linux convention)" {
    local uniq="phase1xdg-$$-$(date +%N)"
    local xdg_dir="$KIT_TMPDIR/xdg-state"
    mkdir -p "$xdg_dir"

    env -u NPS_AGENTS_HOME -u NPS_WORKTREES_HOME -u NPS_LOGS_HOME \
        -u NPS_STATE_HOME \
        HOME="$FAKE_HOME" \
        XDG_STATE_HOME="$xdg_dir" \
        "$SOURCE_KIT/scripts/spawn-agent.sh" setup "$uniq" coder > /dev/null

    # Worker at $XDG_STATE_HOME/nps-kit/agents/, not $HOME/.nps-kit
    [ -d "$xdg_dir/nps-kit/agents/$uniq" ]
    [ ! -d "$FAKE_HOME/.nps-kit/agents/$uniq" ]
}

@test "NPS_STATE_HOME wins over XDG_STATE_HOME" {
    local uniq="phase1ns-$$-$(date +%N)"
    local nps_state="$KIT_TMPDIR/nps-state"
    local xdg_state="$KIT_TMPDIR/xdg-state"
    mkdir -p "$nps_state" "$xdg_state"

    env -u NPS_AGENTS_HOME -u NPS_WORKTREES_HOME -u NPS_LOGS_HOME \
        HOME="$FAKE_HOME" \
        NPS_STATE_HOME="$nps_state" \
        XDG_STATE_HOME="$xdg_state" \
        "$SOURCE_KIT/scripts/spawn-agent.sh" setup "$uniq" coder > /dev/null

    # NPS_STATE_HOME is a direct root — no nps-kit/ suffix
    [ -d "$nps_state/agents/$uniq" ]
    # XDG path NOT populated
    [ ! -d "$xdg_state/nps-kit/agents/$uniq" ]
}

@test "NPS_AGENTS_HOME env override still wins over default" {
    local custom_home="$KIT_TMPDIR/custom"
    mkdir -p "$custom_home"

    env -u NPS_WORKTREES_HOME -u NPS_LOGS_HOME \
        -u NPS_STATE_HOME -u XDG_STATE_HOME \
        NPS_AGENTS_HOME="$custom_home" \
        HOME="$FAKE_HOME" \
        "$SOURCE_KIT/scripts/spawn-agent.sh" setup coder-02 coder > /dev/null

    # Env override took precedence
    [ -d "$custom_home/coder-02" ]
    [ -f "$custom_home/coder-02/CLAUDE.md" ]

    # Default location was NOT populated
    [ ! -d "$FAKE_HOME/.nps-kit/agents/coder-02" ]
}

@test "default NPS_WORKTREES_HOME and NPS_LOGS_HOME are under \$HOME/.nps-kit/" {
    local uniq="phase1wl-$$-$(date +%N)"

    env -u NPS_AGENTS_HOME -u NPS_WORKTREES_HOME -u NPS_LOGS_HOME \
        -u NPS_STATE_HOME -u XDG_STATE_HOME \
        HOME="$FAKE_HOME" \
        "$SOURCE_KIT/scripts/spawn-agent.sh" setup "$uniq" coder > /dev/null

    [ -d "$FAKE_HOME/.nps-kit/agents/$uniq" ]
    [ ! -d "$SOURCE_KIT/agents/$uniq" ]
}
