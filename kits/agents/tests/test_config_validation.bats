#!/usr/bin/env bats
# test_config_validation.bats — tests for kits/agents/scripts/lib/validate_config.py

load 'helpers/build-kit-tree.bash'

VALIDATOR="$BATS_TEST_DIRNAME/../scripts/lib/validate_config.py"

setup() {
    KIT_TMPDIR="$(mktemp -d)"
    build_kit_tree "$KIT_TMPDIR"
}

teardown() {
    rm -rf "${KIT_TMPDIR:-}"
}

# ---------------------------------------------------------------------------
# 1. [REG GUARD] Valid minimal config — passes at RED and GREEN
# ---------------------------------------------------------------------------
@test "validator accepts a valid minimal config" {
    echo '{"issuer_domain":"example.com","issuer_agent_id":"op"}' > "$KIT_TMPDIR/cfg.json"
    run python3 "$VALIDATOR" "$KIT_TMPDIR/cfg.json"
    [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# 2. [REG GUARD] Invalid JSON — passes at RED and GREEN
# ---------------------------------------------------------------------------
@test "validator rejects a file that is not valid JSON" {
    echo 'not json' > "$KIT_TMPDIR/cfg.json"
    run python3 "$VALIDATOR" "$KIT_TMPDIR/cfg.json"
    [ "$status" -eq 1 ]
}

# ---------------------------------------------------------------------------
# 3. [BUG-PROVING] Missing issuer_domain — FAILS at RED, PASSES at GREEN
# ---------------------------------------------------------------------------
@test "validator rejects a config missing issuer_domain" {
    echo '{"issuer_agent_id":"op"}' > "$KIT_TMPDIR/cfg.json"
    run python3 "$VALIDATOR" "$KIT_TMPDIR/cfg.json"
    [ "$status" -eq 1 ]
}

# ---------------------------------------------------------------------------
# 4. [BUG-PROVING] Negative default_budget_npt — FAILS at RED, PASSES at GREEN
# ---------------------------------------------------------------------------
@test "validator rejects a negative default_budget_npt" {
    echo '{"issuer_domain":"x","issuer_agent_id":"y","default_budget_npt":-1}' > "$KIT_TMPDIR/cfg.json"
    run python3 "$VALIDATOR" "$KIT_TMPDIR/cfg.json"
    [ "$status" -eq 1 ]
}

# ---------------------------------------------------------------------------
# 5. [BUG-PROVING] Non-integer default_max_turns — FAILS at RED, PASSES at GREEN
# ---------------------------------------------------------------------------
@test "validator rejects a non-integer default_max_turns" {
    echo '{"issuer_domain":"x","issuer_agent_id":"y","default_max_turns":"lots"}' > "$KIT_TMPDIR/cfg.json"
    run python3 "$VALIDATOR" "$KIT_TMPDIR/cfg.json"
    [ "$status" -eq 1 ]
}

# ---------------------------------------------------------------------------
# 6. [BUG-PROVING] E2E: spawn-agent.sh aborts early with broken config
#    FAILS at RED (no-op validator passes; status fails for wrong reason),
#    PASSES at GREEN (validator catches missing issuer_domain, exits 1 immediately)
# ---------------------------------------------------------------------------
@test "dispatch aborts with validation error when config.json is broken" {
    echo '{"issuer_agent_id":"op"}' > "$KIT_TREE/config.json"
    local rc=0
    local out
    out="$(run_spawner status coder-01 2>&1)" || rc=$?
    [ "$rc" -ne 0 ]
    echo "$out" | grep -q "validation failed"
    echo "$out" | grep -q "issuer_domain"
}
