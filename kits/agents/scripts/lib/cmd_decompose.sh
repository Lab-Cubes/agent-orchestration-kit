cmd_decompose() {
    # --help shortcut
    if [[ "${1:-}" == "--help" ]]; then
        cat <<'HELP'
cmd_decompose — Plan → Decomposer → pending task-list

Usage:
  echo "$json_input" | spawn-agent.sh decompose

Input (stdin, JSON):
  {
    "plan":          "<full plan.md content, YAML frontmatter + body>",
    "context":       { "files": [], "knowledge": [], "branch": "main" },
    "prior_version": <task-list JSON of v_N, or null on first emit>,
    "prior_state":   <task-list-state.json at pushback time, or null>,
    "pushback":      "<free-text pushback message, or null>"
  }

Output (stdout on success):
  Absolute path of the written pending/v{N}.json file.

Exit codes:
  0  — success; pending file written, absolute path on stdout
  1  — Decomposer failure (non-zero exit / timeout / schema / semantic / DAG violation);
       decomposer_failed escalation event appended to escalation.jsonl
  2  — Invocation error (bad stdin JSON, missing plan_id, config error)

Config knobs (config.json):
  decomposer_cmd         — command to invoke as Decomposer
                           default: python3 scripts/lib/decomposers/trivial.py
  decomposer_timeout_ms  — max wall-clock ms for Decomposer invocation
                           default: 60000 (60s); exceeded = SIGTERM, 2s grace, SIGKILL

NOP DAG validation (NPS-5 §3.1.1, enforced before writing pending file):
  - Node count <= 32  → violation: NOP-TASK-DAG-TOO-LARGE
  - Acyclic            → violation: NOP-TASK-DAG-CYCLE

Semantic validation (kit invariants, enforced before DAG validation):
  - Task-list plan_id matches input plan frontmatter
      → violation: KIT-DECOMP-PLAN-MISMATCH
  - Task-list version_id == prior_version_id + 1
      → violation: KIT-DECOMP-VERSION-MISMATCH
  - Re-decompose task-list prior_version == input prior_version_id
      → violation: KIT-DECOMP-PRIOR-VERSION-MISMATCH
  - dag.nodes[].id values are unique
      → violation: KIT-DECOMP-NODE-ID-DUPLICATE
  - dag.nodes contains at least one node
      → violation: KIT-DECOMP-DAG-EMPTY
  - dag.edges[].from and dag.edges[].to reference existing node ids
      → violation: KIT-DECOMP-EDGE-PHANTOM
  - dag.nodes[].input_from entries reference existing node ids
      → violation: KIT-DECOMP-INPUT-FROM-PHANTOM
  - dag.nodes[].agent points at a set-up worker
      → violation: KIT-DECOMP-AGENT-NOT-SET-UP
  - dag.nodes[].budget_npt <= max_budget_npt_per_node
      → violation: KIT-DECOMP-BUDGET-EXCESSIVE
  - dag.nodes[].scope is non-empty and contains no empty strings
      → violation: KIT-DECOMP-SCOPE-EMPTY
  - dag.nodes[].scope == ["."] emits a stderr warning, not a violation

Artifacts:
  task-lists/{plan-id}/pending/v{N}.json  — awaiting OSer ack (cmd_ack)
  task-lists/{plan-id}/escalation.jsonl   — append-only JSONL event log

Escalation event dispatcher_acted values:
  invoked_decomposer  — success; pending v{N} written (re-decompose path, N > 1)
  decomposer_failed   — failure; reason in pushback_reason field
HELP
        return 0
    fi

    # --- Read stdin ---
    local raw_input
    raw_input=$(cat)

    # --- Parse plan_id, prior_version_id, and decomposer config from input ---
    # Pass raw_input via env to avoid any stdin-with-heredoc ambiguity.
    local parse_out
    parse_out=$(
        RAW_INPUT="$raw_input" \
        NPS_DEFAULT_DECOMPOSER_CMD="$DEFAULT_DECOMPOSER_CMD" \
        NPS_DEFAULT_DECOMPOSER_TIMEOUT_MS="$DEFAULT_DECOMPOSER_TIMEOUT_MS" \
        python3 - "$CONFIG_FILE" <<'PYEOF'
import json, os, re, sys

raw = os.environ['RAW_INPUT']
try:
    inp = json.loads(raw)
except json.JSONDecodeError as e:
    print(f"ERR=invalid_stdin:{e}")
    sys.exit(0)

plan_text = inp.get("plan", "")
if not isinstance(plan_text, str):
    print("ERR=plan_not_string:")
    sys.exit(0)

fm_match = re.search(r'^---\s*\n(.*?)\n---', plan_text, re.S)
plan_id = ""
if fm_match:
    m = re.search(r'^plan_id:\s*(.+)', fm_match.group(1), re.M)
    if m:
        plan_id = m.group(1).strip()

prior_version = inp.get("prior_version")
prior_version_id = 0
if isinstance(prior_version, dict):
    prior_version_id = int(prior_version.get("version_id", 1))
elif prior_version is not None and str(prior_version).lstrip('-').isdigit():
    prior_version_id = max(0, int(prior_version))

decomposer_cmd = os.environ.get('NPS_DEFAULT_DECOMPOSER_CMD',
                                'python3 scripts/lib/decomposers/trivial.py')
decomposer_timeout_ms = int(os.environ.get('NPS_DEFAULT_DECOMPOSER_TIMEOUT_MS', '60000'))

config_path = sys.argv[1] if len(sys.argv) > 1 else ""
if config_path and os.path.isfile(config_path):
    try:
        d = json.load(open(config_path))
        if 'decomposer_cmd' in d:
            decomposer_cmd = d['decomposer_cmd']
        if 'decomposer_timeout_ms' in d:
            decomposer_timeout_ms = int(d['decomposer_timeout_ms'])
    except Exception:
        pass

print(f"PLAN_ID={plan_id}")
print(f"PRIOR_VERSION_ID={prior_version_id}")
print(f"DECOMPOSER_CMD={decomposer_cmd}")
print(f"DECOMPOSER_TIMEOUT_MS={decomposer_timeout_ms}")
PYEOF
    ) || true

    local plan_id="" prior_version_id="0" decomposer_cmd="" decomposer_timeout_ms=""
    local parse_error=""
    while IFS='=' read -r key value; do
        [[ -z "$key" ]] && continue
        case "$key" in
            ERR)                   parse_error="$value" ;;
            PLAN_ID)               plan_id="$value" ;;
            PRIOR_VERSION_ID)      prior_version_id="$value" ;;
            DECOMPOSER_CMD)        decomposer_cmd="$value" ;;
            DECOMPOSER_TIMEOUT_MS) decomposer_timeout_ms="$value" ;;
        esac
    done <<< "$parse_out"

    if [[ -n "$parse_error" ]]; then
        err "cmd_decompose: stdin parse error: $parse_error"
        exit 2
    fi

    if [[ -z "$plan_id" ]]; then
        err "cmd_decompose: could not extract plan_id from plan frontmatter"
        exit 2
    fi

    # --- Compute paths ---
    local plan_dir="$NPS_TASKLISTS_HOME/$plan_id"
    local pending_dir="$plan_dir/pending"
    local escalation_log="$plan_dir/escalation.jsonl"
    mkdir -p "$pending_dir"

    local next_version=$(( prior_version_id + 1 ))
    local pending_file="$pending_dir/v${next_version}.json"

    log "cmd_decompose: plan=$plan_id, version=$next_version, decomposer=${decomposer_cmd}"

    # --- Invoke Decomposer with timeout ---
    # SIGTERM → 2s grace → SIGKILL via Python timer thread.
    local timeout_s=$(( (decomposer_timeout_ms + 999) / 1000 ))
    local decomposer_exit=0
    local decomposer_stdout=""

    decomposer_stdout=$(
        RAW_INPUT="$raw_input" \
        NPS_DIR="$NPS_DIR" \
        NPS_AGENTS_HOME="$NPS_AGENTS_HOME" \
        ISSUER_DOMAIN="$ISSUER_DOMAIN" \
        python3 - "$NPS_DIR" "$decomposer_cmd" "$timeout_s" <<'PYEOF'
import json, os, shlex, shutil, subprocess, sys, threading

nps_dir        = sys.argv[1]
decomposer_cmd = sys.argv[2]
timeout_s      = int(sys.argv[3])
raw_input      = os.environ['RAW_INPUT']

parts = shlex.split(decomposer_cmd)
if parts and not os.path.isabs(parts[0]) and not shutil.which(parts[0]):
    parts[0] = os.path.join(nps_dir, parts[0])

env = os.environ.copy()
timed_out = threading.Event()

try:
    proc = subprocess.Popen(
        parts, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
        stderr=subprocess.PIPE, text=True, env=env, cwd=nps_dir
    )
except FileNotFoundError as e:
    print(f"DECOMPOSER_LAUNCH_FAILED:{e}", file=sys.stderr)
    sys.exit(126)
except Exception as e:
    print(f"DECOMPOSER_LAUNCH_FAILED:{e}", file=sys.stderr)
    sys.exit(127)

def _timeout_handler():
    timed_out.set()
    try:
        proc.terminate()
    except Exception:
        pass

timer = threading.Timer(timeout_s, _timeout_handler)
timer.start()
try:
    stdout, stderr = proc.communicate(input=raw_input)
    if stderr:
        print(stderr, file=sys.stderr, end='')
finally:
    timer.cancel()

if timed_out.is_set():
    import time
    time.sleep(2)
    try:
        proc.kill()
        proc.wait()
    except Exception:
        pass
    print("__DECOMPOSER_TIMEOUT__", file=sys.stderr)
    sys.exit(124)

if proc.returncode != 0:
    sys.exit(proc.returncode)

print(stdout, end='')
PYEOF
    ) || decomposer_exit=$?

    local now_iso
    now_iso=$(python3 -c "import datetime; print(datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'))")

    # Helper: append escalation event to escalation.jsonl
    _append_decompose_event() {
        local dispatcher_acted="$1"
        local pushback_reason_val="${2:-null}"
        local decomposer_output_version="${3:-null}"
        RAW_EVENT_LOG="$escalation_log" \
        RAW_TIMESTAMP="$now_iso" \
        RAW_PLAN_ID="$plan_id" \
        RAW_PRIOR_VERSION_ID="$prior_version_id" \
        RAW_DISPATCHER_ACTED="$dispatcher_acted" \
        RAW_PUSHBACK_REASON="$pushback_reason_val" \
        RAW_DECOMPOSER_OUTPUT_VERSION="$decomposer_output_version" \
        python3 - <<'PYEOF'
import json, os

log_path              = os.environ['RAW_EVENT_LOG']
timestamp             = os.environ['RAW_TIMESTAMP']
plan_id               = os.environ['RAW_PLAN_ID']
prior_ver_str         = os.environ['RAW_PRIOR_VERSION_ID']
dispatcher_acted      = os.environ['RAW_DISPATCHER_ACTED']
pushback_reason_val   = os.environ['RAW_PUSHBACK_REASON']
decomp_ver_str        = os.environ['RAW_DECOMPOSER_OUTPUT_VERSION']

prior_version = int(prior_ver_str) if prior_ver_str and prior_ver_str != '0' else None
decomposer_output_version = int(decomp_ver_str) if decomp_ver_str and decomp_ver_str.isdigit() else None
pushback_reason = pushback_reason_val if pushback_reason_val and pushback_reason_val != 'null' else None

event = {
    "schema_version": 1,
    "timestamp": timestamp,
    "plan_id": plan_id,
    "prior_version": prior_version,
    "pushback_source": None,
    "pushback_reason": pushback_reason,
    "dispatcher_acted": dispatcher_acted,
    "decomposer_output_version": decomposer_output_version,
    "osi_ack_at": None,
    "osi_ack_verdict": None,
    "osi_ack_by": None,
    "duration_s": None,
    "escalation_level": "version",
}
with open(log_path, 'a') as f:
    f.write(json.dumps(event) + '\n')
PYEOF
    }

    # --- Timeout path ---
    if [[ "$decomposer_exit" -eq 124 ]]; then
        err "cmd_decompose: Decomposer timed out after ${timeout_s}s"
        _append_decompose_event "decomposer_failed" "timeout" "null"
        exit 1
    fi

    # --- Launch failure path ---
    if [[ "$decomposer_exit" -eq 126 || "$decomposer_exit" -eq 127 ]]; then
        err "cmd_decompose: Decomposer failed to launch (exit $decomposer_exit)"
        _append_decompose_event "decomposer_failed" "launch_error" "null"
        exit 1
    fi

    # --- Pushback-refusal path (exit 2 = decomposer cannot handle pushback) ---
    if [[ "$decomposer_exit" -eq 2 ]]; then
        err "cmd_decompose: Decomposer refused pushback (exit 2); escalating to OSer"
        _append_decompose_event "decomposer_failed" "pushback_unsupported" "null"
        exit 1
    fi

    # --- Non-zero exit path ---
    if [[ "$decomposer_exit" -ne 0 ]]; then
        err "cmd_decompose: Decomposer exited with non-zero code: $decomposer_exit"
        _append_decompose_event "decomposer_failed" "non_zero_exit" "null"
        exit 1
    fi

    # --- Parse and normalise stdout JSON ---
    local tmp_output
    tmp_output=$(mktemp)
    local json_parse_exit=0
    RAW_DECOMPOSER_STDOUT="$decomposer_stdout" python3 - "$tmp_output" <<'PYEOF' || json_parse_exit=$?
import json, os, sys
raw = os.environ['RAW_DECOMPOSER_STDOUT'].strip()
if not raw:
    print("error: Decomposer produced empty stdout", file=sys.stderr)
    sys.exit(1)
try:
    obj = json.loads(raw)
except json.JSONDecodeError as e:
    print(f"error: Decomposer stdout is not valid JSON: {e}", file=sys.stderr)
    sys.exit(1)
with open(sys.argv[1], 'w') as f:
    json.dump(obj, f, indent=2)
    f.write('\n')
PYEOF
    if [[ "$json_parse_exit" -ne 0 ]]; then
        rm -f "$tmp_output"
        err "cmd_decompose: Decomposer output is not valid JSON"
        _append_decompose_event "decomposer_failed" "schema_violation" "null"
        exit 1
    fi

    # --- Schema validation ---
    local schema_file="$NPS_DIR/src/schemas/task-list.schema.json"
    local schema_stderr_file
    schema_stderr_file=$(mktemp)
    local schema_exit=0
    python3 "$NPS_DIR/scripts/lib/validate_schema.py" "$schema_file" "$tmp_output" \
        >/dev/null 2>"$schema_stderr_file" || schema_exit=$?
    if [[ "$schema_exit" -ne 0 ]]; then
        while IFS= read -r line; do err "  schema: $line"; done < "$schema_stderr_file"
        rm -f "$schema_stderr_file" "$tmp_output"
        err "cmd_decompose: Decomposer output failed task-list schema validation"
        _append_decompose_event "decomposer_failed" "schema_violation" "null"
        exit 1
    fi
    rm -f "$schema_stderr_file"

    # --- Semantic identity validation (kit invariants) ---
    local max_budget_npt_per_node
    max_budget_npt_per_node=$(
        python3 - "$CONFIG_FILE" <<'PYEOF'
import json, os, sys
config_file = sys.argv[1]
default = 200000
if config_file and os.path.isfile(config_file):
    try:
        value = json.load(open(config_file)).get("max_budget_npt_per_node", default)
    except Exception:
        value = default
else:
    value = default
print(value)
PYEOF
    )
    local semantics_stderr_file
    semantics_stderr_file=$(mktemp)
    local semantics_exit=0
    INPUT_PLAN_ID="$plan_id" PRIOR_VERSION_ID="$prior_version_id" \
        MAX_BUDGET_NPT_PER_NODE="$max_budget_npt_per_node" \
        NPS_AGENTS_HOME="$NPS_AGENTS_HOME" \
        python3 "$NPS_DIR/scripts/lib/validate_tasklist_semantics.py" "$tmp_output" \
        >/dev/null 2>"$semantics_stderr_file" || semantics_exit=$?
    if [[ "$semantics_exit" -ne 0 ]]; then
        local semantic_reason="semantic_violation"
        if [[ "$semantics_exit" -eq 1 ]]; then
            while IFS= read -r line; do err "  semantic: $line"; done < "$semantics_stderr_file"
            semantic_reason=$(python3 - "$semantics_stderr_file" <<'PYEOF'
import sys
for line in open(sys.argv[1]):
    line = line.strip()
    if line and not line.startswith("warning:"):
        print(line.split(':', 1)[0])
        break
else:
    print("semantic_violation")
PYEOF
)
        else
            while IFS= read -r line; do err "  semantic-validator: $line"; done < "$semantics_stderr_file"
        fi
        rm -f "$semantics_stderr_file" "$tmp_output"
        err "cmd_decompose: Decomposer output failed task-list semantic validation"
        _append_decompose_event "decomposer_failed" "$semantic_reason" "null"
        exit 1
    fi
    while IFS= read -r line; do err "  semantic: $line"; done < "$semantics_stderr_file"
    rm -f "$semantics_stderr_file"

    # --- NOP DAG validation (NPS-5 §3.1.1) ---
    local dag_result
    dag_result=$(python3 - "$tmp_output" <<'PYEOF'
import json, sys

data = json.load(open(sys.argv[1]))
dag = data.get('dag', {})
nodes = dag.get('nodes', [])
edges = dag.get('edges', [])

if len(nodes) > 32:
    print(f"NOP-TASK-DAG-TOO-LARGE:{len(nodes)}")
    sys.exit(0)

node_ids = {n['id'] for n in nodes}
adj = {nid: [] for nid in node_ids}
for e in edges:
    src = e.get('from', '')
    dst = e.get('to', '')
    if src in adj:
        adj[src].append(dst)

WHITE, GRAY, BLACK = 0, 1, 2
colour = {nid: WHITE for nid in node_ids}

def has_cycle():
    for start in node_ids:
        if colour[start] != WHITE:
            continue
        stack = [(start, False)]
        while stack:
            node, returning = stack.pop()
            if returning:
                colour[node] = BLACK
                continue
            if colour[node] == GRAY:
                return True
            colour[node] = GRAY
            stack.append((node, True))
            for nbr in adj.get(node, []):
                if colour.get(nbr) == GRAY:
                    return True
                if colour.get(nbr) == WHITE:
                    stack.append((nbr, False))
    return False

if has_cycle():
    print("NOP-TASK-DAG-CYCLE:cycle detected")
    sys.exit(0)

print("OK:")
PYEOF
    ) || dag_result="OK:"
    local dag_check="${dag_result%%:*}"

    if [[ "$dag_check" == "NOP-TASK-DAG-TOO-LARGE" ]]; then
        local dag_count="${dag_result#*:}"
        rm -f "$tmp_output"
        err "cmd_decompose: DAG node count ${dag_count} exceeds maximum (32)"
        _append_decompose_event "decomposer_failed" "NOP-TASK-DAG-TOO-LARGE" "null"
        exit 1
    fi

    if [[ "$dag_check" == "NOP-TASK-DAG-CYCLE" ]]; then
        rm -f "$tmp_output"
        err "cmd_decompose: DAG contains a cycle"
        _append_decompose_event "decomposer_failed" "NOP-TASK-DAG-CYCLE" "null"
        exit 1
    fi

    # --- Write pending file ---
    mv "$tmp_output" "$pending_file"
    log "cmd_decompose: wrote $pending_file"

    # --- Escalation event: invoked_decomposer on every successful invocation ---
    _append_decompose_event "invoked_decomposer" "null" "$next_version"

    # Emit absolute path for pipeline use
    echo "$pending_file"
}

# --- merge ---
