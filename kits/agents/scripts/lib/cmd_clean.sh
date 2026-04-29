cmd_clean() {
    local agent_id="$1"
    local agent_dir="$NPS_AGENTS_HOME/$agent_id"
    if [[ ! -d "$agent_dir" ]]; then err "Worker not found: $agent_dir"; exit 1; fi
    log "Cleaning worker: $agent_id"
    mv "$agent_dir/inbox/"* "$agent_dir/done/" 2>/dev/null || true
    mv "$agent_dir/active/"* "$agent_dir/done/" 2>/dev/null || true
    find "$agent_dir" -maxdepth 1 -type f -not -name "CLAUDE.md" -not -name ".*" -delete 2>/dev/null || true
    log "Clean complete"
}

# --- decompose ---
# cmd_decompose: Plan → Decomposer → pending task-list
#
# Reads DecomposeInput JSON from stdin, invokes the configured Decomposer
# subprocess with a timeout (SIGTERM → 2s grace → SIGKILL), validates the
# output against task-list.schema.json, semantic identity invariants, and NOP DAG constraints, writes
# task-lists/{plan-id}/pending/v{N}.json, and appends an escalation event.
# Emits the absolute path of the written pending file on stdout.
#
# Exit codes:
#   0  — success; pending file written, path on stdout
#   1  — failure (non-zero decomposer exit / timeout / schema violation /
#          semantic / DAG violation); decomposer_failed escalation event appended
#   2  — invocation error (bad stdin JSON, missing plan_id, config error)
#
# Usage: echo "$json_input" | spawn-agent.sh decompose [--help]
