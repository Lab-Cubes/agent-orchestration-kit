#!/usr/bin/env bats
# test_install.bats — unit tests for plugins/discord/install.sh
#
# install.sh resolves paths relative to its own location:
#   PLUGIN_DIR  = dirname(install.sh)
#   KIT_HOOKS_DIR = $PLUGIN_DIR/../../kits/agents/hooks
#
# Each test builds an isolated temp tree:
#   $INSTALL_TMPDIR/
#     plugins/discord/   ← install.sh + source hook files + config.json
#     kits/agents/hooks/ ← mocked target directory

PLUGIN_SRC="$BATS_TEST_DIRNAME/.."
FIXTURES="$BATS_TEST_DIRNAME/fixtures"

# Build the isolated tree and export the key paths.
setup_install_tree() {
    INSTALL_TMPDIR="$(mktemp -d)"

    MOCK_PLUGIN_DIR="$INSTALL_TMPDIR/plugins/discord"
    MOCK_KIT_HOOKS="$INSTALL_TMPDIR/kits/agents/hooks"
    mkdir -p "$MOCK_PLUGIN_DIR" "$MOCK_KIT_HOOKS"

    # Copy install.sh and all hook source files into the mock plugin dir
    for f in install.sh _post.sh on-task-claimed.sh on-task-completed.sh on-task-failed.sh; do
        cp "$PLUGIN_SRC/$f" "$MOCK_PLUGIN_DIR/$f"
        chmod +x "$MOCK_PLUGIN_DIR/$f"
    done

    # Provide a config.json so install.sh doesn't refuse to proceed
    cp "$FIXTURES/config.json" "$MOCK_PLUGIN_DIR/config.json"
}

setup() {
    setup_install_tree
}

teardown() {
    rm -rf "${INSTALL_TMPDIR:-}"
}

# ---------------------------------------------------------------------------
# install.sh copies hook files into kits/agents/hooks/
# ---------------------------------------------------------------------------

@test "install.sh copies on-task-*.sh and _post.sh into kits/agents/hooks/" {
    run "$MOCK_PLUGIN_DIR/install.sh"
    [ "$status" -eq 0 ]

    for hook in on-task-claimed.sh on-task-completed.sh on-task-failed.sh _post.sh; do
        [ -f "$MOCK_KIT_HOOKS/$hook" ]
    done
}

@test "install.sh sets hook files executable after copying" {
    run "$MOCK_PLUGIN_DIR/install.sh"
    [ "$status" -eq 0 ]

    for hook in on-task-claimed.sh on-task-completed.sh on-task-failed.sh _post.sh; do
        [ -x "$MOCK_KIT_HOOKS/$hook" ]
    done
}

# ---------------------------------------------------------------------------
# Idempotency: running install.sh twice should not error or duplicate entries
# ---------------------------------------------------------------------------

@test "install.sh is idempotent — running twice exits 0 both times" {
    run "$MOCK_PLUGIN_DIR/install.sh"
    [ "$status" -eq 0 ]

    run "$MOCK_PLUGIN_DIR/install.sh"
    [ "$status" -eq 0 ]
}

@test "install.sh is idempotent — file count unchanged after second run" {
    "$MOCK_PLUGIN_DIR/install.sh" > /dev/null
    count_first="$(ls "$MOCK_KIT_HOOKS" | wc -l | tr -d ' ')"

    "$MOCK_PLUGIN_DIR/install.sh" > /dev/null
    count_second="$(ls "$MOCK_KIT_HOOKS" | wc -l | tr -d ' ')"

    [ "$count_first" -eq "$count_second" ]
}

# ---------------------------------------------------------------------------
# install.sh fails gracefully when kits/agents/hooks/ doesn't exist
# ---------------------------------------------------------------------------

@test "install.sh exits non-zero when kits/agents/hooks/ directory is missing" {
    rm -rf "$MOCK_KIT_HOOKS"
    run "$MOCK_PLUGIN_DIR/install.sh"
    [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# install.sh fails gracefully when config.json is missing
# ---------------------------------------------------------------------------

@test "install.sh exits non-zero when config.json is missing" {
    rm -f "$MOCK_PLUGIN_DIR/config.json"
    run "$MOCK_PLUGIN_DIR/install.sh"
    [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# Uninstall: --uninstall removes the hook files from kits/agents/hooks/
# ---------------------------------------------------------------------------

@test "install.sh --uninstall removes hook files from kits/agents/hooks/" {
    # Install first
    "$MOCK_PLUGIN_DIR/install.sh" > /dev/null

    # Verify hooks are present before uninstall
    [ -f "$MOCK_KIT_HOOKS/on-task-claimed.sh" ]

    run "$MOCK_PLUGIN_DIR/install.sh" --uninstall
    [ "$status" -eq 0 ]

    for hook in on-task-claimed.sh on-task-completed.sh on-task-failed.sh _post.sh; do
        [ ! -f "$MOCK_KIT_HOOKS/$hook" ]
    done
}

@test "install.sh --uninstall preserves config.json in the plugin dir" {
    "$MOCK_PLUGIN_DIR/install.sh" > /dev/null
    "$MOCK_PLUGIN_DIR/install.sh" --uninstall > /dev/null

    [ -f "$MOCK_PLUGIN_DIR/config.json" ]
}

@test "install.sh --uninstall is idempotent — exits 0 even if hooks already removed" {
    # Install then uninstall
    "$MOCK_PLUGIN_DIR/install.sh" > /dev/null
    "$MOCK_PLUGIN_DIR/install.sh" --uninstall > /dev/null

    # Uninstall again (hooks already gone)
    run "$MOCK_PLUGIN_DIR/install.sh" --uninstall
    [ "$status" -eq 0 ]
}
