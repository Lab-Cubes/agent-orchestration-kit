cmd_ack() {
    local do_reject=false
    local osi_ack_by=""
    local reject_reason=""

    # Parse flags
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help|-h)
                echo "Usage:"
                echo "  spawn-agent.sh ack <plan-id> <version>"
                echo "      Approve a pending task-list version."
                echo "      Renames task-lists/{plan-id}/pending/v{N}.json → v{N}.json."
                echo "      Writes an escalation event (dispatcher_acted=osi_acked, verdict=approve)."
                echo ""
                echo "  spawn-agent.sh ack --reject [--reason \"text\"] <plan-id> <version>"
                echo "      Reject a pending task-list version."
                echo "      Keeps the pending file in place for inspection or replacement."
                echo "      Writes an escalation event (dispatcher_acted=osi_acked, verdict=reject)."
                echo ""
                echo "Flags:"
                echo "  --reject             Reject instead of approve"
                echo "  --as <nid>           Override OSer identity (default: git config user.email)"
                echo "  --reason <text>      Rejection reason (captured in escalation event)"
                echo ""
                echo "Mid-drain guard:"
                echo "  The ack command reads task-list-state.json::active_version to enforce"
                echo "  sequential version promotion. Given active_version = N:"
                echo "    version <= N  → error: already acked or historical version"
                echo "    version = N+1 → allowed"
                echo "    version > N+1 → error: cannot skip versions"
                echo "  On first ack (state file absent or active_version = 0), version 1 is allowed."
                return 0
                ;;
            --reject) do_reject=true; shift ;;
            --as)
                [[ -z "${2:-}" ]] && { err "cmd_ack: --as requires a NID argument"; exit 1; }
                osi_ack_by="$2"; shift 2 ;;
            --reason)
                [[ -z "${2:-}" ]] && { err "cmd_ack: --reason requires a text argument"; exit 1; }
                reject_reason="$2"; shift 2 ;;
            --) shift; break ;;
            -*) err "cmd_ack: unknown flag: $1"; exit 1 ;;
            *) break ;;
        esac
    done

    local plan_id="${1:-}"
    local version="${2:-}"

    if [[ -z "$plan_id" || -z "$version" ]]; then
        err "cmd_ack: usage: ack [--reject] [--as <nid>] [--reason <text>] <plan-id> <version>"
        exit 1
    fi

    # Validate version is a positive integer
    if ! [[ "$version" =~ ^[1-9][0-9]*$ ]]; then
        err "cmd_ack: version must be a positive integer, got: $version"
        exit 1
    fi

    local tl_dir="$NPS_TASKLISTS_HOME/$plan_id"
    local pending_dir="$tl_dir/pending"
    local pending_file="$pending_dir/v${version}.json"
    local acked_file="$tl_dir/v${version}.json"
    local state_file="$tl_dir/task-list-state.json"
    local escalation_log="$tl_dir/escalation.jsonl"

    # Safety: plans/{plan-id}/plan.md must exist
    local plan_file="$NPS_PLANS_HOME/$plan_id/plan.md"
    if [[ ! -f "$plan_file" ]]; then
        err "cmd_ack: plan not found: $plan_file"
        err "  Acking against a missing or deleted plan is not allowed."
        exit 1
    fi

    # Validate pending file exists
    if [[ ! -f "$pending_file" ]]; then
        if [[ -f "$acked_file" ]]; then
            err "cmd_ack: v${version}.json already acked (found at $acked_file, not in pending/)"
            exit 1
        fi
        err "cmd_ack: pending file not found: $pending_file"
        exit 1
    fi

    # Mid-drain guard: read active_version from state file
    local active_version=0
    if [[ -f "$state_file" ]]; then
        active_version=$(python3 - "$state_file" <<'PYEOF' 2>/dev/null
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    print(d.get("active_version", 0))
except Exception:
    print(0)
PYEOF
)
        active_version="${active_version:-0}"
    fi

    local expected_next=$(( active_version + 1 ))
    if [[ "$version" -le "$active_version" ]]; then
        err "cmd_ack: v${version} is already acked or historical (active_version=${active_version})"
        err "  Use a version > ${active_version} (next expected: v${expected_next})"
        exit 1
    fi
    if [[ "$version" -gt "$expected_next" ]]; then
        err "cmd_ack: cannot skip versions — v${expected_next} must be acked/resolved first"
        err "  active_version=${active_version}, requested=${version}, next_allowed=${expected_next}"
        exit 1
    fi

    # Warn if higher pending versions also exist
    local higher_count
    higher_count=$(find "$pending_dir" -maxdepth 1 -name "v*.json" 2>/dev/null \
        | awk -F'v' '{n=$NF; gsub(/\.json$/, "", n); print n+0}' \
        | awk -v v="$version" '$1 > v' | wc -l | tr -d ' ')
    if [[ "$higher_count" -gt 0 ]]; then
        warn "cmd_ack: ${higher_count} higher pending version(s) exist beyond v${version} — acting on v${version} only"
    fi

    # Resolve osi_ack_by: --as flag or git config user.email
    if [[ -z "$osi_ack_by" ]]; then
        osi_ack_by=$(git config user.email 2>/dev/null || true)
        if [[ -z "$osi_ack_by" ]]; then
            err "cmd_ack: cannot determine OSer identity"
            err "  Set git config user.email or use --as <nid>"
            exit 1
        fi
    fi

    local now
    now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    if [[ "$do_reject" == "true" ]]; then
        # --- Reject path ---
        # Keep pending file in place; write reject escalation event
        local prior_version
        prior_version=$(python3 - "$pending_file" <<'PYEOF' 2>/dev/null
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    pv = d.get("prior_version")
    print("null" if pv is None else str(pv))
except Exception:
    print("null")
PYEOF
)
        prior_version="${prior_version:-null}"
        mkdir -p "$(dirname "$escalation_log")"
        python3 - "$escalation_log" "$now" "$plan_id" "$version" "$osi_ack_by" "$prior_version" "$reject_reason" <<'PYEOF'
import json, sys
log_file, timestamp, plan_id, version_str, osi_ack_by, prior_version_str, reason = sys.argv[1:]
version = int(version_str)
prior_version = None if prior_version_str == "null" else int(prior_version_str)
event = {
    "schema_version": 1,
    "timestamp": timestamp,
    "plan_id": plan_id,
    "prior_version": prior_version,
    "pushback_source": None,
    "pushback_reason": reason if reason else None,
    "dispatcher_acted": "osi_acked",
    "decomposer_output_version": version,
    "osi_ack_at": timestamp,
    "osi_ack_by": osi_ack_by,
    "osi_ack_verdict": "reject",
    "duration_s": None,
    "escalation_level": "version",
}
with open(log_file, "a") as f:
    f.write(json.dumps(event, separators=(',', ':')) + "\n")
PYEOF
        log "cmd_ack: rejected v${version} for plan ${plan_id}"
        log "  Pending file kept at: $pending_file"
        return 0
    fi

    # --- Approve path ---

    # Optional schema validation against task-list.schema.json
    local schema_file="$NPS_DIR/src/schemas/task-list.schema.json"
    local validator_script="$NPS_DIR/scripts/lib/validate_schema.py"
    if command -v python3 >/dev/null 2>&1 && [[ -f "$validator_script" ]] && [[ -f "$schema_file" ]] && python3 -c "import jsonschema" 2>/dev/null; then
        if ! python3 "$validator_script" "$schema_file" "$pending_file" 2>&1; then
            err "cmd_ack: schema validation failed for $pending_file"
            err "  Rename aborted. Fix the task-list or use --reject."
            exit 1
        fi
    else
        warn "cmd_ack: schema validator unavailable — skipping validation"
    fi

    local node_count
    node_count=$(python3 - "$pending_file" <<'PYEOF' 2>/dev/null
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    print(len(d.get("dag", {}).get("nodes", [])))
except Exception:
    print(-1)
PYEOF
)
    if [[ "$node_count" == "0" ]]; then
        err "cmd_ack: task-list DAG has no nodes"
        err "  Rename aborted. Fix the task-list or use --reject."
        exit 1
    fi

    # Resolve prior_version from the pending file
    local prior_version
    prior_version=$(python3 - "$pending_file" <<'PYEOF' 2>/dev/null
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    pv = d.get("prior_version")
    print("null" if pv is None else str(pv))
except Exception:
    print("null")
PYEOF
)
    prior_version="${prior_version:-null}"

    # POSIX-atomic rename: pending/v{N}.json → v{N}.json
    mv "$pending_file" "$acked_file"

    # Append escalation event
    mkdir -p "$(dirname "$escalation_log")"
    python3 - "$escalation_log" "$now" "$plan_id" "$version" "$osi_ack_by" "$prior_version" <<'PYEOF'
import json, sys
log_file, timestamp, plan_id, version_str, osi_ack_by, prior_version_str = sys.argv[1:]
version = int(version_str)
prior_version = None if prior_version_str == "null" else int(prior_version_str)
event = {
    "schema_version": 1,
    "timestamp": timestamp,
    "plan_id": plan_id,
    "prior_version": prior_version,
    "pushback_source": None,
    "pushback_reason": None,
    "dispatcher_acted": "osi_acked",
    "decomposer_output_version": version,
    "osi_ack_at": timestamp,
    "osi_ack_by": osi_ack_by,
    "osi_ack_verdict": "approve",
    "duration_s": None,
    "escalation_level": "version",
}
with open(log_file, "a") as f:
    f.write(json.dumps(event, separators=(',', ':')) + "\n")
PYEOF

    log "cmd_ack: approved v${version} for plan ${plan_id}"
    echo "$acked_file"
}

# --- dispatch-tasklist ---
# cmd_dispatch_tasklist: consume an acked task-list, walk the DAG, spawn workers.
#
# One-shot per dispatch (architecture.md §6.2). Acquires an exclusive non-blocking
# advisory lock via Python fcntl — no `flock` CLI dependency. Second invocation
# fails fast with a clear error.
# Writes task-list-state.json atomically on every node transition (tmp + mv).
# Graph walk is wave-based: each iteration dispatches all currently-runnable
# nodes in parallel, waits for completion, then repeats until all nodes are
# terminal. No async — cmd_dispatch subprocess handles the worker lifecycle.
#
# Exit codes:
#   0  — all nodes completed successfully
#   1  — one or more nodes failed (or dependency blocked by failed dep)
#   2  — invocation error (bad args, missing task-list, config error)
