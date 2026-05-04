#!/usr/bin/env bats
# test_hooks.bats — unit tests for on-task-claimed.sh, on-task-completed.sh, on-task-failed.sh
#
# Strategy A (arg capture): place a mock _post.sh alongside the hooks so we can
# verify which event name each hook passes.
#
# Strategy B (real _post.sh, no config): verify that a missing config.json causes
# exit 0 — hooks must never block the worker.

PLUGIN_SRC="$BATS_TEST_DIRNAME/.."
FIXTURES="$BATS_TEST_DIRNAME/fixtures"

# ---------------------------------------------------------------------------
# Strategy A: hook dir with MOCK _post.sh that records its args
# ---------------------------------------------------------------------------

setup_mock_dir() {
    HOOK_TMPDIR="$(mktemp -d)"
    for hook in on-task-claimed.sh on-task-completed.sh on-task-failed.sh; do
        cp "$PLUGIN_SRC/$hook" "$HOOK_TMPDIR/$hook"
        chmod +x "$HOOK_TMPDIR/$hook"
    done

    CAPTURED_ARGS_FILE="$HOOK_TMPDIR/captured_args"
    > "$CAPTURED_ARGS_FILE"
    export CAPTURED_ARGS_FILE

    # Mock _post.sh: records argv[1] (the event name) and exits 0
    cat > "$HOOK_TMPDIR/_post.sh" << 'EOF'
#!/usr/bin/env bash
echo "$1" >> "${CAPTURED_ARGS_FILE}"
exit 0
EOF
    chmod +x "$HOOK_TMPDIR/_post.sh"
}

# ---------------------------------------------------------------------------
# Strategy B: hook dir with REAL _post.sh, no config.json → silent exit 0
# ---------------------------------------------------------------------------

setup_real_noconfig_dir() {
    NOCONFIG_TMPDIR="$(mktemp -d)"
    for f in on-task-claimed.sh on-task-completed.sh on-task-failed.sh _post.sh; do
        cp "$PLUGIN_SRC/$f" "$NOCONFIG_TMPDIR/$f"
        chmod +x "$NOCONFIG_TMPDIR/$f"
    done
    # Deliberately no config.json
}

setup() {
    setup_mock_dir
}

teardown() {
    rm -rf "$HOOK_TMPDIR" "${NOCONFIG_TMPDIR:-}"
}

# ---------------------------------------------------------------------------
# Arg passing: each hook invokes _post.sh with the correct event name
# ---------------------------------------------------------------------------

@test "on-task-claimed.sh delegates to _post.sh with 'task_claimed'" {
    run "$HOOK_TMPDIR/on-task-claimed.sh"
    [ "$status" -eq 0 ]
    grep -q "task_claimed" "$CAPTURED_ARGS_FILE"
}

@test "on-task-completed.sh delegates to _post.sh with 'task_completed'" {
    run "$HOOK_TMPDIR/on-task-completed.sh"
    [ "$status" -eq 0 ]
    grep -q "task_completed" "$CAPTURED_ARGS_FILE"
}

@test "on-task-failed.sh delegates to _post.sh with 'task_failed'" {
    run "$HOOK_TMPDIR/on-task-failed.sh"
    [ "$status" -eq 0 ]
    grep -q "task_failed" "$CAPTURED_ARGS_FILE"
}

# ---------------------------------------------------------------------------
# Each hook exits 0 when config.json is absent (kit contract: hooks never block)
# ---------------------------------------------------------------------------

@test "on-task-claimed.sh exits 0 even when config.json is absent" {
    setup_real_noconfig_dir
    run "$NOCONFIG_TMPDIR/on-task-claimed.sh"
    [ "$status" -eq 0 ]
}

@test "on-task-completed.sh exits 0 even when config.json is absent" {
    setup_real_noconfig_dir
    run "$NOCONFIG_TMPDIR/on-task-completed.sh"
    [ "$status" -eq 0 ]
}

@test "on-task-failed.sh exits 0 even when config.json is absent" {
    setup_real_noconfig_dir
    run "$NOCONFIG_TMPDIR/on-task-failed.sh"
    [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# NPS env vars (NPS_TASK_ID, NPS_AGENT_ID, NPS_COST_CGN) flow through hooks
# into _post.sh — verified via mock curl + real _post.sh + fixture config
# ---------------------------------------------------------------------------

@test "hooks pass NPS_TASK_ID, NPS_AGENT_ID, NPS_COST_CGN through to _post.sh" {
    # Set up a hook dir with real _post.sh + fixture config + mock curl
    ENVVAR_TMPDIR="$(mktemp -d)"
    for f in on-task-claimed.sh _post.sh; do
        cp "$PLUGIN_SRC/$f" "$ENVVAR_TMPDIR/$f"
        chmod +x "$ENVVAR_TMPDIR/$f"
    done
    cp "$FIXTURES/valid_config.json" "$ENVVAR_TMPDIR/config.json"

    CURL_ARGS_FILE="$ENVVAR_TMPDIR/curl_args"
    > "$CURL_ARGS_FILE"
    export CURL_ARGS_FILE
    export PATH="$BATS_TEST_DIRNAME/bin:$PATH"

    export NPS_TASK_ID="envvar-test-task-007"
    export NPS_AGENT_ID="coder-01"
    export NPS_COST_CGN="2.5"

    run "$ENVVAR_TMPDIR/on-task-claimed.sh"
    [ "$status" -eq 0 ]

    # The task_id and cost should appear in the curl payload (message body)
    grep -q "envvar-test-task-007" "$CURL_ARGS_FILE"

    rm -rf "$ENVVAR_TMPDIR"
}
