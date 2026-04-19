#!/usr/bin/env bats
# test_derive_budget_usd.bats — unit tests for scripts/lib/derive-budget-usd.py
#
# Verifies that category_usd_cap is treated as a CEILING (not the target),
# so that operator --budget values lower than the cap are honoured.

SCRIPT="$BATS_TEST_DIRNAME/../scripts/lib/derive-budget-usd.py"
FIXTURES="$BATS_TEST_DIRNAME/fixtures"

# ---------------------------------------------------------------------------
# (a) budget-derived < cap → budget wins
#     budget=40000 NPT, sonnet ($0.000025/NPT), overhead=$0.10, research cap=$2.00
#     derived = 40000 * 0.000025 + 0.10 = 1.10 < 2.00  → expect 1.10
# ---------------------------------------------------------------------------

@test "budget-derived below cap: budget value is used, not cap" {
    run python3 "$SCRIPT" 40000 "$FIXTURES/config-research-cap.json" sonnet research
    [ "$status" -eq 0 ]
    [ "$output" = "1.10" ]
}

# ---------------------------------------------------------------------------
# (b) budget-derived > cap → cap wins
#     budget=200000 NPT, sonnet, overhead=$0.10, code cap=$1.00
#     derived = 200000 * 0.000025 + 0.10 = 5.10 > 1.00  → expect 1.00
# ---------------------------------------------------------------------------

@test "budget-derived above cap: cap ceiling is applied" {
    run python3 "$SCRIPT" 200000 "$FIXTURES/config-code-cap.json" sonnet code
    [ "$status" -eq 0 ]
    [ "$output" = "1.00" ]
}

# ---------------------------------------------------------------------------
# (c) budget-derived below $0.50 floor → floor wins
#     budget=1000 NPT, sonnet, overhead=$0.10, test cap=$0.75
#     derived = 1000 * 0.000025 + 0.10 = 0.125; min(0.75, 0.125) = 0.125 < floor
#     → expect 0.50
# ---------------------------------------------------------------------------

@test "budget-derived below floor: floor of 0.50 is applied" {
    run python3 "$SCRIPT" 1000 "$FIXTURES/config-test-cap.json" sonnet test
    [ "$status" -eq 0 ]
    [ "$output" = "0.50" ]
}

# ---------------------------------------------------------------------------
# (d) no category_usd_cap in config → pure budget-derived used
#     budget=40000 NPT, sonnet, overhead=$0.10, no cap key in config
#     derived = 40000 * 0.000025 + 0.10 = 1.10  → expect 1.10
# ---------------------------------------------------------------------------

@test "no cap in config: pure budget-derived value is used" {
    run python3 "$SCRIPT" 40000 "$FIXTURES/config-no-cap.json" sonnet research
    [ "$status" -eq 0 ]
    [ "$output" = "1.10" ]
}

# ---------------------------------------------------------------------------
# (e) missing config file → fallback rate 0.000025, floor $0.50 still applies
#     budget=40000 NPT, fallback rate
#     derived = 40000 * 0.000025 = 1.00  → expect 1.00
# ---------------------------------------------------------------------------

@test "missing config file: fallback rate used and floor still applies" {
    run python3 "$SCRIPT" 40000 /nonexistent/config.json sonnet research
    [ "$status" -eq 0 ]
    [ "$output" = "1.00" ]
}
