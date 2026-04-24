#!/usr/bin/env bats
# test_context_capacity.bats — tests for #56: context_capacity field in result.json

load 'helpers/build-kit-tree.bash'

setup() {
    KIT_TMPDIR="$(mktemp -d)"
    build_kit_tree "$KIT_TMPDIR"
}

teardown() {
    rm -rf "${KIT_TMPDIR:-}"
}

@test "#56 nop-types.ts exports ContextCapacity type" {
    local source_kit="${BATS_TEST_DIRNAME%/tests}"
    grep -q 'export type ContextCapacity' "$source_kit/src/nop-types.ts"
}

@test "#56 NopResultPayload has optional context_capacity field" {
    local source_kit="${BATS_TEST_DIRNAME%/tests}"
    grep -q 'context_capacity.*ContextCapacity' "$source_kit/src/nop-types.ts"
}

@test "#56 types.ts re-exports ContextCapacity" {
    local source_kit="${BATS_TEST_DIRNAME%/tests}"
    grep -q 'ContextCapacity' "$source_kit/src/types.ts"
}

@test "#56 AGENT-CLAUDE.md instructs workers to report context_capacity" {
    grep -q 'context_capacity' "$KIT_TEMPLATES/AGENT-CLAUDE.md"
}

@test "#56 context_capacity is optional — result without it is valid" {
    # Verify the type definition allows omission (the ? in context_capacity?)
    local source_kit="${BATS_TEST_DIRNAME%/tests}"
    grep -q 'context_capacity?' "$source_kit/src/nop-types.ts"
}
