#!/usr/bin/env bash
# build-kit-tree.bash — shared helper for integration tests
#
# Load this from a .bats file with `load 'helpers/build-kit-tree.bash'`
# then call `build_kit_tree "$BATS_TMPDIR_UNIQUE"` inside setup().
#
# Creates an isolated kit tree under the given directory, copies the real
# scripts/ and templates/ in, drops a minimal NPT-only config fixture, and
# prepends the mock Claude CLI (kits/agents/tests/bin/) to PATH.
#
# Exports:
#   KIT_TREE       — root of the isolated kit
#   KIT_SCRIPTS    — $KIT_TREE/scripts
#   KIT_AGENTS     — $KIT_TREE/agents
#   KIT_WORKTREES  — $KIT_TREE/worktrees
#   KIT_LOGS       — $KIT_TREE/logs
#   KIT_HOOKS      — $KIT_TREE/hooks
#   KIT_TEMPLATES  — $KIT_TREE/templates
#   MOCK_CLAUDE_ARGS_FILE — log of args passed to mock claude

build_kit_tree() {
    local tmpdir="$1"

    # kits/agents/tests/ → kits/agents
    local tests_dir="$BATS_TEST_DIRNAME"
    local source_kit="${tests_dir%/tests}"

    KIT_TREE="$tmpdir/kit"
    KIT_SCRIPTS="$KIT_TREE/scripts"
    KIT_AGENTS="$KIT_TREE/agents"
    KIT_WORKTREES="$KIT_TREE/worktrees"
    KIT_LOGS="$KIT_TREE/logs"
    KIT_HOOKS="$KIT_TREE/hooks"
    KIT_TEMPLATES="$KIT_TREE/templates"

    mkdir -p "$KIT_SCRIPTS" "$KIT_AGENTS" "$KIT_WORKTREES" "$KIT_LOGS" "$KIT_HOOKS"

    # Copy scripts from the real kit
    cp "$source_kit/scripts/spawn-agent.sh" "$KIT_SCRIPTS/"
    chmod +x "$KIT_SCRIPTS/spawn-agent.sh"
    cp -r "$source_kit/scripts/lib" "$KIT_SCRIPTS/"

    # Copy templates (AGENT-CLAUDE.md + personas/) from the real kit
    cp -r "$source_kit/templates" "$KIT_TEMPLATES"

    # Drop minimal NPT-only config
    cp "$tests_dir/fixtures/config-minimal.json" "$KIT_TREE/config.json"

    # Mock Claude CLI — prepend its dir to PATH
    MOCK_CLAUDE_ARGS_FILE="$tmpdir/claude-args.log"
    : > "$MOCK_CLAUDE_ARGS_FILE"
    export MOCK_CLAUDE_ARGS_FILE
    export PATH="$tests_dir/bin:$PATH"

    export KIT_TREE KIT_SCRIPTS KIT_AGENTS KIT_WORKTREES KIT_LOGS KIT_HOOKS KIT_TEMPLATES
}

# Run spawn-agent.sh with the isolated-tree env overrides baked in.
# Usage: run_spawner <command> [args...]
run_spawner() {
    NPS_AGENTS_HOME="$KIT_AGENTS" \
    NPS_WORKTREES_HOME="$KIT_WORKTREES" \
    NPS_LOGS_HOME="$KIT_LOGS" \
    "$KIT_SCRIPTS/spawn-agent.sh" "$@"
}
