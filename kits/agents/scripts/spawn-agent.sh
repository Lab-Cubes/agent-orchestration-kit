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
#   --budget CGN        Max CGN to spend (default: category-based, from config.json)
#   --max-turns N       Safety net turn limit
#   --time-limit N      Safety net wall-clock seconds
#   --model MODEL       Model override (default: sonnet)
#   --scope PATH,...    Comma-separated scope paths
#   --priority LEVEL    low|normal|high (default: normal)
#   --category CAT      Task category (default: code)
#   --context-file F    JSON file with extra context
#   --dry-run           Print intent JSON without launching
#   --target-branch B   Merge target branch (default: auto-detect)

set -euo pipefail

# --- Runtime + command modules ---
# shellcheck source=/dev/null
NPS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$NPS_DIR/scripts/lib/helpers/env.sh"
source "$NPS_DIR/scripts/lib/helpers/hooks.sh"
source "$NPS_DIR/scripts/lib/cmd_setup.sh"
source "$NPS_DIR/scripts/lib/cmd_dispatch.sh"
source "$NPS_DIR/scripts/lib/cmd_status.sh"
source "$NPS_DIR/scripts/lib/cmd_clean.sh"
source "$NPS_DIR/scripts/lib/cmd_decompose.sh"
source "$NPS_DIR/scripts/lib/cmd_merge.sh"
source "$NPS_DIR/scripts/lib/cmd_ack.sh"
source "$NPS_DIR/scripts/lib/cmd_dispatch_tasklist.sh"
source "$NPS_DIR/scripts/lib/cmd_supersede_gc.sh"

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
        echo "                    Archived (superseded) branches emit cherry-pick guidance."
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
        echo "  --budget CGN       Max CGN (default: category-based from config.json)"
        echo "  --max-turns N      Safety net (default: $DEFAULT_MAX_TURNS)"
        echo "  --time-limit N     Wall-clock seconds (default: $DEFAULT_TIME_LIMIT)"
        echo "  --model MODEL      Claude model (default: $DEFAULT_MODEL)"
        echo "  --scope PATH,...   Scope (git repos get worktree isolation)"
        echo "  --priority LEVEL   low|normal|high"
        echo "  --category CAT     code|docs|test|research|refactor|ops"
        echo "  --context-file F   JSON context file"
        echo "  --dry-run          Print intent without launching"
        echo "  --branch-name B    Worktree branch name (default: agent/<id>/<task-id>)"
        echo "  --target-branch B  Merge target (default: auto-detect)"
        echo "  --runtime NAME     Agent runtime: claude, kiro (default: $DEFAULT_RUNTIME)"
        ;;
esac
