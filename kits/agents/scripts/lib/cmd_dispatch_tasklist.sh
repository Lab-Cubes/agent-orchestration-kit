cmd_dispatch_tasklist() {
    # --help
    if [[ "${1:-}" == "--help" ]]; then
        cat <<'HELP'
cmd_dispatch_tasklist — consume acked task-list, spawn workers, track state

Usage:
  spawn-agent.sh dispatch-tasklist <plan-id> [--version N]

Arguments:
  plan-id          Plan identifier (must have an acked task-list)
  --version N      Use specific acked version vN.json (default: latest)

Exit codes:
  0  — all nodes completed
  1  — one or more nodes failed, or dispatcher error during graph walk
  2  — invocation error (bad args, missing/unacked task-list)

Lock semantics:
  Acquires an exclusive non-blocking advisory lock on
  $NPS_TASKLISTS_HOME/{plan-id}/.dispatcher.lock via Python fcntl.
  A second concurrent invocation for the same plan-id exits immediately with
  exit code 1 and a clear error — no queuing.

State file:
  $NPS_TASKLISTS_HOME/{plan-id}/task-list-state.json
  Written on dispatch start (all nodes pending), updated on every node
  transition (running → completed|failed). Writes are atomic: tmp file + mv.
  merge_hold: true is set throughout; enforcement lands in #64.

Escalation log:
  $NPS_TASKLISTS_HOME/{plan-id}/escalation.jsonl
  Per-node events (escalation_level: "task") on failure.
  Version-level event (escalation_level: "version") on completion.
HELP
        return 0
    fi

    # ---- Arg parsing ----
    local plan_id=""
    local version_override=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --version) version_override="$2"; shift 2 ;;
            -*)        err "cmd_dispatch_tasklist: unknown option: $1"; exit 2 ;;
            *)
                if [[ -z "$plan_id" ]]; then
                    plan_id="$1"
                else
                    err "cmd_dispatch_tasklist: unexpected argument: $1"
                    exit 2
                fi
                shift ;;
        esac
    done

    if [[ -z "$plan_id" ]]; then
        err "Usage: spawn-agent.sh dispatch-tasklist <plan-id> [--version N]"
        exit 2
    fi

    local plan_dir="$NPS_TASKLISTS_HOME/$plan_id"
    mkdir -p "$plan_dir"

    # ---- Advisory lock: non-blocking — fail fast if another dispatcher is active ----
    # Uses Python fcntl.flock (POSIX, cross-platform) — no `flock` CLI dependency.
    # A named FIFO synchronises lock acquisition: Python writes "ok" on success or
    # "fail" on LOCK_NB refusal; bash reads it before proceeding.
    local lock_file="$plan_dir/.dispatcher.lock"
    local _lock_fifo _lock_pid
    _lock_fifo=$(mktemp -u)
    mkfifo "$_lock_fifo" || { err "cmd_dispatch_tasklist: failed to create lock fifo"; exit 2; }

    python3 - "$lock_file" "$_lock_fifo" <<'PYEOF' &
import fcntl, sys, time
lf = open(sys.argv[1], 'w')
try:
    fcntl.flock(lf, fcntl.LOCK_EX | fcntl.LOCK_NB)
    with open(sys.argv[2], 'w') as f:
        f.write('ok\n')
    # Hold lock until killed (SIGTERM from parent when function exits)
    while True:
        time.sleep(3600)
except IOError:
    with open(sys.argv[2], 'w') as f:
        f.write('fail\n')
PYEOF
    _lock_pid=$!

    # Block until Python signals lock result (FIFO rendezvous)
    local _lock_result
    _lock_result=$(cat "$_lock_fifo")
    rm -f "$_lock_fifo"

    if [[ "$_lock_result" != "ok" ]]; then
        wait "$_lock_pid" 2>/dev/null || true
        err "cmd_dispatch_tasklist: another dispatcher is already running for plan $plan_id"
        exit 1
    fi

    # ---- Find acked task-list file ----
    local task_list_file=""
    if [[ -n "$version_override" ]]; then
        task_list_file="$plan_dir/v${version_override}.json"
        if [[ ! -f "$task_list_file" ]]; then
            if [[ -f "$plan_dir/pending/v${version_override}.json" ]]; then
                err "cmd_dispatch_tasklist: v${version_override} is in pending/ — ack first:"
                err "  spawn-agent.sh ack $plan_id $version_override"
            else
                err "cmd_dispatch_tasklist: no acked task-list v${version_override} for plan $plan_id"
            fi
            kill "$_lock_pid" 2>/dev/null || true
            exit 2
        fi
    else
        # Latest acked version: highest-numbered vN.json directly in plan_dir (not pending/)
        task_list_file=$(python3 - "$plan_dir" <<'PYEOF'
import os, sys
d = sys.argv[1]
if not os.path.isdir(d):
    sys.exit(1)
vers = []
for f in os.listdir(d):
    if f.startswith('v') and f.endswith('.json') and f[1:-5].isdigit():
        full = os.path.join(d, f)
        if os.path.isfile(full):
            vers.append((int(f[1:-5]), full))
if not vers:
    sys.exit(1)
vers.sort(key=lambda x: x[0])
print(vers[-1][1])
PYEOF
        ) || true
        if [[ -z "$task_list_file" ]]; then
            err "cmd_dispatch_tasklist: no acked task-list for plan $plan_id"
            err "  Run: spawn-agent.sh ack $plan_id <version>"
            kill "$_lock_pid" 2>/dev/null || true
            exit 2
        fi
    fi

    log "cmd_dispatch_tasklist: plan=$plan_id, task-list=$(basename "$task_list_file")"

    # ---- Parse task-list: emit unit-separator-delimited node rows ----
    # Separator: \x1f (ASCII 31, unit separator) — non-whitespace so empty
    # scope_csv fields don't collapse when read by IFS=$'\037' read.
    # Format: node_id \x1f agent_id \x1f action \x1f scope_csv \x1f budget_npt \x1f timeout_s
    local node_data_file
    node_data_file=$(mktemp)

    local parse_out
    parse_out=$(python3 - "$task_list_file" <<'PYEOF'
import json, sys
SEP = '\x1f'
d = json.load(open(sys.argv[1]))
print(f"VERSION_ID={d['version_id']}")
print(f"PLAN_ID_TL={d['plan_id']}")
for n in d['dag']['nodes']:
    agent_id = n['agent'].split(':')[-1]
    scope_csv = ','.join(n.get('scope') or [])
    timeout_s = str(int(n.get('timeout_ms', 600000) // 1000))
    max_retries = str(n.get('retry_policy', {}).get('max_retries', 0))
    print(f"NODE={n['id']}{SEP}{agent_id}{SEP}{n['action']}{SEP}{scope_csv}{SEP}{n['budget_npt']}{SEP}{timeout_s}{SEP}{max_retries}")
PYEOF
    ) || { err "cmd_dispatch_tasklist: failed to parse task-list JSON"; rm -f "$node_data_file"; kill "$_lock_pid" 2>/dev/null || true; exit 2; }

    local version_id=""
    local node_ids=()
    # Parallel arrays indexed by position (bash 3.2 — no declare -A)
    local _agents=() _actions=() _scopes=() _budgets=() _timeouts=()

    while IFS= read -r line; do
        case "${line%%=*}" in
            VERSION_ID)  version_id="${line#*=}" ;;
            PLAN_ID_TL)  ;;   # already have plan_id from arg
            NODE)
                # IFS=$'\037' (non-whitespace) so empty scope_csv fields are preserved
                IFS=$'\037' read -r nid agent_id action scope_csv budget timeout_s max_retries \
                    <<< "${line#NODE=}"
                node_ids+=("$nid")
                _agents+=("$agent_id")
                _actions+=("$action")
                _scopes+=("$scope_csv")
                _budgets+=("$budget")
                _timeouts+=("$timeout_s")
                # Also write tab-delimited to node_data_file for awk-based lookups
                # Fields: 1=node_id 2=agent_id 3=action 4=scope_csv 5=budget 6=timeout_s 7=max_retries
                printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
                    "$nid" "$agent_id" "$action" "$scope_csv" "$budget" "$timeout_s" "${max_retries:-0}" \
                    >> "$node_data_file"
                ;;
        esac
    done <<< "$parse_out"

    if [[ ${#node_ids[@]} -eq 0 ]]; then
        log "cmd_dispatch_tasklist: task-list has no nodes — nothing to dispatch"
        rm -f "$node_data_file"
        kill "$_lock_pid" 2>/dev/null || true
        exit 0
    fi

    log "cmd_dispatch_tasklist: ${#node_ids[@]} node(s), version=$version_id"

    # ---- Helper: look up a field for a node_id from node_data_file (awk) ----
    # Fields: 1=node_id 2=agent_id 3=action 4=scope_csv 5=budget 6=timeout_s
    _dt_node_field() {
        awk -F'\t' -v nid="$1" -v f="$2" '$1==nid{print $f; exit}' "$node_data_file"
    }

    # ---- State file paths ----
    local state_file="$plan_dir/task-list-state.json"
    local state_tmp="$plan_dir/.task-list-state.json.tmp"
    local escalation_log="$plan_dir/escalation.jsonl"

    # ---- Init state file (all nodes pending) if not already present ----
    if [[ ! -f "$state_file" ]]; then
        python3 - "$task_list_file" "$state_tmp" <<'PYEOF'
import json, sys
from datetime import datetime, timezone
tl = json.load(open(sys.argv[1]))
now = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
state = {
    "schema_version": 1,
    "plan_id": tl['plan_id'],
    "active_version": tl['version_id'],
    "superseded_versions": [],
    "node_states": {
        n['id']: {
            "status": "pending", "task_id": None,
            "started_at": None, "completed_at": None,
            "result_path": None, "retries": 0,
        }
        for n in tl['dag']['nodes']
    },
    "merge_hold": True,
    "updated_at": now,
}
with open(sys.argv[2], 'w') as f:
    json.dump(state, f, indent=2)
    f.write('\n')
PYEOF
        mv "$state_tmp" "$state_file"
        log "cmd_dispatch_tasklist: state initialized (all nodes pending)"
    else
        log "cmd_dispatch_tasklist: resuming from existing state"
    fi

    # ---- Helper: append escalation event ----
    # Args: dispatcher_acted_or_null  pushback_source_or_null  escalation_level
    #       [prior_version_or_null]  [pushback_reason_or_null]  [decomposer_output_version_or_null]
    _dt_append_event() {
        python3 - "$escalation_log" "$plan_id" "$version_id" "$1" "$2" "$3" \
            "${4:-null}" "${5:-null}" "${6:-null}" <<'PYEOF'
import json, os, sys
from datetime import datetime, timezone
log_p, plan_id, ver_str, disp_acted, pb_src, level, prior_ver, pb_reason, decomp_ver = sys.argv[1:]
now = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
decomp_out = (int(decomp_ver) if decomp_ver not in ('null', '') and decomp_ver.isdigit()
              else (int(ver_str) if ver_str.isdigit() else None))
event = {
    "schema_version": 1,
    "timestamp": now,
    "plan_id": plan_id,
    "prior_version": None if prior_ver == 'null' else int(prior_ver),
    "pushback_source": None if pb_src == 'null' else pb_src,
    "pushback_reason": None if pb_reason == 'null' else pb_reason,
    "dispatcher_acted": None if disp_acted == 'null' else disp_acted,
    "decomposer_output_version": decomp_out,
    "osi_ack_at": None,
    "osi_ack_verdict": None,
    "osi_ack_by": None,
    "duration_s": None,
    "escalation_level": level,
}
os.makedirs(os.path.dirname(os.path.abspath(log_p)), exist_ok=True)
with open(log_p, 'a') as f:
    f.write(json.dumps(event) + '\n')
PYEOF
    }

    # ---- Helper: update a single node's state (atomic write) ----
    # Args: node_id  new_status  task_id_or_null  result_path_or_null
    _dt_update_node() {
        python3 - "$state_file" "$state_tmp" "$1" "$2" "$3" "$4" <<'PYEOF'
import json, os, sys
from datetime import datetime, timezone
sf, tmp, node_id, new_status, task_id, result_path = sys.argv[1:]
now = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
d = json.load(open(sf))
ns = d['node_states'][node_id]
ns['status'] = new_status
if task_id != 'null':
    ns['task_id'] = task_id
if new_status == 'running':
    ns['started_at'] = now
elif new_status in ('completed', 'failed'):
    ns['completed_at'] = now
    if result_path != 'null':
        ns['result_path'] = result_path
d['updated_at'] = now
with open(tmp, 'w') as f:
    json.dump(d, f, indent=2)
    f.write('\n')
os.replace(tmp, sf)
PYEOF
    }

    # ---- Helper: rename a branch for supersede (terminal + pushback-blocked nodes) ----
    # Args: node_id  agent_id  task_id_or_null  prev_version  event_action  new_status_or_empty
    #   new_status_or_empty = "" means leave status unchanged (terminal nodes)
    _dt_supersede_rename_branch() {
        local _srb_node="$1" _srb_agent="$2" _srb_tid="$3" _srb_prev="$4"
        local _srb_event="$5" _srb_status="$6"
        if [[ "$_srb_tid" == "null" ]]; then
            [[ -n "$_srb_status" ]] && _dt_update_node "$_srb_node" "$_srb_status" "null" "null"
            _dt_append_event "$_srb_event" "null" "task" "$_srb_prev"
            return
        fi
        local _srb_bf="$NPS_AGENTS_HOME/$_srb_agent/done/${_srb_tid}.branch.json"
        local _srb_branch="" _srb_wt="" _srb_bm
        if [[ -f "$_srb_bf" ]]; then
            _srb_bm=$(python3 - "$_srb_bf" <<'PYEOF' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
print('\t'.join([d.get('branch',''), d.get('worktree','')]))
PYEOF
            ) || true
            [[ -n "$_srb_bm" ]] && IFS=$'\t' read -r _srb_branch _srb_wt <<< "$_srb_bm"
        fi
        if [[ -n "$_srb_branch" && -d "$_srb_wt" ]]; then
            local _srb_new="superseded/${plan_id}/v${_srb_prev}/${_srb_branch#agent/}"
            git -C "$_srb_wt" branch -m "$_srb_branch" "$_srb_new" 2>/dev/null || true
        fi
        [[ -n "$_srb_status" ]] && _dt_update_node "$_srb_node" "$_srb_status" "$_srb_tid" "null"
        _dt_append_event "$_srb_event" "$_srb_tid" "task" "$_srb_prev"
    }

    # ---- Helper: supersede a running node ----
    # Args: node_id  agent_id  task_id_or_null  prev_version
    # Sets: updates state + appends escalation event; complex-HEAD → blocked (gates drain)
    _dt_supersede_running() {
        local _sr_node="$1" _sr_agent="$2" _sr_tid="$3" _sr_prev="$4"
        if [[ "$_sr_tid" == "null" ]]; then
            warn "cmd_dispatch_tasklist: supersede: running node $_sr_node has null task_id — complex state"
            _dt_update_node "$_sr_node" "blocked" "null" "null"
            _dt_append_event "supersede_complex_state" "null" "task" "$_sr_prev"
            return
        fi
        local _sr_bf="$NPS_AGENTS_HOME/$_sr_agent/done/${_sr_tid}.branch.json"
        if [[ ! -f "$_sr_bf" ]]; then
            warn "cmd_dispatch_tasklist: supersede: no branch.json for $_sr_tid — complex state"
            _dt_update_node "$_sr_node" "blocked" "$_sr_tid" "null"
            _dt_append_event "supersede_complex_state" "$_sr_tid" "task" "$_sr_prev"
            return
        fi
        local _sr_branch="" _sr_wt="" _sr_scope="" _sr_bm
        _sr_bm=$(python3 - "$_sr_bf" <<'PYEOF' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
print('\t'.join([d.get('branch',''), d.get('worktree',''), d.get('original_scope','')]))
PYEOF
        ) || true
        [[ -n "$_sr_bm" ]] && IFS=$'\t' read -r _sr_branch _sr_wt _sr_scope <<< "$_sr_bm"
        if [[ -z "$_sr_branch" || -z "$_sr_wt" ]]; then
            warn "cmd_dispatch_tasklist: supersede: invalid branch metadata for $_sr_tid — complex state"
            _dt_update_node "$_sr_node" "blocked" "$_sr_tid" "null"
            _dt_append_event "supersede_complex_state" "$_sr_tid" "task" "$_sr_prev"
            return
        fi
        # Best-effort SIGINT to running worker (process may have already exited)
        local _sr_pid
        _sr_pid=$(ps aux 2>/dev/null | grep -F "$_sr_tid" | grep -v grep | awk '{print $2}' | head -1 || true)
        if [[ -n "$_sr_pid" ]]; then
            kill -INT "$_sr_pid" 2>/dev/null || true
            sleep 1
        fi
        # HEAD state check
        local _sr_head
        _sr_head=$(git -C "$_sr_wt" symbolic-ref --quiet HEAD 2>/dev/null || echo "")
        if [[ -z "$_sr_head" || "$_sr_head" != "refs/heads/${_sr_branch}" ]]; then
            warn "cmd_dispatch_tasklist: supersede: abnormal HEAD in worktree for $_sr_tid (head=${_sr_head:-<detached>}) — complex state"
            _dt_update_node "$_sr_node" "blocked" "$_sr_tid" "null"
            _dt_append_event "supersede_complex_state" "$_sr_tid" "task" "$_sr_prev"
            return
        fi
        # Normal HEAD: Dispatcher-side commit + branch rename
        local _sr_email _sr_name
        _sr_email=$(git config user.email 2>/dev/null || echo "noreply@example.com")
        _sr_name=$(git config user.name 2>/dev/null || echo "Dispatcher")
        git -C "$_sr_wt" add -A 2>/dev/null || true
        if ! git -C "$_sr_wt" \
                -c "user.email=${_sr_email}" \
                -c "user.name=${_sr_name}" \
                commit -m "supersede: partial work at v${_sr_prev}" \
                --allow-empty --no-verify 2>/dev/null; then
            warn "cmd_dispatch_tasklist: supersede: Dispatcher-side commit failed for $_sr_tid — complex state"
            _dt_update_node "$_sr_node" "blocked" "$_sr_tid" "null"
            _dt_append_event "supersede_complex_state" "$_sr_tid" "task" "$_sr_prev"
            return
        fi
        local _sr_new="superseded/${plan_id}/v${_sr_prev}/${_sr_branch#agent/}"
        if ! git -C "$_sr_wt" branch -m "$_sr_branch" "$_sr_new" 2>/dev/null; then
            warn "cmd_dispatch_tasklist: supersede: branch rename failed for $_sr_tid — complex state"
            _dt_update_node "$_sr_node" "blocked" "$_sr_tid" "null"
            _dt_append_event "supersede_complex_state" "$_sr_tid" "task" "$_sr_prev"
            return
        fi
        _dt_update_node "$_sr_node" "superseded" "$_sr_tid" "null"
        _dt_append_event "supersede_applied" "$_sr_tid" "task" "$_sr_prev"
        log "cmd_dispatch_tasklist: supersede: node $_sr_node → superseded (branch: $_sr_new)"
    }

    # ---- Helper: run supersede pass (v_N → v_{N+1}) ----
    # Args: prev_version (N; v_{N+1} is already $version_id)
    _dt_run_supersede_pass() {
        local _sp_prev="$1"
        local _sp_prev_tl="$plan_dir/v${_sp_prev}.json"
        if [[ ! -f "$_sp_prev_tl" ]]; then
            err "cmd_dispatch_tasklist: supersede: v${_sp_prev}.json not found — cannot route v${_sp_prev} nodes"
            kill "$_lock_pid" 2>/dev/null || true
            exit 1
        fi
        log "cmd_dispatch_tasklist: supersede pass v${_sp_prev} → v${version_id}"
        # Build node→agent map from v_N task-list
        local _sp_node_agents
        _sp_node_agents=$(python3 - "$_sp_prev_tl" <<'PYEOF'
import json, sys
for n in json.load(open(sys.argv[1]))['dag']['nodes']:
    print(f"{n['id']}\t{n['agent'].split(':')[-1]}")
PYEOF
        ) || { err "cmd_dispatch_tasklist: supersede: failed to parse v${_sp_prev}.json"; kill "$_lock_pid" 2>/dev/null || true; exit 1; }
        # Read current node states
        local _sp_node_states
        _sp_node_states=$(python3 - "$state_file" <<'PYEOF'
import json, sys
for nid, ns in json.load(open(sys.argv[1]))['node_states'].items():
    print('\t'.join([nid, ns['status'],
                     ns.get('task_id') or 'null',
                     ns.get('result_path') or 'null']))
PYEOF
        )
        local _sp_blocked=false
        local _sp_blocked_list=()
        while IFS=$'\t' read -r _sp_nid _sp_st _sp_tid _sp_rp; do
            [[ -z "$_sp_nid" ]] && continue
            local _sp_agent
            _sp_agent=$(awk -F'\t' -v nid="$_sp_nid" '$1==nid{print $2; exit}' <<< "$_sp_node_agents")
            if [[ -z "$_sp_agent" ]]; then
                warn "cmd_dispatch_tasklist: supersede: no agent for node $_sp_nid in v${_sp_prev}"
                continue
            fi
            case "$_sp_st" in
                running)
                    _dt_supersede_running "$_sp_nid" "$_sp_agent" "$_sp_tid" "$_sp_prev"
                    # Re-read post-transition status
                    local _sp_post
                    _sp_post=$(python3 - "$state_file" "$_sp_nid" <<'PYEOF' 2>/dev/null
import json, sys
print(json.load(open(sys.argv[1]))['node_states'].get(sys.argv[2], {}).get('status', 'unknown'))
PYEOF
                    )
                    if [[ "$_sp_post" == "blocked" ]]; then
                        _sp_blocked=true
                        _sp_blocked_list+=("$_sp_nid")
                    fi
                    ;;
                blocked)
                    local _sp_has_pb=false
                    if [[ "$_sp_rp" != "null" && -f "$_sp_rp" ]]; then
                        _sp_has_pb=$(python3 - "$_sp_rp" <<'PYEOF' 2>/dev/null
import json, sys
try:
    print('true' if json.load(open(sys.argv[1])).get('payload', {}).get('pushback_reason') else 'false')
except Exception:
    print('false')
PYEOF
                        )
                    fi
                    if [[ "$_sp_has_pb" == "true" ]]; then
                        _dt_supersede_rename_branch "$_sp_nid" "$_sp_agent" "$_sp_tid" "$_sp_prev" "pushback_superseded" "superseded"
                    else
                        warn "cmd_dispatch_tasklist: supersede: blocked node $_sp_nid (no pushback) gates drain"
                        _dt_append_event "supersede_complex_state" "$_sp_tid" "task" "$_sp_prev"
                        _sp_blocked=true
                        _sp_blocked_list+=("$_sp_nid")
                    fi
                    ;;
                completed|failed|cancelled|timeout|superseded)
                    _dt_supersede_rename_branch "$_sp_nid" "$_sp_agent" "$_sp_tid" "$_sp_prev" "supersede_archived" ""
                    ;;
                pending)
                    # Never dispatched: no branch to rename; archive directly
                    _dt_update_node "$_sp_nid" "superseded" "null" "null"
                    _dt_append_event "supersede_archived" "null" "task" "$_sp_prev"
                    ;;
            esac
        done <<< "$_sp_node_states"
        # Drain gate
        if $_sp_blocked; then
            err "KIT-SUPERSEDE-INCOMPLETE: v${_sp_prev} nodes blocked — OSer triage required:"
            for _bn in "${_sp_blocked_list[@]}"; do err "  $_bn"; done
            err "Resolve blocked nodes, then re-run: spawn-agent.sh dispatch-tasklist $plan_id"
            kill "$_lock_pid" 2>/dev/null || true
            exit 1
        fi
        # All v_N nodes terminal — flip active_version to v_{N+1} and re-init node_states
        python3 - "$state_file" "$state_tmp" "$task_list_file" "$version_id" "$_sp_prev" <<'PYEOF'
import json, os, sys
from datetime import datetime, timezone
sf, tmp, tl_file, new_ver, prev_ver = sys.argv[1:]
new_ver, prev_ver = int(new_ver), int(prev_ver)
now = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
s = json.load(open(sf))
tl = json.load(open(tl_file))
svs = s.get('superseded_versions', [])
if prev_ver not in svs:
    svs.append(prev_ver)
s['active_version'] = new_ver
s['superseded_versions'] = svs
s['node_states'] = {
    n['id']: {"status": "pending", "task_id": None,
               "started_at": None, "completed_at": None,
               "result_path": None, "retries": 0}
    for n in tl['dag']['nodes']
}
s['updated_at'] = now
with open(tmp, 'w') as f:
    json.dump(s, f, indent=2)
    f.write('\n')
os.replace(tmp, sf)
PYEOF
        log "cmd_dispatch_tasklist: supersede complete — active_version → v${version_id}"
    }

    # ---- Supersede check: version upgrade detected ----
    local _cur_active_ver
    _cur_active_ver=$(python3 - "$state_file" <<'PYEOF' 2>/dev/null
import json, sys
print(json.load(open(sys.argv[1])).get('active_version', 0))
PYEOF
    )
    if [[ "$_cur_active_ver" -lt "$version_id" ]]; then
        _dt_run_supersede_pass "$_cur_active_ver"
    fi

    # ---- Graph walk loop ----
    # Wave-based: each iteration dispatches all currently-runnable nodes in
    # parallel, waits for completion, then checks terminal state and repeats.
    # Runnable: status=pending AND all input_from nodes are completed.
    local any_failed=false
    local _pushback_break=false
    local max_waves=$(( ${#node_ids[@]} + 1 ))
    local wave=0

    while (( wave < max_waves )); do
        (( wave += 1 ))

        # --- Check terminal state and find runnable nodes ---
        local graph_out
        graph_out=$(python3 - "$state_file" "$task_list_file" <<'PYEOF'
import json, sys
state = json.load(open(sys.argv[1]))
tl    = json.load(open(sys.argv[2]))
ns    = state['node_states']
terminal = {'completed', 'failed', 'superseded'}
all_t    = all(v['status'] in terminal for v in ns.values())
any_f    = any(v['status'] == 'failed'  for v in ns.values())
inp_map  = {n['id']: n.get('input_from') or [] for n in tl['dag']['nodes']}
runnable = [
    nid for nid, v in ns.items()
    if v['status'] == 'pending'
    and all(ns.get(dep, {}).get('status') == 'completed' for dep in inp_map[nid])
]
print(f"ALL_TERMINAL={'true' if all_t else 'false'}")
print(f"ANY_FAILED={'true' if any_f else 'false'}")
print(f"RUNNABLE={' '.join(runnable)}")
PYEOF
        )

        local all_terminal="" any_failed_flag="" runnable_str=""
        while IFS='=' read -r key val; do
            case "$key" in
                ALL_TERMINAL) all_terminal="$val" ;;
                ANY_FAILED)   any_failed_flag="$val" ;;
                RUNNABLE)     runnable_str="$val" ;;
            esac
        done <<< "$graph_out"

        [[ "$any_failed_flag" == "true" ]] && any_failed=true
        [[ "$all_terminal" == "true" ]] && break

        if [[ -z "$runnable_str" ]]; then
            err "cmd_dispatch_tasklist: no runnable nodes — blocked by failed dependency"
            _dt_append_event "escalated_to_oser" "null" "task"
            any_failed=true
            break
        fi

        # --- Dispatch all runnable nodes in parallel ---
        local wave_tmp_dir
        wave_tmp_dir=$(mktemp -d)

        for node_id in $runnable_str; do
            local agent_id action scope_csv budget timeout_s
            agent_id=$(_dt_node_field "$node_id" 2)
            action=$(_dt_node_field   "$node_id" 3)
            scope_csv=$(_dt_node_field "$node_id" 4)
            budget=$(_dt_node_field    "$node_id" 5)
            timeout_s=$(_dt_node_field "$node_id" 6)

            local dispatch_log="$wave_tmp_dir/$node_id.log"
            local success_criteria_file="$wave_tmp_dir/$node_id.success_criteria.json"
            python3 - "$task_list_file" "$node_id" "$success_criteria_file" <<'PYEOF'
import json, sys
tl_file, node_id, out_file = sys.argv[1:]
tl = json.load(open(tl_file))
for node in tl['dag']['nodes']:
    if node['id'] == node_id:
        with open(out_file, 'w') as f:
            json.dump(node.get('success_criteria') or {}, f)
            f.write('\n')
        break
else:
    raise SystemExit(f"node not found: {node_id}")
PYEOF

            local -a dispatch_args=("$agent_id" "$action" \
                "--budget" "$budget" "--time-limit" "$timeout_s" \
                "--plan-id" "$plan_id" \
                "--success-criteria-file" "$success_criteria_file")
            [[ -n "$scope_csv" ]] && dispatch_args+=("--scope" "$scope_csv")

            log "cmd_dispatch_tasklist: dispatching node $node_id → agent $agent_id"
            "$0" dispatch "${dispatch_args[@]}" > "$dispatch_log" 2>&1 &
            echo "$!" > "$wave_tmp_dir/$node_id.pid"

            # Mark running; task_id resolved after dispatch completes
            _dt_update_node "$node_id" "running" "null" "null"
        done

        # --- Wait for each node's dispatch process and update state ---
        for node_id in $runnable_str; do
            local pid_file="$wave_tmp_dir/$node_id.pid"
            local dispatch_log="$wave_tmp_dir/$node_id.log"
            local pid
            pid=$(cat "$pid_file")

            local node_exit=0
            wait "$pid" || node_exit=$?

            # Extract task_id from the dispatch log ("Intent created: task-xxx")
            local task_id
            task_id=$(grep 'Intent created:' "$dispatch_log" 2>/dev/null \
                | sed 's/.*Intent created:[[:space:]]*//' \
                | grep -oE 'task-[a-zA-Z0-9_-]+' | head -1 || true)

            # Find result file via task_id
            local result_file="null"
            if [[ -n "$task_id" ]]; then
                local candidate="$NPS_AGENTS_HOME/$(_dt_node_field "$node_id" 2)/done/${task_id}.result.json"
                [[ -f "$candidate" ]] && result_file="$candidate"
            fi

            # Determine node outcome from result payload, or preserve kit-side
            # dispatch errors when no worker result exists.
            local node_status="failed" node_pushback_reason="" node_failure_reason=""
            if [[ "$result_file" != "null" ]]; then
                local _raw_outcome
                _raw_outcome=$(python3 - "$result_file" <<'PYEOF'
import json, sys
try:
    p = json.load(open(sys.argv[1])).get('payload', {})
    s = p.get('status', 'failed')
    pb = p.get('pushback_reason') or ''
    if s == 'completed': print('completed')
    elif s == 'blocked' and pb: print('pushback'); print(pb)
    else: print('failed')
except Exception: print('failed')
PYEOF
                )
                node_status=$(printf '%s' "$_raw_outcome" | sed -n '1p')
                node_pushback_reason=$(printf '%s' "$_raw_outcome" | sed -n '2p')
            elif [[ $node_exit -ne 0 ]]; then
                node_failure_reason=$(grep -oE 'KIT-DISPATCH-NO-LIFECYCLE' "$dispatch_log" 2>/dev/null | head -1 || true)
            fi

            if [[ "$node_status" == "pushback" ]]; then
                _dt_update_node "$node_id" "blocked" "${task_id:-null}" "$result_file"
                log "cmd_dispatch_tasklist: node $node_id BLOCKED (pushback: $node_pushback_reason)"
                local _pb_plan="$NPS_PLANS_HOME/$plan_id/plan.md"
                local _pb_input _pb_decomp_exit=0
                local _pb_new_ver=$(( version_id + 1 ))
                if [[ -f "$_pb_plan" ]]; then
                    _pb_input=$(mktemp)
                    python3 - "$_pb_plan" "$task_list_file" "$state_file" "$node_pushback_reason" \
                        <<'PYEOF' > "$_pb_input"
import json, sys
plan_file, tl_file, sf, pb = sys.argv[1:]
print(json.dumps({"plan": open(plan_file).read(),
    "context": {"files": [], "knowledge": [], "branch": "main"},
    "prior_version": json.load(open(tl_file)),
    "prior_state": json.load(open(sf)), "pushback": pb}))
PYEOF
                    "$0" decompose < "$_pb_input" > /dev/null 2>&1 || _pb_decomp_exit=$?
                    rm -f "$_pb_input"
                else
                    warn "cmd_dispatch_tasklist: pushback: plan.md not found ($plan_id)"
                    _pb_decomp_exit=1
                fi
                local _pb_acted="invoked_decomposer" _pb_ver="$_pb_new_ver"
                [[ $_pb_decomp_exit -ne 0 ]] && { _pb_acted="decomposer_failed"; _pb_ver="null"; }
                _dt_append_event "$_pb_acted" "${task_id:-null}" "task" \
                    "$version_id" "$node_pushback_reason" "$_pb_ver"
                any_failed=true
                _pushback_break=true
                break

            elif [[ "$node_status" == "failed" ]]; then
                local _node_retries _node_max_r
                _node_retries=$(python3 - "$state_file" "$node_id" 2>/dev/null <<'PYEOF'
import json, sys; print(json.load(open(sys.argv[1]))['node_states'][sys.argv[2]].get('retries', 0))
PYEOF
                )
                _node_max_r=$(_dt_node_field "$node_id" 7)
                _node_retries="${_node_retries:-0}"; _node_max_r="${_node_max_r:-0}"
                if [[ -n "$node_failure_reason" ]]; then
                    _dt_update_node "$node_id" "failed" "${task_id:-null}" "$result_file"
                    _dt_append_event "escalated_to_oser" "${task_id:-null}" "task" \
                        "null" "$node_failure_reason" "null"
                    any_failed=true
                    log "cmd_dispatch_tasklist: node $node_id FAILED ($node_failure_reason)"
                elif [[ "$_node_retries" -lt "${_node_max_r:-0}" ]]; then
                    python3 - "$state_file" "$state_tmp" "$node_id" "$(( _node_retries + 1 ))" <<'PYEOF'
import json, os, sys
from datetime import datetime, timezone
sf, tmp, nid, nr = sys.argv[1:]
now = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
d = json.load(open(sf))
ns = d['node_states'][nid]
ns.update({'status': 'pending', 'retries': int(nr), 'started_at': None, 'completed_at': None})
d['updated_at'] = now
open(tmp, 'w').write(json.dumps(d, indent=2) + '\n')
os.replace(tmp, sf)
PYEOF
                    _dt_append_event "retried" "${task_id:-null}" "task"
                    log "cmd_dispatch_tasklist: node $node_id retrying (attempt $(( _node_retries + 1 )) of $_node_max_r)"
                else
                    _dt_update_node "$node_id" "failed" "${task_id:-null}" "$result_file"
                    _dt_append_event "escalated_to_oser" "${task_id:-null}" "task"
                    any_failed=true
                    log "cmd_dispatch_tasklist: node $node_id FAILED"
                fi

            else
                _dt_update_node "$node_id" "$node_status" "${task_id:-null}" "$result_file"
                log "cmd_dispatch_tasklist: node $node_id completed"
            fi
        done

        rm -rf "$wave_tmp_dir"
        [[ "$_pushback_break" == "true" ]] && break
    done

    # ---- Final version-level escalation event ----
    _dt_append_event "null" "null" "version"

    rm -f "$node_data_file"
    # Release lock: kill Python lock holder (releases fcntl lock when process exits)
    kill "$_lock_pid" 2>/dev/null || true
    wait "$_lock_pid" 2>/dev/null || true

    log "cmd_dispatch_tasklist: dispatch complete (plan=$plan_id, version=$version_id)"

    if $any_failed; then
        exit 1
    fi
    exit 0
}

# --- supersede-gc ---
