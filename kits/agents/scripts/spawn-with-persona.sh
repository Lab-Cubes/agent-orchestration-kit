#!/usr/bin/env bash
# spawn-with-persona.sh — Layer a SKILL.md persona onto a worker's CLAUDE.md,
# dispatch a task, then restore the original CLAUDE.md on exit.
#
# The persona is APPENDED to the worker's existing CLAUDE.md (not replaced), so
# the worker retains its NOP protocol scaffold (inbox/active/done mailbox,
# result.json contract) while inheriting the persona's identity and behaviour
# for this one dispatch.
#
# Usage:
#   spawn-with-persona.sh <agent-id> <absolute-skill-md-path> "<task-intent>" [dispatch-opts...]
#
# Guarantees: original CLAUDE.md is restored on exit, even on error or Ctrl-C.
#
# Apache 2.0.

set -euo pipefail

AGENT_ID="${1:?agent-id required (e.g. coder-01)}"
SKILL_FILE="${2:?absolute path to SKILL.md required}"
TASK="${3:?task intent required}"
shift 3

NPS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# Default location matches spawn-agent.sh — see that script's
# path-resolution comment for the security rationale and the
# NPS_STATE_HOME / XDG_STATE_HOME / $HOME precedence.
if [[ -n "${NPS_STATE_HOME:-}" ]]; then
    NPS_STATE_HOME_DEFAULT="$NPS_STATE_HOME"
elif [[ -n "${XDG_STATE_HOME:-}" ]]; then
    NPS_STATE_HOME_DEFAULT="$XDG_STATE_HOME/nps-kit"
else
    NPS_STATE_HOME_DEFAULT="$HOME/.nps-kit"
fi
NPS_AGENTS_HOME="${NPS_AGENTS_HOME:-$NPS_STATE_HOME_DEFAULT/agents}"
WORKER_DIR="$NPS_AGENTS_HOME/$AGENT_ID"
ORIGINAL="$WORKER_DIR/CLAUDE.md"
BACKUP="/tmp/${AGENT_ID}-CLAUDE.md.bak.$$"

[ -f "$SKILL_FILE" ] || { echo "ERROR: skill file missing: $SKILL_FILE" >&2; exit 1; }
[ -f "$ORIGINAL" ]   || { echo "ERROR: worker CLAUDE.md missing: $ORIGINAL" >&2; exit 1; }

trap 'if [ -f "$BACKUP" ]; then cp "$BACKUP" "$ORIGINAL" && rm -f "$BACKUP" && echo "[restored] $AGENT_ID CLAUDE.md" >&2; fi' EXIT

cp "$ORIGINAL" "$BACKUP"

{
  cat "$BACKUP"
  printf '\n\n---\n\n# Active Persona (loaded for this dispatch)\n\n'
  cat "$SKILL_FILE"
} > "$ORIGINAL.tmp"
mv "$ORIGINAL.tmp" "$ORIGINAL"

echo "[appended] $AGENT_ID CLAUDE.md += $SKILL_FILE" >&2

"$NPS_DIR/scripts/spawn-agent.sh" dispatch "$AGENT_ID" "$TASK" "$@"
