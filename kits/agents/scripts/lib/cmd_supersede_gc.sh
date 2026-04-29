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
