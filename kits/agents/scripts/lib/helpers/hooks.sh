# --- Hook runner: post-hook scripts in $HOOKS_DIR/ ---
# Contract: if $HOOKS_DIR/on-task-<event>.sh exists, run it with env + task JSON on stdin.
run_hook() {
    local event="$1"       # task-claimed | task-completed | task-failed
    local task_id="$2"
    local agent_id="$3"
    local status="$4"
    local cost_npt="${5:-0}"
    local hook_script="$HOOKS_DIR/on-${event}.sh"

    [[ -x "$hook_script" ]] || return 0

    local hook_log="$NPS_LOGS_HOME/hooks.log"
    mkdir -p "$(dirname "$hook_log")"
    printf '=== %s event=%s task=%s agent=%s ===\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$event" "$task_id" "$agent_id" >> "$hook_log"
    NPS_TASK_ID="$task_id" \
    NPS_AGENT_ID="$agent_id" \
    NPS_STATUS="$status" \
    NPS_COST_NPT="$cost_npt" \
    NPS_EVENT="$event" \
      "$hook_script" < /dev/null >> "$hook_log" 2>&1 || warn "hook $event exited non-zero"
}
