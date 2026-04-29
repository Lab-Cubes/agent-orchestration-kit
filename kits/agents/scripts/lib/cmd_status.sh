cmd_status() {
    local agent_id="$1"
    local agent_dir="$NPS_AGENTS_HOME/$agent_id"
    if [[ ! -d "$agent_dir" ]]; then
        err "Worker not found: $agent_dir"; exit 1
    fi
    echo "=== Worker: $agent_id ==="
    for state in inbox active done blocked; do
        echo ""
        echo "$state:"
        ls "$agent_dir/$state/" 2>/dev/null | head -5 | sed 's/^/  /'
    done
    local latest
    latest=$(ls -t "$agent_dir/done/"*.result.json 2>/dev/null | head -1)
    if [[ -n "$latest" ]]; then
        echo ""
        echo "Latest result:"
        python3 - "$latest" <<'PYEOF' 2>/dev/null || cat "$latest"
import json, sys
d = json.load(open(sys.argv[1]))
p = d.get('payload', {})
print(f"  Task:      {p.get('id', '?')}")
print(f"  Status:    {p.get('status', '?')}")
print(f"  Duration:  {p.get('duration', '?')}s")
print(f"  Cost NPT:  {p.get('cost_npt', '?')}")
print(f"  Files:     {p.get('files_changed', [])}")
print(f"  Summary:   {str(d.get('value', '?'))[:200]}")
PYEOF
    fi
}

# --- clean ---
