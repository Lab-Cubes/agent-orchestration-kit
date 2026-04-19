#!/usr/bin/env bats
# test_permissions.bats — Phase 2+4 realignment contract tests.
#
# Phase 2 (NPS-3/NIP alignment): CAPABILITIES in persona files must contain
# only NIP-level capabilities (nop:execute). Tool-level concepts (file:read,
# git:commit, web:search) are adapter-layer — they belong in the new
# ## RuntimePermissions documentation section, not the protocol field.
#
# Phase 4 (settings.json removal): cmd_setup must NOT generate .claude/
# directories or settings.json files. The allow/deny mechanism in Claude Code's
# permission matcher was found to be non-enforcing: broad allow rules dominate
# narrow deny rules, making persona-specific deny lists cosmetic. The worktree
# is the actual isolation boundary. See:
# memory/dev-sessions/knowledge/runtime-helper-experiment.md

load 'helpers/build-kit-tree.bash'

setup() {
    KIT_TMPDIR="$(mktemp -d)"
    build_kit_tree "$KIT_TMPDIR"
}

teardown() {
    rm -rf "${KIT_TMPDIR:-}"
}

# ---------------------------------------------------------------------------
# Phase 4: cmd_setup must not create .claude/ or settings.json.
# Generating settings.json was cosmetic — broad allow dominates narrow deny
# in Claude Code's permission matcher (verified empirically, session 004).
# ---------------------------------------------------------------------------

@test "coder setup does not create .claude directory" {
    run_spawner setup coder-01 coder
    [ ! -d "$KIT_AGENTS/coder-01/.claude" ]
}

@test "critic setup does not create .claude directory" {
    run_spawner setup critic-01 critic
    [ ! -d "$KIT_AGENTS/critic-01/.claude" ]
}

@test "researcher setup does not create .claude directory" {
    run_spawner setup researcher-01 researcher
    [ ! -d "$KIT_AGENTS/researcher-01/.claude" ]
}

# ---------------------------------------------------------------------------
# Phase 2: CAPABILITIES must be exactly 'nop:execute' in every persona.
# Anything beyond nop:execute is adapter-layer (tool concepts), not NIP
# protocol. Tool docs belong in ## RuntimePermissions.
# ---------------------------------------------------------------------------

@test "coder persona CAPABILITIES is exactly nop:execute" {
    grep -qE '^CAPABILITIES: nop:execute$' "$KIT_TEMPLATES/personas/coder.md"
}

@test "critic persona CAPABILITIES is exactly nop:execute" {
    grep -qE '^CAPABILITIES: nop:execute$' "$KIT_TEMPLATES/personas/critic.md"
}

@test "researcher persona CAPABILITIES is exactly nop:execute" {
    grep -qE '^CAPABILITIES: nop:execute$' "$KIT_TEMPLATES/personas/researcher.md"
}

# ---------------------------------------------------------------------------
# Phase 2: each persona must have a ## RuntimePermissions section.
# This section carries the human-readable tool concepts that were removed
# from CAPABILITIES, plus the allow/deny hints that formerly fed settings.json.
# ---------------------------------------------------------------------------

@test "coder persona has RuntimePermissions section" {
    grep -q '^## RuntimePermissions$' "$KIT_TEMPLATES/personas/coder.md"
}

@test "critic persona has RuntimePermissions section" {
    grep -q '^## RuntimePermissions$' "$KIT_TEMPLATES/personas/critic.md"
}

@test "researcher persona has RuntimePermissions section" {
    grep -q '^## RuntimePermissions$' "$KIT_TEMPLATES/personas/researcher.md"
}
