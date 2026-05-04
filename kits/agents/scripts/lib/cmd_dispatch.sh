cmd_dispatch() {
    local agent_id="$1"
    shift
    local intent_text="$1"
    shift

    # Runtime defaults to config; --runtime override parsed from remaining args
    local runtime="$DEFAULT_RUNTIME"
    local _arg
    for _arg in "$@"; do
        if [[ "${_prev_arg:-}" == "--runtime" ]]; then runtime="$_arg"; break; fi
        local _prev_arg="$_arg"
    done

    if [[ "$runtime" == "claude" ]]; then
        if ! claude --help 2>&1 | grep -q -- '--setting-sources'; then
            err "claude CLI missing required --setting-sources flag — upgrade Claude Code CLI"
            exit 1
        fi
    elif [[ "$runtime" == "kiro" ]]; then
        if ! command -v kiro-cli &>/dev/null; then
            err "kiro-cli not found — install Kiro CLI"
            exit 1
        fi
    else
        err "Unknown runtime: $runtime (expected: claude, kiro)"
        exit 1
    fi

    local agent_dir="$NPS_AGENTS_HOME/$agent_id"
    local max_turns="$DEFAULT_MAX_TURNS"
    local time_limit="$DEFAULT_TIME_LIMIT"
    local budget=""
    local shutdown_grace_s="$DEFAULT_SHUTDOWN_GRACE_S"
    local soft_cap_ratio="$DEFAULT_SOFT_CAP_RATIO"
    local model="$DEFAULT_MODEL"
    local scope=""
    local priority="normal"
    local category="code"
    local context_file=""
    local dry_run=false
    local target_branch=""
    local branch_name_override=""
    local plan_id=""
    local success_criteria_file=""

    _disp_budget_for_category() {
        if [[ -f "$CONFIG_FILE" ]]; then
            python3 - "$CONFIG_FILE" "$1" "$DEFAULT_BUDGET_NPT" <<'PYEOF'
import json, sys
config_file, category, fallback = sys.argv[1], sys.argv[2], int(sys.argv[3])
d = json.load(open(config_file))
print(d.get('category_budget_npt', {}).get(category, fallback))
PYEOF
        else
            echo "$DEFAULT_BUDGET_NPT"
        fi
    }

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --max-turns)     max_turns="$2"; shift 2 ;;
            --time-limit)    time_limit="$2"; shift 2 ;;
            --budget)          budget="$2"; shift 2 ;;
            --shutdown-grace-s) shutdown_grace_s="$2"; shift 2 ;;
            --soft-cap-ratio)   soft_cap_ratio="$2"; shift 2 ;;
            --model)           model="$2"; shift 2 ;;
            --scope)         scope="$2"; shift 2 ;;
            --priority)      priority="$2"; shift 2 ;;
            --category)      category="$2"; shift 2 ;;
            --context-file)  context_file="$2"; shift 2 ;;
            --dry-run)       dry_run=true; shift ;;
            --runtime)       runtime="$2"; shift 2 ;;
            --branch-name)   branch_name_override="$2"; shift 2 ;;
            --target-branch) target_branch="$2"; shift 2 ;;
            --plan-id)       plan_id="$2"; shift 2 ;;
            --success-criteria-file) success_criteria_file="$2"; shift 2 ;;
            *) err "Unknown option: $1"; exit 1 ;;
        esac
    done

    [[ -z "$budget" ]] && budget=$(_disp_budget_for_category "$category")

    if [[ ! -d "$agent_dir" ]]; then
        err "Worker not set up: $agent_dir"
        err "Run: spawn-agent.sh setup $agent_id <type>"
        exit 1
    fi

    local timestamp
    timestamp=$(date +%Y%m%d-%H%M%S)
    local task_id="task-${ISSUER}-${timestamp}"

    # Git worktree isolation if scope contains a repo
    local branch_name=""
    local worktree_path=""
    local original_scope="$scope"

    if [[ -n "$scope" ]]; then
        local first_scope="${scope%%,*}"
        # Use rev-parse to detect whether first_scope is inside any git repo —
        # not just a direct .git child. A scope of outer-repo/subdir has no
        # .git entry of its own but is still inside a repo and must be isolated.
        local git_root
        git_root=$(git -C "$first_scope" rev-parse --show-toplevel 2>/dev/null || true)
        if [[ -n "$git_root" ]]; then
            if [[ -z "$target_branch" ]]; then
                target_branch=$(git -C "$first_scope" symbolic-ref --short HEAD 2>/dev/null || true)
                if [[ -z "$target_branch" ]]; then
                    err "Scope repo '$first_scope' is on detached HEAD — pass --target-branch explicitly"
                    exit 1
                fi
            fi
            if [[ -n "$branch_name_override" ]]; then
                branch_name="$branch_name_override"
            else
                branch_name="agent/${agent_id}/${task_id}"
            fi
            worktree_path="$NPS_WORKTREES_HOME/$task_id"
            mkdir -p "$NPS_WORKTREES_HOME"
            if ! $dry_run; then
                log "Creating worktree: $worktree_path (branch: $branch_name)"
                git -C "$git_root" worktree add "$worktree_path" -b "$branch_name" 2>&1 \
                    || { err "Failed to create worktree"; exit 1; }
            fi
            # Map scope to the equivalent subdir inside the worktree.
            # --show-prefix returns "sub/dir/" relative to repo root (empty
            # string when scope IS the root). Using a single git invocation
            # keeps symlink handling consistent — no cd+pwd dance needed.
            local relative_path
            relative_path=$(git -C "$first_scope" rev-parse --show-prefix 2>/dev/null)
            relative_path="${relative_path%/}"   # trim trailing /
            local scope_in_worktree
            if [[ -n "$relative_path" ]]; then
                scope_in_worktree="$worktree_path/$relative_path"
                # The subdir may not exist on the new branch yet — create it
                # so the worker can operate there without an explicit mkdir.
                if ! $dry_run; then
                    mkdir -p "$scope_in_worktree"
                fi
            else
                scope_in_worktree="$worktree_path"
            fi
            scope="${scope/$first_scope/$scope_in_worktree}"
        fi
    fi

    local context_json='{}'
    if [[ -n "$context_file" && -f "$context_file" ]]; then
        context_json=$(cat "$context_file")
    fi

    local intent_file="$agent_dir/inbox/${task_id}.intent.json"
    # Use Python's datetime for real millisecond precision (matches TS
    # dispatch.ts / nop-agent.ts ISOString format; bash `date` on macOS fakes ms).
    local created_at
    created_at=$(python3 -c "import datetime; print(datetime.datetime.now(datetime.timezone.utc).isoformat(timespec='milliseconds').replace('+00:00','Z'))")

    # Write to a temp file first — the intent only lands in inbox/ when we
    # know this is a real dispatch. Dry-run prints and discards the temp file,
    # leaving the mailbox untouched (bug #6 fix).
    local tmp_intent
    tmp_intent=$(mktemp)

    # All operator-controlled values pass via argv or env — never interpolated
    # into Python source. Eliminates injection via crafted intent text, agent
    # IDs, or context paths. `context` payload read from file if supplied.
    python3 - \
        "$intent_text" "$task_id" "$ISSUER_DOMAIN" "$ISSUER" "$agent_id" \
        "$created_at" "$priority" "$category" "$scope" "$model" \
        "$time_limit" "$budget" "$context_json" "$plan_id" "$success_criteria_file" \
        <<'PYEOF' > "$tmp_intent"
import json, os, sys
(_, intent_text, task_id, issuer_domain, issuer, agent_id,
 created_at, priority, category, scope_str, model,
 time_limit, budget, context_json, plan_id, success_criteria_file) = sys.argv

scope_list = [s for s in scope_str.split(',') if s] if scope_str else []

try:
    context = json.loads(context_json) if context_json and context_json.strip() else {}
except json.JSONDecodeError:
    context = {}

intent = {
    '_ncp': 1,
    'type': 'intent',
    'intent': intent_text,
    'confidence': 0.95,
    'payload': {
        '_nop': 1,
        'id': task_id,
        'from': f'urn:nps:agent:{issuer_domain}:{issuer}',
        'to':   f'urn:nps:agent:{issuer_domain}:{agent_id}',
        'created_at': created_at,
        'priority': priority,
        'category': category,
        'mailbox': {'base': './'},
        'context': context,
        'constraints': {
            'model': model,
            'time_limit': int(time_limit),
            'scope': scope_list,
            'budget_npt': int(budget),
        },
    },
}
if plan_id:
    intent['payload']['plan_id'] = plan_id
if success_criteria_file and os.path.isfile(success_criteria_file):
    with open(success_criteria_file) as f:
        intent['payload']['success_criteria'] = json.load(f)
print(json.dumps(intent, indent=2))
PYEOF

    log "Intent created: $task_id"

    if $dry_run; then
        log "DRY RUN — not launching worker"
        cat "$tmp_intent"
        rm -f "$tmp_intent"
        return 0
    fi

    mv "$tmp_intent" "$intent_file"

    # Hook: task claimed (fires when intent lands in inbox, before dispatch)
    run_hook "task-claimed" "$task_id" "$agent_id" "pending" "0"

    local branch_instruction=""
    if [[ -n "$worktree_path" ]]; then
        branch_instruction=" IMPORTANT: Your workspace is at $worktree_path (a git worktree on branch $branch_name). Do all work there. Do NOT push — the operator will squash-merge your branch after review."
    fi
    local prompt="You are $agent_id. Read your CLAUDE.md for identity and protocol. Then use Bash to run 'ls $agent_dir/inbox/' to find tasks. There IS a task waiting: ${task_id}.intent.json — read it, claim via mv to $agent_dir/active/, execute, archive intent to $agent_dir/done/, write result.json to $agent_dir/done/.${branch_instruction}"

    log "Launching worker: $agent_id (model: $model, budget: $budget NPT, time-limit: ${time_limit}s, max-turns: $max_turns)"
    local start_time end_time duration
    start_time=$(date +%s)

    local add_dirs=""
    if [[ -n "$scope" ]]; then
        IFS=',' read -ra scope_paths <<< "$scope"
        for sp in "${scope_paths[@]}"; do
            add_dirs="$add_dirs --add-dir $sp"
        done
    fi

    # Dispatch with wall-clock and NPT budget enforcement.
    # Runs claude with --output-format stream-json; accumulates per-turn token
    # counts from assistant events and terminates the worker via SIGTERM when
    # budget_npt or time_limit is reached. A threading.Timer handles wall-clock
    # so blocked readline() calls are interrupted when the process is killed.
    # Emits a single JSON line mirroring --output-format json so the parse
    # block below needs no changes.
    # For runtimes without --add-dir (e.g. kiro), cd into the worktree
    # so the worker operates on the right files. Claude uses --add-dir
    # and runs from the agent dir (mailbox access).
    local work_dir="$agent_dir"
    if [[ "$runtime" != "claude" && -n "$worktree_path" ]]; then
        work_dir="$worktree_path"
    fi

    local output
    output=$(
        cd "$work_dir" && \
        NPS_DIR="$NPS_DIR" \
        NPS_EXCHANGE_RATES="$NPT_EXCHANGE_RATES_JSON" \
        NPS_SHUTDOWN_GRACE_S="$shutdown_grace_s" \
        NPS_SOFT_CAP_RATIO="$soft_cap_ratio" \
        NPS_PROMPT="$prompt" \
        NPS_MODEL="$model" \
        NPS_MAX_TURNS="$max_turns" \
        NPS_TIME_LIMIT="$time_limit" \
        NPS_BUDGET="$budget" \
        NPS_ADD_DIRS="$add_dirs" \
        NPS_RUNTIME="$runtime" \
        python3 - <<'PYEOF' 2>&1
import json, math, os, signal, subprocess, sys, threading
sys.path.insert(0, os.path.join(os.environ['NPS_DIR'], 'scripts', 'lib'))
from calc_npt import calc_npt, detect_family

prompt          = os.environ['NPS_PROMPT']
model           = os.environ['NPS_MODEL']
max_turns       = int(os.environ['NPS_MAX_TURNS'])
time_limit      = int(os.environ['NPS_TIME_LIMIT'])
budget          = int(os.environ['NPS_BUDGET'])
grace_s         = int(os.environ.get('NPS_SHUTDOWN_GRACE_S', '15'))
soft_cap_ratio  = float(os.environ.get('NPS_SOFT_CAP_RATIO', '0.9'))
soft_cap        = math.ceil(budget * soft_cap_ratio)
add_dirs        = os.environ.get('NPS_ADD_DIRS', '').split()
rates           = json.loads(os.environ.get('NPS_EXCHANGE_RATES', '{}')) or {'unknown': 1.0}
runtime_name    = os.environ.get('NPS_RUNTIME', 'claude')

# Load adapter by runtime name
if runtime_name == 'kiro':
    from adapters.kiro import KiroAdapter
    adapter = KiroAdapter()
else:
    from adapters.claude import ClaudeAdapter
    adapter = ClaudeAdapter()

model_family = adapter.model_family(model)
cmd = adapter.build_cmd(prompt, model, max_turns, add_dirs)

proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                        text=True, bufsize=1)

state = {
    'stop_reason':        'end_turn',
    'accum_npt':          0,
    'graceful_exit':      False,
    'result_event_seen':  False,
    'native': {'input_tokens': 0, 'output_tokens': 0,
               'cache_read_input_tokens': 0, 'cache_creation_input_tokens': 0},
}

def _kill_on_deadline():
    state['stop_reason'] = 'time_limit'
    try:
        proc.terminate()
    except Exception:
        pass

timer = threading.Timer(time_limit, _kill_on_deadline)
timer.start()

events = []
try:
    for raw in proc.stdout:
        event = adapter.parse_event(raw)
        if event is None:
            continue
        events.append(event)
        if adapter.extract_result(event) is not None:
            state['result_event_seen'] = True
        u = adapter.extract_usage(event)
        if u:
            for ch in ('input_tokens', 'output_tokens',
                       'cache_read_input_tokens', 'cache_creation_input_tokens'):
                state['native'][ch] += u.get(ch) or 0
            state['accum_npt'] += calc_npt(u, model_family, rates)
            if state['accum_npt'] >= soft_cap and state['stop_reason'] == 'end_turn':
                state['stop_reason'] = 'soft_cap'
                try:
                    proc.send_signal(adapter.shutdown_signal())
                except Exception:
                    pass
finally:
    timer.cancel()
    if state['stop_reason'] == 'soft_cap':
        try:
            proc.wait(timeout=grace_s)
            state['graceful_exit'] = state['result_event_seen']
        except subprocess.TimeoutExpired:
            try:
                proc.terminate()
            except Exception:
                pass
            try:
                proc.wait(timeout=2)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait()
    else:
        try:
            proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()

forced = state['stop_reason'] == 'time_limit' or \
         (state['stop_reason'] == 'soft_cap' and not state['graceful_exit'])
result_event = None
for e in reversed(events):
    r = adapter.extract_result(e)
    if r is not None:
        result_event = r
        break

if result_event and not forced:
    out = result_event
elif not result_event and not forced and events:
    # Runtime (e.g. kiro-cli) produced output but no structured result event.
    # Synthesize a success result from collected text.
    text_lines = [e.get('content', '') for e in events if e.get('type') == 'text']
    out = {
        'result':             '\n'.join(text_lines)[:2000] if text_lines else 'Worker completed (no structured output)',
        'usage':              state['native'],
        'num_turns':          1,
        'stop_reason':        'end_turn',
        'is_error':           False,
        'permission_denials': [],
    }
else:
    u = (result_event or {}).get('usage') or {}
    out = {
        'result':             f"Worker terminated: {state['stop_reason']}",
        'usage':              u if u else state['native'],
        'num_turns':          (result_event or {}).get('num_turns', 0),
        'stop_reason':        state['stop_reason'],
        'is_error':           True,
        'permission_denials': [],
        '_terminated_npt':    state['accum_npt'],
    }
print(json.dumps(out))
PYEOF
    ) || true

    end_time=$(date +%s)
    duration=$((end_time - start_time))

    echo "$output" > "$agent_dir/done/${task_id}.raw-output.json"

    local clean_json
    clean_json=$(echo "$output" | python3 "$NPS_DIR/scripts/lib/extract_result_json.py")

    local result="NO JSON OUTPUT"
    local cost_npt="0"
    local denials="0"
    local turns="0"
    local stop_reason="?"
    local status_val="error"

    if [[ -n "$clean_json" ]]; then
        # Parse worker result JSON via stdin → tab-separated fields. stdin
        # carries untrusted worker output but it's never parsed as Python or
        # shell code, and the `read` below is `IFS=$'\t'` so newlines/tabs
        # within fields can't corrupt the structure.
        local parse_out
        parse_out=$(CLEAN_JSON="$clean_json" NPS_DIR="$NPS_DIR" NPS_EXCHANGE_RATES="$NPT_EXCHANGE_RATES_JSON" NPS_MODEL="$model" python3 - <<'PYEOF' 2>/dev/null
import json, os, sys
sys.path.insert(0, os.path.join(os.environ['NPS_DIR'], 'scripts', 'lib'))
from calc_npt import calc_npt, detect_family
try:
    d = json.loads(os.environ['CLEAN_JSON'])
except json.JSONDecodeError:
    sys.exit(1)
usage = d.get('usage') or {}
if '_terminated_npt' in d:
    cost_npt_val = d['_terminated_npt']
else:
    rates = json.loads(os.environ.get('NPS_EXCHANGE_RATES', '{}')) or {'unknown': 1.0}
    model_family = detect_family(os.environ.get('NPS_MODEL', ''))
    cost_npt_val = calc_npt(usage, model_family, rates)
fields = [
    str(d.get('result', 'NO RESULT'))[:500].replace('\t', ' ').replace('\n', ' '),
    str(cost_npt_val),
    str(len(d.get('permission_denials') or [])),
    str(d.get('num_turns', 0)),
    str(d.get('stop_reason', '?')),
    'error' if d.get('is_error') else 'success',
]
print('\t'.join(fields))
PYEOF
        ) || true
        if [[ -n "$parse_out" ]]; then
            IFS=$'\t' read -r result cost_npt denials turns stop_reason status_val <<< "$parse_out"
        else
            result="PARSE ERROR"
            status_val="error"
        fi
    else
        warn "No JSON found in worker output"
    fi

    local overshoot_ratio="0.0"
    if [[ "$budget" -gt 0 ]] && [[ "$cost_npt" =~ ^[0-9]+$ ]]; then
        overshoot_ratio=$(python3 -c "print(round($cost_npt / $budget, 4))")
    fi

    log "Worker finished in ${duration}s (cost: ${cost_npt} NPT, turns: $turns, denials: $denials)"
    log "Result: $result"

    # Fallback result.json if worker claimed the task but didn't write one.
    local agent_result="$agent_dir/done/${task_id}.result.json"
    local intent_in_inbox="$agent_dir/inbox/${task_id}.intent.json"
    if [[ -f "$intent_in_inbox" && ! -f "$agent_result" ]]; then
        err "KIT-DISPATCH-NO-LIFECYCLE: worker did not claim intent (still in inbox/)"
        err "  Raw output preserved: $agent_dir/done/${task_id}.raw-output.json"
        err "  Likely cause: kit-side dispatch bug, runtime crash before claim,"
        err "  or malformed worker prompt. Investigate before retrying."
        mv "$intent_in_inbox" "$agent_dir/done/${task_id}.unclaimed.intent.json"
        return 1
    fi
    if [[ ! -f "$agent_result" ]]; then
        warn "Worker claimed intent but did not write result.json — generating fallback"
        local completed_at
        completed_at=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)
        python3 - "$task_id" "$status_val" "$agent_id" "$created_at" "$completed_at" \
            "$duration" "$cost_npt" "$turns" "$stop_reason" "$ISSUER_DOMAIN" "$result" "$plan_id" << 'PYEOF' > "$agent_result" 2>/dev/null
import json, sys
_, task_id, status_val, agent_id, picked_up, completed, duration, cost_npt, turns, stop, issuer_domain, worker_result, plan_id = sys.argv
fallback_value = worker_result if worker_result and worker_result not in ('NO JSON OUTPUT', 'NO RESULT', 'PARSE ERROR') else f"Fallback result (worker did not complete NOP lifecycle). Stop reason: {stop}. Check raw-output.json."
result = {
    "_ncp": 1,
    "type": "result",
    "value": fallback_value,
    "probability": 0.5,
    "alternatives": [],
    "payload": {
        "_nop": 1,
        "id": task_id,
        "status": "completed" if status_val == "success" else ("timeout" if stop == "time_limit" else "failed"),
        "from": f"urn:nps:agent:{issuer_domain}:{agent_id}",
        "picked_up_at": picked_up,
        "completed_at": completed,
        "duration": int(duration) if duration.isdigit() else 0,
        "cost_npt": int(cost_npt) if str(cost_npt).isdigit() else 0,
        "files_changed": [],
        "commits": [],
        "follow_up": ["Review raw-output.json — worker may have hit limit before writing result"],
        "error": None if status_val == "success" else f"Worker terminated: {stop}",
        "_fallback": True,
        "_turns": int(turns) if turns != "?" else 0,
        "_stop_reason": stop
    }
}
if plan_id:
    result["payload"]["plan_id"] = plan_id
print(json.dumps(result, indent=2))
PYEOF
    fi

    # Task-list dispatch owns the plan boundary. Workers may omit the optional
    # back-pointer, so stamp it before merge-hold reads result.payload.plan_id.
    if [[ -n "$plan_id" && -f "$agent_result" ]]; then
        RESULT_FILE="$agent_result" PLAN_ID="$plan_id" python3 - <<'PYEOF' 2>/dev/null || true
import json, os
path = os.environ['RESULT_FILE']
d = json.load(open(path))
d.setdefault('payload', {})['plan_id'] = os.environ['PLAN_ID']
open(path, 'w').write(json.dumps(d, indent=2) + '\n')
PYEOF
    fi

    # --- result.json validation (#90): reject worker-written malformed files ---
    RESULT_PATH="$agent_result" python3 -c "
import json, os, sys
try:
    d = json.load(open(os.environ['RESULT_PATH']))
    assert '_ncp' in d and 'payload' in d and '_nop' in d.get('payload', {})
except Exception:
    sys.exit(1)
" 2>/dev/null || { warn "result.json invalid or missing required fields — marking error"; status_val="error"; }

    # --- Result identity binding (#205): result must belong to this dispatch ---
    if [[ -f "$agent_result" ]]; then
        local result_identity_error=""
        result_identity_error=$(RESULT_FILE="$agent_result" TASK_ID="$task_id" EXPECTED_FROM="urn:nps:agent:${ISSUER_DOMAIN}:${agent_id}" python3 - <<'PYEOF' 2>/dev/null
import json, os, sys
path = os.environ['RESULT_FILE']
expected_id = os.environ['TASK_ID']
expected_from = os.environ['EXPECTED_FROM']
d = json.load(open(path))
p = d.get('payload') or {}
errors = []
if p.get('id') != expected_id:
    errors.append(f"payload.id {p.get('id')!r} does not match task_id {expected_id!r}")
if p.get('from') != expected_from:
    errors.append(f"payload.from {p.get('from')!r} does not match worker NID {expected_from!r}")
if errors:
    p['status'] = 'failed'
    p['error'] = (p.get('error') or '') + ' RESULT IDENTITY VIOLATION: ' + '; '.join(errors)
    p['_identity_violation'] = True
    d['payload'] = p
    open(path, 'w').write(json.dumps(d, indent=2) + '\n')
    print('\n'.join(errors))
PYEOF
        ) || true
        if [[ -n "$result_identity_error" ]]; then
            warn "RESULT IDENTITY VIOLATION:"
            while IFS= read -r v; do
                warn "  - $v"
            done <<< "$result_identity_error"
            status_val="error"
        fi
    fi

    # --- Scope validation (#34): reject files_changed outside constraints.scope ---
    if [[ -n "$original_scope" && -f "$agent_result" ]]; then
        local scope_violations=""
        scope_violations=$(RESULT_FILE="$agent_result" SCOPE="$original_scope" python3 - <<'PYEOF' 2>/dev/null
import json, os, sys
result = json.load(open(os.environ['RESULT_FILE']))
files_changed = result.get('payload', {}).get('files_changed') or []
scope_str = os.environ['SCOPE']
scope_paths = [os.path.realpath(s) for s in scope_str.split(',') if s]
violations = []
for f in files_changed:
    real_f = os.path.realpath(f)
    if not any(real_f == s or real_f.startswith(s + os.sep) for s in scope_paths):
        violations.append(f)
if violations:
    print('\n'.join(violations))
PYEOF
        ) || true
        if [[ -n "$scope_violations" ]]; then
            warn "SCOPE VIOLATION: files_changed outside constraints.scope:"
            while IFS= read -r v; do
                warn "  - $v"
            done <<< "$scope_violations"
            # CSV status_val='error' is the operator-facing dispatch outcome
            # (matches the existing error/success convention in the CSV schema).
            # result.json payload.status='failed' is the NOP wire-protocol status
            # (must be a valid TaskStatus enum value per NPS-5 §4).
            status_val="error"
            RESULT_FILE="$agent_result" python3 - <<'PYEOF' 2>/dev/null
import json, os
path = os.environ['RESULT_FILE']
d = json.load(open(path))
d['payload']['error'] = (d['payload'].get('error') or '') + ' SCOPE VIOLATION: files_changed outside constraints.scope'
d['payload']['status'] = 'failed'
d['payload']['_scope_violation'] = True
open(path, 'w').write(json.dumps(d, indent=2) + '\n')
PYEOF
        fi
    fi

    # Append to cost log (CSV)
    mkdir -p "$(dirname "$COST_LOG")"
    if [[ ! -f "$COST_LOG" ]]; then
        echo "timestamp,task_id,agent_id,model,category,priority,budget_npt,cost_npt,turns,duration_s,denials,status,overshoot_ratio" > "$COST_LOG"
    fi
    printf '"%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s"\n' \
        "$created_at" "$task_id" "$agent_id" "$model" "$category" "$priority" \
        "$budget" "$cost_npt" "$turns" "$duration" "$denials" "$status_val" "$overshoot_ratio" >> "$COST_LOG"

    # Hook: task completed, timed out, or failed
    if [[ "$status_val" == "success" ]]; then
        run_hook "task-completed" "$task_id" "$agent_id" "completed" "$cost_npt"
    elif [[ "$stop_reason" == "time_limit" ]]; then
        run_hook "task-failed" "$task_id" "$agent_id" "timeout" "$cost_npt"
    else
        run_hook "task-failed" "$task_id" "$agent_id" "failed" "$cost_npt"
    fi

    # Worktree metadata for merge command
    if [[ -n "$worktree_path" ]]; then
        python3 - "$task_id" "$agent_id" "$branch_name" "$worktree_path" \
            "$original_scope" "$status_val" "$target_branch" << 'PYEOF' > "$agent_dir/done/${task_id}.branch.json" 2>/dev/null
import json, sys
_, task_id, agent_id, branch, worktree, scope, status, target_branch = sys.argv
print(json.dumps({
    "task_id": task_id, "agent_id": agent_id, "branch": branch,
    "worktree": worktree, "original_scope": scope, "status": status,
    "target_branch": target_branch
}, indent=2))
PYEOF
        log "Branch: $branch_name"
        log "Merge with: spawn-agent.sh merge $task_id"
    fi

    return 0
}

# --- status ---
