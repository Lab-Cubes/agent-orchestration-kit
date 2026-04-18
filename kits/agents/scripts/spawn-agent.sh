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
NPS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
NPS_AGENTS_HOME="${NPS_AGENTS_HOME:-$NPS_DIR/agents}"
NPS_WORKTREES_HOME="${NPS_WORKTREES_HOME:-$NPS_DIR/worktrees}"
NPS_LOGS_HOME="${NPS_LOGS_HOME:-$NPS_DIR/logs}"
COST_LOG="$NPS_LOGS_HOME/dispatch-costs.csv"
TEMPLATE="$NPS_DIR/templates/AGENT-CLAUDE.md"
HOOKS_DIR="$NPS_DIR/hooks"
PERSONAS_DIR="$NPS_DIR/templates/personas"

# --- Config (from config.json if present, else defaults) ---
CONFIG_FILE="$NPS_DIR/config.json"
if [[ -f "$CONFIG_FILE" ]]; then
    eval "$(python3 -c "
import json
d = json.load(open('$CONFIG_FILE'))
def q(s): return str(s).replace(\"'\", \"'\\\\''\")
print(f\"ISSUER_DOMAIN='{q(d.get('issuer_domain', 'dev.localhost'))}'\")
print(f\"ISSUER='{q(d.get('issuer_agent_id', 'operator'))}'\")
print(f\"DEFAULT_MODEL='{q(d.get('default_model', 'sonnet'))}'\")
print(f\"DEFAULT_TIME_LIMIT={d.get('default_time_limit_s', 900)}\")
print(f\"DEFAULT_MAX_TURNS={d.get('default_max_turns', 100)}\")
print(f\"DEFAULT_BUDGET_NPT={d.get('default_budget_npt', 20000)}\")
")"
else
    ISSUER_DOMAIN="dev.localhost"
    ISSUER="operator"
    DEFAULT_MODEL="sonnet"
    DEFAULT_TIME_LIMIT=900
    DEFAULT_MAX_TURNS=100
    DEFAULT_BUDGET_NPT=20000
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

    NPS_TASK_ID="$task_id" \
    NPS_AGENT_ID="$agent_id" \
    NPS_STATUS="$status" \
    NPS_COST_NPT="$cost_npt" \
    NPS_EVENT="$event" \
      "$hook_script" < /dev/null > /dev/null 2>&1 || warn "hook $event exited non-zero"
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

    # Parse persona values + sections
    local model capabilities default_scope tools_section agent_instructions run_mode
    eval "$(python3 -c "
import re
content = open('$persona_file').read()
def kv(key):
    m = re.search(r'^' + key + r':\s*(.+)', content, re.M)
    return m.group(1).strip() if m else ''
def section(name):
    pattern = r'^## ' + re.escape(name) + r'\n(.*?)(?=^## |\Z)'
    m = re.search(pattern, content, re.M | re.S)
    return m.group(1).strip() if m else ''
def q(s): return s.replace(\"'\", \"'\\\\''\" )
print(f\"model='{q(kv('MODEL'))}'\")
print(f\"capabilities='{q(kv('CAPABILITIES'))}'\")
print(f\"run_mode='{q(kv('RUN_MODE'))}'\")
print(f\"default_scope='{q(section('Default Scope'))}'\")
print(f\"tools_section='{q(section('Tools Section'))}'\")
print(f\"agent_instructions='{q(section('Agent Instructions'))}'\")
")"

    # Assemble CLAUDE.md from template
    local assembled="$agent_dir/CLAUDE.md"
    cp "$TEMPLATE" "$assembled"

    sed -i '' "s|{{AGENT_ID}}|$agent_id|g" "$assembled"
    sed -i '' "s|{{AGENT_TYPE}}|$agent_type|g" "$assembled"
    sed -i '' "s|{{MODEL}}|${model:-$DEFAULT_MODEL}|g" "$assembled"
    sed -i '' "s|{{ISSUER_DOMAIN}}|$ISSUER_DOMAIN|g" "$assembled"
    sed -i '' "s|{{ISSUER}}|$ISSUER|g" "$assembled"
    sed -i '' "s|{{CAPABILITIES}}|${capabilities:-nop:execute}|g" "$assembled"
    sed -i '' "s|{{INBOX_PATH}}|./inbox/|g" "$assembled"
    sed -i '' "s|{{RUN_MODE}}|${run_mode:-single-shot}|g" "$assembled"

    python3 -c "
content = open('$assembled').read()
sections = {
    '{{DEFAULT_SCOPE}}': '''$default_scope'''.strip(),
    '{{TOOLS_SECTION}}': '''$tools_section'''.strip(),
    '{{AGENT_INSTRUCTIONS}}': '''$agent_instructions'''.strip(),
}
for placeholder, replacement in sections.items():
    content = content.replace(placeholder, replacement)
open('$assembled', 'w').write(content)
"

    # Permissive .claude/settings.json for the worker (operator-owned scope enforcement)
    cat > "$agent_dir/.claude/settings.json" << 'SETTINGS'
{
  "permissions": {
    "allow": ["Read(*)", "Write(**)", "Edit(**)", "Bash"]
  }
}
SETTINGS

    log "Worker $agent_id ready at $agent_dir"
    log "Mailbox: inbox/ active/ done/ blocked/"
}

# --- dispatch ---
cmd_dispatch() {
    local agent_id="$1"
    shift
    local intent_text="$1"
    shift

    local agent_dir="$NPS_AGENTS_HOME/$agent_id"
    local max_turns="$DEFAULT_MAX_TURNS"
    local time_limit="$DEFAULT_TIME_LIMIT"
    local budget=""
    local model="$DEFAULT_MODEL"
    local scope=""
    local priority="normal"
    local category="code"
    local context_file=""
    local dry_run=false
    local target_branch=""

    _budget_for_category() {
        if [[ -f "$CONFIG_FILE" ]]; then
            python3 -c "
import json
d = json.load(open('$CONFIG_FILE'))
print(d.get('category_budget_npt', {}).get('$1', $DEFAULT_BUDGET_NPT))
"
        else
            echo "$DEFAULT_BUDGET_NPT"
        fi
    }

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --max-turns)     max_turns="$2"; shift 2 ;;
            --time-limit)    time_limit="$2"; shift 2 ;;
            --budget)        budget="$2"; shift 2 ;;
            --model)         model="$2"; shift 2 ;;
            --scope)         scope="$2"; shift 2 ;;
            --priority)      priority="$2"; shift 2 ;;
            --category)      category="$2"; shift 2 ;;
            --context-file)  context_file="$2"; shift 2 ;;
            --dry-run)       dry_run=true; shift ;;
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
        if [[ -d "$first_scope/.git" || -f "$first_scope/.git" ]]; then
            if [[ -z "$target_branch" ]]; then
                target_branch=$(git -C "$first_scope" symbolic-ref --short HEAD 2>/dev/null || true)
                if [[ -z "$target_branch" ]]; then
                    err "Scope repo '$first_scope' is on detached HEAD — pass --target-branch explicitly"
                    exit 1
                fi
            fi
            branch_name="agent/${agent_id}/${task_id}"
            worktree_path="$NPS_WORKTREES_HOME/$task_id"
            mkdir -p "$NPS_WORKTREES_HOME"
            if ! $dry_run; then
                log "Creating worktree: $worktree_path (branch: $branch_name)"
                git -C "$first_scope" worktree add "$worktree_path" -b "$branch_name" 2>&1 \
                    || { err "Failed to create worktree"; exit 1; }
            fi
            scope="${scope/$first_scope/$worktree_path}"
        fi
    fi

    local scope_json="[]"
    if [[ -n "$scope" ]]; then
        scope_json=$(echo "$scope" | python3 -c "import sys,json; print(json.dumps(sys.stdin.read().strip().split(',')))")
    fi

    local context_json='{}'
    if [[ -n "$context_file" && -f "$context_file" ]]; then
        context_json=$(cat "$context_file")
    fi

    local intent_file="$agent_dir/inbox/${task_id}.intent.json"
    local created_at
    created_at=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)

    python3 -c "
import json
intent = {
    '_ncp': 1,
    'type': 'intent',
    'intent': '''$intent_text''',
    'confidence': 0.95,
    'payload': {
        '_nop': 1,
        'id': '$task_id',
        'from': 'urn:nps:agent:$ISSUER_DOMAIN:$ISSUER',
        'to': 'urn:nps:agent:$ISSUER_DOMAIN:$agent_id',
        'created_at': '$created_at',
        'priority': '$priority',
        'category': '$category',
        'mailbox': {'base': './'},
        'context': $context_json,
        'constraints': {
            'model': '$model',
            'time_limit': $time_limit,
            'scope': $scope_json,
            'proceed_gate': False,
            'budget_npt': $budget
        }
    }
}
print(json.dumps(intent, indent=2))
" > "$intent_file"

    log "Intent created: $task_id"

    if $dry_run; then
        log "DRY RUN — not launching worker"
        cat "$intent_file"
        return 0
    fi

    # Hook: task claimed (fires when intent lands in inbox, before dispatch)
    run_hook "task-claimed" "$task_id" "$agent_id" "pending" "0"

    local branch_instruction=""
    if [[ -n "$worktree_path" ]]; then
        branch_instruction=" IMPORTANT: Your workspace is at $worktree_path (a git worktree on branch $branch_name). Do all work there. Do NOT push — the operator will squash-merge your branch after review."
    fi
    local prompt="You are $agent_id. Read your CLAUDE.md for identity and protocol. Then use Bash to run 'ls ./inbox/' to find tasks. There IS a task waiting: ${task_id}.intent.json — read it, claim via mv to ./active/, execute, archive intent to ./done/, write result.json to ./done/.${branch_instruction}"

    log "Launching worker: $agent_id (model: $model, budget: $budget NPT, max-turns: $max_turns)"
    local start_time end_time duration
    start_time=$(date +%s)

    local add_dirs=""
    if [[ -n "$scope" ]]; then
        IFS=',' read -ra scope_paths <<< "$scope"
        for sp in "${scope_paths[@]}"; do
            add_dirs="$add_dirs --add-dir $sp"
        done
    fi

    # Claude CLI's --max-budget-usd is the closest available kill-switch; we derive
    # an approximate USD ceiling from the NPT budget. Rough: 1000 NPT ≈ $0.005
    # on Sonnet. Over-generous rather than blocking legitimate work.
    local budget_usd_derived
    budget_usd_derived=$(python3 -c "print(max(0.50, $budget * 0.00001))")

    local output
    output=$(cd "$agent_dir" && claude -p "$prompt" \
        --model "$model" \
        --permission-mode dontAsk \
        --allowedTools "Read,Edit,Write,Bash,Glob,Grep" \
        --setting-sources "project,local" \
        --max-turns "$max_turns" \
        --max-budget-usd "$budget_usd_derived" \
        --output-format json \
        $add_dirs 2>&1) || true

    end_time=$(date +%s)
    duration=$((end_time - start_time))

    echo "$output" > "$agent_dir/done/${task_id}.raw-output.json"

    local clean_json
    clean_json=$(echo "$output" | grep '^{' | head -1)

    local result cost_usd cost_npt denials turns status_val stop_reason
    if [[ -n "$clean_json" ]]; then
        eval "$(echo "$clean_json" | python3 -c "
import sys, json
d = json.load(sys.stdin)
def q(s): return str(s).replace(\"'\", \"'\\\\''\")
usage = d.get('usage', {}) or {}
input_tokens = usage.get('input_tokens', 0) or 0
output_tokens = usage.get('output_tokens', 0) or 0
cache_read = usage.get('cache_read_input_tokens', 0) or 0
# NPT approximation for v0.1.0: sum of distinct input-side + output tokens.
# Cross-model standardization per NPS-0 §4.3 requires a full token-budget.md
# implementation; this is a defensible placeholder until v0.2.0.
cost_npt_val = input_tokens + output_tokens + cache_read
print(f\"result='{q(d.get('result','NO RESULT')[:500])}'\")
print(f\"cost_usd='{d.get('total_cost_usd',0):.4f}'\")
print(f\"cost_npt={cost_npt_val}\")
print(f\"denials='{len(d.get('permission_denials',[]))}'\")
print(f\"turns='{d.get('num_turns','?')}'\")
print(f\"stop_reason='{q(d.get('stop_reason','?'))}'\")
print(f\"status_val='{'error' if d.get('is_error') else 'success'}'\")
" 2>/dev/null)" || {
            result="PARSE ERROR"
            cost_usd="?"; cost_npt="0"; denials="?"; turns="?"; stop_reason="?"; status_val="?"
        }
    else
        warn "No JSON found in worker output"
        result="NO JSON OUTPUT"; cost_usd="?"; cost_npt="0"; denials="?"; turns="?"; stop_reason="?"; status_val="error"
    fi

    log "Worker finished in ${duration}s (cost: ${cost_npt} NPT / \$${cost_usd}, turns: $turns, denials: $denials)"
    log "Result: $result"

    # Fallback result.json if worker didn't write one
    local agent_result="$agent_dir/done/${task_id}.result.json"
    if [[ ! -f "$agent_result" ]]; then
        warn "Worker did not write result.json — generating fallback"
        local completed_at
        completed_at=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)
        python3 - "$task_id" "$status_val" "$agent_id" "$created_at" "$completed_at" \
            "$duration" "$cost_npt" "$turns" "$stop_reason" "$ISSUER_DOMAIN" << 'PYEOF' > "$agent_result" 2>/dev/null || true
import json, sys
_, task_id, status_val, agent_id, picked_up, completed, duration, cost_npt, turns, stop, issuer_domain = sys.argv
result = {
    "_ncp": 1,
    "type": "result",
    "value": f"Fallback result (worker did not complete NOP lifecycle). Stop reason: {stop}. Check raw-output.json.",
    "probability": 0.5,
    "alternatives": [],
    "payload": {
        "_nop": 1,
        "id": task_id,
        "status": "completed" if status_val == "success" else "failed",
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

    # Append to cost log (CSV)
    mkdir -p "$(dirname "$COST_LOG")"
    if [[ ! -f "$COST_LOG" ]]; then
        echo "timestamp,task_id,agent_id,model,category,priority,budget_npt,cost_npt,cost_usd_derived,turns,duration_s,denials,status" > "$COST_LOG"
    fi
    printf '"%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s"\n' \
        "$created_at" "$task_id" "$agent_id" "$model" "$category" "$priority" \
        "$budget" "$cost_npt" "$cost_usd" "$turns" "$duration" "$denials" "$status_val" >> "$COST_LOG"

    # Hook: task completed or failed
    if [[ "$status_val" == "success" ]]; then
        run_hook "task-completed" "$task_id" "$agent_id" "completed" "$cost_npt"
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
        python3 -c "
import json
d = json.load(open('$latest'))
p = d.get('payload', {})
print(f\"  Task:      {p.get('id', '?')}\")
print(f\"  Status:    {p.get('status', '?')}\")
print(f\"  Duration:  {p.get('duration', '?')}s\")
print(f\"  Cost NPT:  {p.get('cost_npt', '?')}\")
print(f\"  Files:     {p.get('files_changed', [])}\")
print(f\"  Summary:   {d.get('value', '?')[:200]}\")
" 2>/dev/null || cat "$latest"
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

# --- merge ---
cmd_merge() {
    local task_id="$1"; shift
    local message=""
    local do_push=true
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --no-push) do_push=false; shift ;;
            *) message="$1"; shift ;;
        esac
    done

    local branch_file=""
    for wdir in "$NPS_AGENTS_HOME"/*/done/; do
        if [[ -f "${wdir}${task_id}.branch.json" ]]; then
            branch_file="${wdir}${task_id}.branch.json"; break
        fi
    done
    if [[ -z "$branch_file" ]]; then err "No branch metadata for $task_id"; exit 1; fi

    local branch worktree original_scope agent_id target_branch
    eval "$(python3 -c "
import json
d = json.load(open('$branch_file'))
print(f\"branch='{d['branch']}'\")
print(f\"worktree='{d['worktree']}'\")
print(f\"original_scope='{d['original_scope']}'\")
print(f\"agent_id='{d['agent_id']}'\")
print(f\"target_branch='{d.get('target_branch', 'main')}'\")
" 2>/dev/null)"

    if [[ -z "$branch" || -z "$original_scope" ]]; then err "Invalid branch metadata"; exit 1; fi

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

# --- Main ---
case "${1:-help}" in
    setup)    shift; cmd_setup "$@" ;;
    dispatch) shift; cmd_dispatch "$@" ;;
    status)   shift; cmd_status "$@" ;;
    clean)    shift; cmd_clean "$@" ;;
    merge)    shift; cmd_merge "$@" ;;
    *)
        echo "spawn-agent.sh — NOP worker lifecycle manager"
        echo ""
        echo "Commands:"
        echo "  setup    <agent-id> <type>       Create worker dir + CLAUDE.md"
        echo "  dispatch <agent-id> \"<intent>\"   Launch worker on a task"
        echo "  status   <agent-id>              Show mailbox + latest result"
        echo "  clean    <agent-id>              Remove stale artifacts"
        echo "  merge    <task-id> [\"msg\"]       Squash-merge worktree branch"
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
        echo "  --target-branch B  Merge target (default: auto-detect)"
        ;;
esac
