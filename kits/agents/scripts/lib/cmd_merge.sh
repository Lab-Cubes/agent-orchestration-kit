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

    # Archive-branch detection: if the expected branch no longer exists, check for
    # superseded/{plan-id}/v{N}/{agent-id}/{task-id} and emit actionable guidance.
    if ! git -C "$original_scope" rev-parse --verify "refs/heads/$branch" >/dev/null 2>&1; then
        local archived_branch
        archived_branch=$(git -C "$original_scope" for-each-ref \
            "refs/heads/superseded/" --format='%(refname:short)' 2>/dev/null \
            | grep "/${agent_id}/${task_id}\$" | head -1)
        if [[ -n "$archived_branch" ]]; then
            local arc_plan arc_ver arc_status="unknown" arc_active="unknown"
            arc_plan=$(printf '%s' "$archived_branch" | cut -d/ -f2)
            arc_ver=$(printf '%s' "$archived_branch" | cut -d/ -f3)
            local arc_state_f="$NPS_TASKLISTS_HOME/$arc_plan/task-list-state.json"
            if [[ -f "$arc_state_f" ]]; then
                local arc_meta
                arc_meta=$(python3 - "$arc_state_f" "$task_id" <<'PYEOF' 2>/dev/null
import json, sys
s = json.load(open(sys.argv[1]))
tid = sys.argv[2]
status = next((ns['status'] for ns in s['node_states'].values()
               if ns.get('task_id') == tid), 'unknown')
print('\t'.join([status, str(s.get('active_version', 'unknown'))]))
PYEOF
                ) || true
                [[ -n "$arc_meta" ]] && IFS=$'\t' read -r arc_status arc_active <<< "$arc_meta"
            fi
            err "Task $task_id is archived under supersede lifecycle."
            err "Branch: $archived_branch"
            err "State: node status $arc_status at active_version $arc_active (supersede from $arc_ver)"
            err "If you want to land this work despite the supersede, cherry-pick:"
            err "    git cherry-pick <commit-hash>..HEAD"
            err "from the superseded branch into your target."
            exit 1
        fi
    fi

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
