#!/usr/bin/env bats
# test_hooks.bats — hook execution observability
#
# Bug: hook script output is swallowed by `> /dev/null 2>&1` in run_hook
# (scripts/spawn-agent.sh:100). This made the Discord install.sh regression
# (PR #15) invisible — no log, no trace, no visibility into hook failure.
#
# Fix: route hook output (stdout + stderr) to $NPS_LOGS_HOME/hooks.log with
# enough metadata (event, task, agent) for the operator to correlate.

load 'helpers/build-kit-tree.bash'

setup() {
    KIT_TMPDIR="$(mktemp -d)"
    build_kit_tree "$KIT_TMPDIR"
}

teardown() {
    rm -rf "${KIT_TMPDIR:-}"
}

@test "failing hook's stdout and stderr are captured in logs/hooks.log" {
    export MOCK_CLAUDE_MODE=happy

    cat > "$KIT_HOOKS/on-task-completed.sh" << 'HOOK'
#!/usr/bin/env bash
echo "HOOK_STDOUT_MARKER_7Z8K"
echo "HOOK_STDERR_MARKER_9Q4M" >&2
exit 1
HOOK
    chmod +x "$KIT_HOOKS/on-task-completed.sh"

    run_spawner setup coder-01 coder
    run run_spawner dispatch coder-01 "hook observability test" --category code --time-limit 60

    # Dispatch must still succeed — hook failure is non-fatal by design
    [ "$status" -eq 0 ]

    # Hook log must exist after the dispatch
    [ -f "$KIT_LOGS/hooks.log" ]

    # Both stdout and stderr from the hook body must be captured
    grep -q "HOOK_STDOUT_MARKER_7Z8K" "$KIT_LOGS/hooks.log"
    grep -q "HOOK_STDERR_MARKER_9Q4M" "$KIT_LOGS/hooks.log"
}

@test "hook log identifies the event and agent for each invocation" {
    export MOCK_CLAUDE_MODE=happy

    cat > "$KIT_HOOKS/on-task-claimed.sh" << 'HOOK'
#!/usr/bin/env bash
exit 0
HOOK
    chmod +x "$KIT_HOOKS/on-task-claimed.sh"
    cat > "$KIT_HOOKS/on-task-completed.sh" << 'HOOK'
#!/usr/bin/env bash
exit 0
HOOK
    chmod +x "$KIT_HOOKS/on-task-completed.sh"

    run_spawner setup coder-01 coder
    run run_spawner dispatch coder-01 "hook metadata test" --category code --time-limit 60

    [ "$status" -eq 0 ]
    [ -f "$KIT_LOGS/hooks.log" ]

    # Both events fired during the dispatch — the log must record each
    grep -q "task-claimed" "$KIT_LOGS/hooks.log"
    grep -q "task-completed" "$KIT_LOGS/hooks.log"
    # Agent id appears so the operator can correlate which worker triggered
    grep -q "coder-01" "$KIT_LOGS/hooks.log"
}
