#!/usr/bin/env bash
# spawn-agent.sh — NOP worker lifecycle manager
#
# Part of @nps-kit/agents — reference implementation of NPS-5 NOP using Claude Code.
# Wraps a Claude Code instance as a NOP worker: creates the mailbox, writes the
# task intent, dispatches, captures the result, optionally merges the worker's
# git worktree.
#
# Apache 2.0 — see LICENSE at repo root.
#
# Usage:
#   spawn-agent.sh setup    <agent-id> <agent-type>     # create worker dir + CLAUDE.md
#   spawn-agent.sh dispatch <agent-id> "<intent>" [opts] # launch worker on a task
#   spawn-agent.sh status   <agent-id>                   # show mailbox state + latest result
#   spawn-agent.sh clean    <agent-id>                   # remove stale artifacts
#   spawn-agent.sh merge    <task-id> ["commit msg"] [--no-push]
#
# Dispatch options:
#   --budget NPT        Max NPT to spend (default: category-based, from config.json)
#   --max-turns N       Safety net turn limit
#   --time-limit N      Safety net wall-clock seconds
#   --model MODEL       Model override (default: sonnet)
#   --scope PATH,...    Comma-separated scope paths
#   --priority LEVEL    urgent|normal|low (default: normal)
#   --category CAT      Task category (default: code)
#   --context-file F    JSON file with extra context
#   --dry-run           Print intent JSON without launching
#   --target-branch B   Merge target branch (default: auto-detect)

set -euo pipefail

# --- Paths (env-var driven; defaults work out-of-box) ---
#
# Runtime state (agents, worktrees, logs) defaults to $HOME/.nps-kit/ (or
# $XDG_STATE_HOME/nps-kit on Linux systems that set XDG_STATE_HOME). Lives
# OUTSIDE the cloned kit repo: if the worker's mailbox sat inside, a
# `git commit` from the worker would walk up, find the kit's .git, and
# land accidental commits on the kit's branches. User state lives in $HOME;
# the kit repo stays code-only.
#
# Precedence, highest to lowest:
#   1. NPS_AGENTS_HOME / NPS_WORKTREES_HOME / NPS_LOGS_HOME — individual overrides
#   2. NPS_STATE_HOME — override the root for all three at once
#   3. XDG_STATE_HOME (Linux convention) — $XDG_STATE_HOME/nps-kit
#   4. Fallback — $HOME/.nps-kit
#
# Cross-platform: $HOME is set by macOS, Linux, WSL, Git Bash, MSYS2, and
# Cygwin — all bash-capable environments. Native Windows PowerShell/cmd
# can't run this script anyway.
NPS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
if [[ -n "${NPS_STATE_HOME:-}" ]]; then
    NPS_STATE_HOME_DEFAULT="$NPS_STATE_HOME"
elif [[ -n "${XDG_STATE_HOME:-}" ]]; then
    NPS_STATE_HOME_DEFAULT="$XDG_STATE_HOME/nps-kit"
else
    NPS_STATE_HOME_DEFAULT="$HOME/.nps-kit"
fi
NPS_AGENTS_HOME="${NPS_AGENTS_HOME:-$NPS_STATE_HOME_DEFAULT/agents}"
NPS_WORKTREES_HOME="${NPS_WORKTREES_HOME:-$NPS_STATE_HOME_DEFAULT/worktrees}"
NPS_LOGS_HOME="${NPS_LOGS_HOME:-$NPS_STATE_HOME_DEFAULT/logs}"
NPS_TASKLISTS_HOME="${NPS_TASKLISTS_HOME:-$NPS_STATE_HOME_DEFAULT/task-lists}"
NPS_PLANS_HOME="${NPS_PLANS_HOME:-$NPS_STATE_HOME_DEFAULT/plans}"
COST_LOG="$NPS_LOGS_HOME/dispatch-costs.csv"
TEMPLATE="$NPS_DIR/templates/AGENT-CLAUDE.md"
HOOKS_DIR="$NPS_DIR/hooks"
PERSONAS_DIR="$NPS_DIR/templates/personas"

# --- Config (from config.json if present, else defaults) ---
# Defaults here; overridden below if config.json exists. Using env vars read
# by Python (not string interpolation into Python source) avoids injection
# if config path or values contain shell or Python metacharacters.
CONFIG_FILE="$NPS_DIR/config.json"
ISSUER_DOMAIN="dev.localhost"
ISSUER="operator"
DEFAULT_MODEL="sonnet"
DEFAULT_TIME_LIMIT=900
DEFAULT_MAX_TURNS=100
DEFAULT_BUDGET_NPT=20000
DEFAULT_SHUTDOWN_GRACE_S=15
DEFAULT_SOFT_CAP_RATIO=0.9
DEFAULT_RUNTIME="claude"
NPT_EXCHANGE_RATES_JSON='{"unknown":1.0}'
DEFAULT_DECOMPOSER_CMD="python3 scripts/lib/decomposers/trivial.py"
DEFAULT_DECOMPOSER_TIMEOUT_MS=60000
MERGE_HOLD_ENFORCE=true

if [[ -f "$CONFIG_FILE" ]]; then
    if ! python3 "$NPS_DIR/scripts/lib/validate_config.py" "$CONFIG_FILE" >&2; then
        err "config.json validation failed — see errors above"
        exit 1
    fi
    # Python reads the config path from argv and emits one KEY=value per line.
    # Bash reads back via a safe while loop, no eval.
    while IFS='=' read -r key value; do
        [[ -z "$key" ]] && continue
        declare "$key"="$value"
    done < <(python3 - "$CONFIG_FILE" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
print(f"ISSUER_DOMAIN={d.get('issuer_domain', 'dev.localhost')}")
print(f"ISSUER={d.get('issuer_agent_id', 'operator')}")
print(f"DEFAULT_MODEL={d.get('default_model', 'sonnet')}")
print(f"DEFAULT_TIME_LIMIT={d.get('default_time_limit_s', 900)}")
print(f"DEFAULT_MAX_TURNS={d.get('default_max_turns', 100)}")
print(f"DEFAULT_BUDGET_NPT={d.get('default_budget_npt', 40000)}")
print(f"DEFAULT_SHUTDOWN_GRACE_S={d.get('default_shutdown_grace_s', 15)}")
print(f"DEFAULT_SOFT_CAP_RATIO={d.get('default_soft_cap_ratio', 0.9)}")
print(f"DEFAULT_RUNTIME={d.get('runtime', 'claude')}")
_raw = d.get('npt_exchange_rates') or dict()
_rates = dict((k, v) for k, v in _raw.items() if not k.startswith('$'))
_fallback = dict((('unknown', 1.0),))
print(f"NPT_EXCHANGE_RATES_JSON={json.dumps(_rates or _fallback)}")
print(f"DEFAULT_DECOMPOSER_CMD={d.get('decomposer_cmd', 'python3 scripts/lib/decomposers/trivial.py')}")
print(f"DEFAULT_DECOMPOSER_TIMEOUT_MS={d.get('decomposer_timeout_ms', 60000)}")
print(f"MERGE_HOLD_ENFORCE={'true' if d.get('merge_hold_enforce', True) else 'false'}")
PYEOF
)
fi

# --- Colours ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[nps]${NC} $*"; }
warn() { echo -e "${YELLOW}[nps]${NC} $*"; }
err()  { echo -e "${RED}[nps]${NC} $*" >&2; }

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

# --- setup ---
cmd_setup() {
    local agent_id="$1"
    local agent_type="${2:-coder}"
    local agent_dir="$NPS_AGENTS_HOME/$agent_id"
    local persona_file="$PERSONAS_DIR/$agent_type.md"

    if [[ ! -f "$persona_file" ]]; then
        err "No persona template: $persona_file"
        err "Available types: $(ls "$PERSONAS_DIR/" 2>/dev/null | sed 's/\.md$//' | tr '\n' ' ')"
        exit 1
    fi

    log "Setting up worker: $agent_id (type: $agent_type)"

    mkdir -p "$agent_dir"/{inbox,active,done,blocked,.claude}

    # One Python pass: read persona + template from argv, do all substitutions,
    # write the assembled CLAUDE.md. Fixes (a) sed -i '' macOS-only issue and
    # (b) every Python-string-interpolation injection by passing all values
    # through argv (never parsed as Python code).
    local assembled="$agent_dir/CLAUDE.md"
    local settings_json="$agent_dir/.claude/settings.json"
    python3 - \
        "$persona_file" "$TEMPLATE" "$assembled" \
        "$agent_id" "$agent_type" \
        "${DEFAULT_MODEL}" "$ISSUER_DOMAIN" "$ISSUER" \
        "$settings_json" \
        <<'PYEOF'
import re, sys, json
persona_file, template_file, out_file, agent_id, agent_type, default_model, issuer_domain, issuer, settings_path = sys.argv[1:]

persona = open(persona_file).read()

def kv(key):
    m = re.search(r'^' + key + r':\s*(.+)', persona, re.M)
    return m.group(1).strip() if m else ''

def section(name):
    pattern = r'^## ' + re.escape(name) + r'\n(.*?)(?=^## |\Z)'
    m = re.search(pattern, persona, re.M | re.S)
    return m.group(1).strip() if m else ''

model = kv('MODEL') or default_model
capabilities = kv('CAPABILITIES') or 'nop:execute'
run_mode = kv('RUN_MODE') or 'single-shot'
default_scope = section('Default Scope')
tools_section = section('Tools Section')
agent_instructions = section('Agent Instructions')

subs = {
    '{{AGENT_ID}}':       agent_id,
    '{{AGENT_TYPE}}':     agent_type,
    '{{MODEL}}':          model,
    '{{ISSUER_DOMAIN}}':  issuer_domain,
    '{{ISSUER}}':         issuer,
    '{{CAPABILITIES}}':   capabilities,
    '{{INBOX_PATH}}':     './inbox/',
    '{{RUN_MODE}}':       run_mode,
    '{{DEFAULT_SCOPE}}':  default_scope,
    '{{TOOLS_SECTION}}':  tools_section,
    '{{AGENT_INSTRUCTIONS}}': agent_instructions,
}

content = open(template_file).read()
for placeholder, replacement in subs.items():
    content = content.replace(placeholder, replacement)

open(out_file, 'w').write(content)

# Parse ## Permissions section and write persona-specific settings.json
perm_block = section('Permissions')
allow, deny = [], []
current = None
for line in perm_block.split('\n'):
    stripped = line.strip()
    if stripped.lower().startswith('allow:'):
        current = allow
    elif stripped.lower().startswith('deny:'):
        current = deny
    elif stripped.startswith('- ') and current is not None:
        current.append(stripped[2:].strip())
open(settings_path, 'w').write(json.dumps({'permissions': {'allow': allow, 'deny': deny}}, indent=2) + '\n')
PYEOF

    log "Worker $agent_id ready at $agent_dir"
    log "Mailbox: inbox/ active/ done/ blocked/"
}

# --- dispatch ---
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

    _budget_for_category() {
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
            *) err "Unknown option: $1"; exit 1 ;;
        esac
    done

    [[ -z "$budget" ]] && budget=$(_budget_for_category "$category")

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
        "$time_limit" "$budget" "$context_json" \
        <<'PYEOF' > "$tmp_intent"
import json, sys
(_, intent_text, task_id, issuer_domain, issuer, agent_id,
 created_at, priority, category, scope_str, model,
 time_limit, budget, context_json) = sys.argv

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

    # Fallback result.json if worker didn't write one
    local agent_result="$agent_dir/done/${task_id}.result.json"
    if [[ ! -f "$agent_result" ]]; then
        warn "Worker did not write result.json — generating fallback"
        local completed_at
        completed_at=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)
        python3 - "$task_id" "$status_val" "$agent_id" "$created_at" "$completed_at" \
            "$duration" "$cost_npt" "$turns" "$stop_reason" "$ISSUER_DOMAIN" "$result" << 'PYEOF' > "$agent_result" 2>/dev/null
import json, sys
_, task_id, status_val, agent_id, picked_up, completed, duration, cost_npt, turns, stop, issuer_domain, worker_result = sys.argv
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
print(json.dumps(result, indent=2))
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
# output against task-list.schema.json and NOP DAG constraints, writes
# task-lists/{plan-id}/pending/v{N}.json, and appends an escalation event.
# Emits the absolute path of the written pending file on stdout.
#
# Exit codes:
#   0  — success; pending file written, path on stdout
#   1  — failure (non-zero decomposer exit / timeout / schema violation /
#          DAG violation); decomposer_failed escalation event appended
#   2  — invocation error (bad stdin JSON, missing plan_id, config error)
#
# Usage: echo "$json_input" | spawn-agent.sh decompose [--help]
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
  1  — Decomposer failure (non-zero exit / timeout / schema / DAG violation);
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
    local schema_exit=0
    python3 "$NPS_DIR/scripts/lib/validate_schema.py" "$schema_file" "$tmp_output" 2>&1 \
        | while IFS= read -r line; do err "  schema: $line"; done || true
    python3 "$NPS_DIR/scripts/lib/validate_schema.py" "$schema_file" "$tmp_output" >/dev/null 2>&1 \
        || schema_exit=$?
    if [[ "$schema_exit" -ne 0 ]]; then
        rm -f "$tmp_output"
        err "cmd_decompose: Decomposer output failed task-list schema validation"
        _append_decompose_event "decomposer_failed" "schema_violation" "null"
        exit 1
    fi

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
cmd_merge() {
    local task_id="$1"; shift
    local message=""
    local do_push=true
    local force_merge=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --no-push)     do_push=false; shift ;;
            --force-merge) force_merge=true; shift ;;
            *)             message="$1"; shift ;;
        esac
    done

    local branch_file=""
    for wdir in "$NPS_AGENTS_HOME"/*/done/; do
        if [[ -f "${wdir}${task_id}.branch.json" ]]; then
            branch_file="${wdir}${task_id}.branch.json"; break
        fi
    done
    if [[ -z "$branch_file" ]]; then err "No branch metadata for $task_id"; exit 1; fi

    local branch="" worktree="" original_scope="" agent_id="" target_branch=""
    local meta_out
    meta_out=$(python3 - "$branch_file" <<'PYEOF' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
print('\t'.join([
    d.get('branch', ''),
    d.get('worktree', ''),
    d.get('original_scope', ''),
    d.get('agent_id', ''),
    d.get('target_branch', 'main'),
]))
PYEOF
    ) || true
    if [[ -n "$meta_out" ]]; then
        IFS=$'\t' read -r branch worktree original_scope agent_id target_branch <<< "$meta_out"
    fi

    if [[ -z "$branch" || -z "$original_scope" ]]; then err "Invalid branch metadata"; exit 1; fi

    # ---- Merge-hold gate ----
    # Check plan_id from the task's result file; solo-intent tasks (no plan_id) bypass.
    local task_plan_id=""
    local result_file="$NPS_AGENTS_HOME/$agent_id/done/${task_id}.result.json"
    if [[ -f "$result_file" ]]; then
        task_plan_id=$(python3 - "$result_file" <<'PYEOF' 2>/dev/null
import json, sys
try:
    print(json.load(open(sys.argv[1])).get('payload', {}).get('plan_id') or '')
except Exception:
    print('')
PYEOF
        ) || true
    fi

    if [[ -n "$task_plan_id" ]]; then
        local state_file="$NPS_TASKLISTS_HOME/$task_plan_id/task-list-state.json"
        if [[ ! -f "$state_file" ]]; then
            warn "merge-hold: no task-list-state.json for plan $task_plan_id — bypassing hold check"
        else
            local hold_check
            hold_check=$(python3 - "$state_file" <<'PYEOF' 2>/dev/null
import json, sys
s = json.load(open(sys.argv[1]))
terminal = {'completed', 'failed', 'cancelled', 'timeout', 'superseded'}
if not s.get('merge_hold', True):
    print('OK')
    raise SystemExit(0)
non_terminal = [(nid, ns['status']) for nid, ns in s['node_states'].items()
                if ns['status'] not in terminal]
if non_terminal:
    for nid, st in non_terminal:
        print(f'BLOCKED\t{nid}\t{st}')
else:
    print('OK')
PYEOF
            ) || true

            if [[ "$hold_check" != "OK" ]]; then
                if [[ "$MERGE_HOLD_ENFORCE" != "true" ]]; then
                    if [[ "$force_merge" != "true" ]]; then
                        err "merge_hold_enforce=false but --force-merge not passed; add --force-merge to override"
                        err "Non-terminal nodes in plan $task_plan_id:"
                        while IFS=$'\t' read -r _ nid st; do
                            [[ "$nid" == "BLOCKED" ]] && continue
                            err "  $nid: $st"
                        done <<< "$hold_check"
                        exit 1
                    fi
                    warn "merge_hold_enforce=false; manual ack required (--force-merge passed for task $task_id)"
                    # Escalation event: manual_merge_override
                    python3 - "$NPS_TASKLISTS_HOME/$task_plan_id/escalation.jsonl" \
                        "$task_plan_id" "$task_id" <<'PYEOF' 2>/dev/null || true
import json, os, sys
from datetime import datetime, timezone
log_p, plan_id, task_id = sys.argv[1:]
now = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
event = {
    "schema_version": 1, "timestamp": now, "plan_id": plan_id,
    "prior_version": None, "pushback_source": task_id,
    "pushback_reason": None, "dispatcher_acted": "manual_merge_override",
    "decomposer_output_version": None, "osi_ack_at": None,
    "osi_ack_verdict": None, "osi_ack_by": None,
    "duration_s": None, "escalation_level": "task",
}
os.makedirs(os.path.dirname(os.path.abspath(log_p)), exist_ok=True)
with open(log_p, 'a') as f:
    f.write(json.dumps(event) + '\n')
PYEOF
                else
                    err "merge-hold: task-list for plan $task_plan_id is not fully green"
                    err "Non-terminal nodes (must be completed|failed|cancelled|timeout|superseded):"
                    while IFS=$'\t' read -r tag nid st; do
                        [[ "$tag" == "BLOCKED" ]] && err "  $nid: $st"
                    done <<< "$hold_check"
                    exit 1
                fi
            fi
        fi
    fi

    git -C "$original_scope" config user.name > /dev/null 2>&1 && \
        git -C "$original_scope" config user.email > /dev/null 2>&1 || {
        err "git user.name and user.email must be configured before merging"
        err "  git config --global user.name 'Your Name'"
        err "  git config --global user.email 'you@example.com'"
        exit 1
    }

    log "Merging $task_id from $branch into $target_branch"
    echo ""; echo "Commits:"; git -C "$original_scope" log --oneline "$target_branch..$branch" 2>/dev/null || true
    echo ""; echo "Files:"; git -C "$original_scope" diff --stat "$target_branch..$branch" 2>/dev/null || true; echo ""

    if [[ -z "$message" ]]; then
        local count
        count=$(git -C "$original_scope" rev-list --count "$target_branch..$branch" 2>/dev/null || echo "0")
        message="squash($agent_id): $task_id — ${count} commits merged"
    fi

    git -C "$original_scope" checkout "$target_branch" 2>/dev/null || { err "Checkout failed"; exit 1; }
    git -C "$original_scope" merge --squash "$branch" 2>/dev/null || { err "Squash merge failed"; exit 1; }
    git -C "$original_scope" commit -m "$message" 2>/dev/null || warn "Nothing to commit"
    $do_push && (git -C "$original_scope" push 2>/dev/null || warn "Push failed")

    [[ -d "$worktree" ]] && git -C "$original_scope" worktree remove "$worktree" --force 2>/dev/null || true
    git -C "$original_scope" branch -D "$branch" 2>/dev/null || true
    log "Merge complete"
}

# --- ack ---
# cmd_ack [--reject] [--as <nid>] [--reason <text>] <plan-id> <version>
#
# OSer gate between Decompose and Dispatch: approve or reject a pending
# task-list version. Approve = POSIX-atomic rename pending/v{N}.json →
# v{N}.json + escalation event. Reject = keep pending + escalation event.
#
# Mid-drain guard: refuses to ack version N if active_version != N-1.
# Prevents skipping versions while a prior version is still draining.
#
# See architecture.md §6.1 for the pending-ack protocol.
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
    if command -v python3 >/dev/null 2>&1 && [[ -f "$validator_script" ]] && [[ -f "$schema_file" ]]; then
        if ! python3 "$validator_script" "$schema_file" "$pending_file" 2>&1; then
            err "cmd_ack: schema validation failed for $pending_file"
            err "  Rename aborted. Fix the task-list or use --reject."
            exit 1
        fi
    else
        warn "cmd_ack: schema validator unavailable — skipping validation"
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
    print(f"NODE={n['id']}{SEP}{agent_id}{SEP}{n['action']}{SEP}{scope_csv}{SEP}{n['budget_npt']}{SEP}{timeout_s}")
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
                IFS=$'\037' read -r nid agent_id action scope_csv budget timeout_s \
                    <<< "${line#NODE=}"
                node_ids+=("$nid")
                _agents+=("$agent_id")
                _actions+=("$action")
                _scopes+=("$scope_csv")
                _budgets+=("$budget")
                _timeouts+=("$timeout_s")
                # Also write tab-delimited to node_data_file for awk-based lookups
                printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
                    "$nid" "$agent_id" "$action" "$scope_csv" "$budget" "$timeout_s" \
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
    # Args: dispatcher_acted_or_null  pushback_source_or_null  escalation_level  [prior_version_or_null]
    _dt_append_event() {
        python3 - "$escalation_log" "$plan_id" "$version_id" "$1" "$2" "$3" "${4:-null}" <<'PYEOF'
import json, os, sys
from datetime import datetime, timezone
log_p, plan_id, ver_str, disp_acted, pb_src, level, prior_ver = sys.argv[1:]
now = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
event = {
    "schema_version": 1,
    "timestamp": now,
    "plan_id": plan_id,
    "prior_version": None if prior_ver == 'null' else int(prior_ver),
    "pushback_source": None if pb_src == 'null' else pb_src,
    "pushback_reason": None,
    "dispatcher_acted": None if disp_acted == 'null' else disp_acted,
    "decomposer_output_version": int(ver_str) if ver_str.isdigit() else None,
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
            # No runnable nodes and not yet terminal → failed deps block progress
            err "cmd_dispatch_tasklist: no runnable nodes — blocked by failed dependency"
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

            local -a dispatch_args=("$agent_id" "$action" \
                "--budget" "$budget" "--time-limit" "$timeout_s")
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

            # Determine node outcome from result payload
            local node_status="failed"
            if [[ "$result_file" != "null" ]]; then
                node_status=$(python3 - "$result_file" <<'PYEOF'
import json, sys
try:
    p = json.load(open(sys.argv[1])).get('payload', {})
    print('completed' if p.get('status') == 'completed' else 'failed')
except Exception:
    print('failed')
PYEOF
                )
            fi

            _dt_update_node "$node_id" "$node_status" "${task_id:-null}" "$result_file"

            if [[ "$node_status" == "failed" ]]; then
                any_failed=true
                _dt_append_event "escalated_to_oser" "${task_id:-null}" "task"
                log "cmd_dispatch_tasklist: node $node_id FAILED"
            else
                log "cmd_dispatch_tasklist: node $node_id completed"
            fi
        done

        rm -rf "$wave_tmp_dir"
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
cmd_supersede_gc() {
    local opt_list=false opt_dry_run=false opt_older_than="" opt_plan_id=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --list)         opt_list=true ;;
            --dry-run)      opt_dry_run=true ;;
            --older-than=*) opt_older_than="${1#*=}" ;;
            --plan-id=*)    opt_plan_id="${1#*=}" ;;
            --help|-h)
                echo "supersede-gc — enumerate or remove superseded worktrees"
                echo ""
                echo "Usage: spawn-agent.sh supersede-gc [--list] [--older-than=DAYS]"
                echo "                                   [--dry-run] [--plan-id=PLAN-ID]"
                echo ""
                echo "Flags:"
                echo "  --list              List superseded worktrees with ages (default when no flags)"
                echo "  --older-than=DAYS   Remove worktrees older than DAYS days"
                echo "  --dry-run           Print what would be removed without acting"
                echo "  --plan-id=PLAN-ID   Scope cleanup to a single plan"
                return 0
                ;;
            *)
                err "supersede-gc: unknown flag: $1"
                return 1
                ;;
        esac
        shift
    done

    # Default (no action flags) = --list
    if [[ -z "$opt_older_than" && "$opt_list" == "false" ]]; then
        opt_list=true
    fi

    # Portable mtime: macOS stat -f %m; Linux stat -c %Y
    local _stat_mtime_cmd
    if [[ "$(uname)" == "Darwin" ]]; then
        _stat_mtime_cmd="stat -f %m"
    else
        _stat_mtime_cmd="stat -c %Y"
    fi

    local now_s found_count=0
    now_s=$(date +%s)

    for wt_dir in "$NPS_WORKTREES_HOME"/*/; do
        [[ -d "$wt_dir" ]] || continue

        local branch
        branch=$(git -C "$wt_dir" rev-parse --abbrev-ref HEAD 2>/dev/null) || continue

        # Safety guard: never act on non-superseded branches
        [[ "$branch" == superseded/* ]] || continue

        # Extract plan_id: superseded/{plan-id}/v{N}/...
        local wt_plan_id
        wt_plan_id=$(printf '%s' "$branch" | cut -d/ -f2)

        # Apply --plan-id filter
        if [[ -n "$opt_plan_id" && "$wt_plan_id" != "$opt_plan_id" ]]; then
            continue
        fi

        local mtime_s age_days
        mtime_s=$($_stat_mtime_cmd "$wt_dir" 2>/dev/null) || continue
        age_days=$(( (now_s - mtime_s) / 86400 ))

        found_count=$((found_count + 1))

        if [[ "$opt_list" == "true" ]]; then
            printf "  %s  branch=%s  age=%dd\n" "${wt_dir%/}" "$branch" "$age_days"
        fi

        if [[ -n "$opt_older_than" && $age_days -gt $opt_older_than ]]; then
            if [[ "$opt_dry_run" == "true" ]]; then
                printf "[dry-run] would remove: %s (branch=%s age=%dd)\n" "${wt_dir%/}" "$branch" "$age_days"
            else
                local main_wt
                main_wt=$(git -C "$wt_dir" worktree list --porcelain 2>/dev/null \
                    | awk '/^worktree /{print $2; exit}')
                if [[ -n "$main_wt" ]]; then
                    git -C "$main_wt" worktree remove --force "${wt_dir%/}" 2>/dev/null
                fi
                log "supersede-gc: removed ${wt_dir%/} (branch=$branch age=${age_days}d)"

                local escalation_log="$NPS_TASKLISTS_HOME/$wt_plan_id/escalation.jsonl"
                python3 - "$escalation_log" "$wt_plan_id" <<'PYEOF'
import json, os, sys
from datetime import datetime, timezone
log_p, plan_id = sys.argv[1:]
now = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
event = {
    "schema_version": 1,
    "timestamp": now,
    "plan_id": plan_id,
    "prior_version": None,
    "pushback_source": None,
    "pushback_reason": None,
    "dispatcher_acted": "supersede_gc",
    "decomposer_output_version": None,
    "osi_ack_at": None,
    "osi_ack_verdict": None,
    "osi_ack_by": None,
    "duration_s": None,
    "escalation_level": "task",
}
os.makedirs(os.path.dirname(os.path.abspath(log_p)), exist_ok=True)
with open(log_p, 'a') as f:
    f.write(json.dumps(event) + '\n')
PYEOF
            fi
        fi
    done

    if [[ "$opt_list" == "true" && $found_count -eq 0 ]]; then
        log "supersede-gc: no superseded worktrees found"
    fi
}

# --- Main ---
case "${1:-help}" in
    ack)               shift; cmd_ack "$@" ;;
    clean)             shift; cmd_clean "$@" ;;
    decompose)         shift; cmd_decompose "$@" ;;
    dispatch)          shift; cmd_dispatch "$@" ;;
    dispatch-tasklist) shift; cmd_dispatch_tasklist "$@" ;;
    merge)             shift; cmd_merge "$@" ;;
    setup)             shift; cmd_setup "$@" ;;
    status)            shift; cmd_status "$@" ;;
    supersede-gc)      shift; cmd_supersede_gc "$@" ;;
    *)
        echo "spawn-agent.sh — NOP worker lifecycle manager"
        echo ""
        echo "Commands:"
        echo "  ack               <plan-id> <version>   Approve pending task-list version"
        echo "  clean             <agent-id>            Remove stale artifacts"
        echo "  decompose                               Plan → Decomposer → pending task-list"
        echo "  dispatch          <agent-id> \"<intent>\" Launch worker on a task"
        echo "  dispatch-tasklist <plan-id> [--version] Dispatch full task-list DAG"
        echo "  merge             <task-id> [\"msg\"]     Squash-merge worktree branch"
        echo "  setup             <agent-id> <type>     Create worker dir + CLAUDE.md"
        echo "  status            <agent-id>            Show mailbox + latest result"
        echo "  supersede-gc      [--list] [--older-than=N] [--dry-run] [--plan-id=ID]"
        echo "                                         Clean up superseded worktrees"
        echo ""
        echo "Decompose options:"
        echo "  --help               Print protocol summary (input, output, exit codes)"
        echo "  (stdin = DecomposeInput JSON)"
        echo ""
        echo "Ack options:"
        echo "  --reject             Reject instead of approve"
        echo "  --as <nid>           Override OSer identity (default: git config user.email)"
        echo "  --reason <text>      Rejection reason (captured in escalation event)"
        echo ""
        echo "Dispatch options:"
        echo "  --budget NPT       Max NPT (default: category-based from config.json)"
        echo "  --max-turns N      Safety net (default: $DEFAULT_MAX_TURNS)"
        echo "  --time-limit N     Wall-clock seconds (default: $DEFAULT_TIME_LIMIT)"
        echo "  --model MODEL      Claude model (default: $DEFAULT_MODEL)"
        echo "  --scope PATH,...   Scope (git repos get worktree isolation)"
        echo "  --priority LEVEL   urgent|normal|low"
        echo "  --category CAT     code|docs|test|research|refactor|ops"
        echo "  --context-file F   JSON context file"
        echo "  --dry-run          Print intent without launching"
        echo "  --branch-name B    Worktree branch name (default: agent/<id>/<task-id>)"
        echo "  --target-branch B  Merge target (default: auto-detect)"
        echo "  --runtime NAME     Agent runtime: claude, kiro (default: $DEFAULT_RUNTIME)"
        ;;
esac
