#!/usr/bin/env bash
# Discord plugin — shared POST helper. Called by the on-task-*.sh wrappers.
# Usage: _post.sh <event_name>
#   event_name: task_claimed | task_completed | task_failed
#
# Env vars (from NPS invoker): NPS_TASK_ID, NPS_AGENT_ID, NPS_COST_NPT, NPS_EVENT

set -euo pipefail

EVENT="${1:-}"
[[ -z "$EVENT" ]] && { echo "_post.sh: event name required as argv[1]" >&2; exit 1; }

PLUGIN_DIR="$(cd "$(dirname "$0")" && pwd)"
[[ ! -f "$PLUGIN_DIR/config.json" ]] && exit 0

# Load config + format message in one Python call.
# Config path and all substitution values are passed as argv — no shell interpolation
# into Python source (injection hardening, same pattern as spawn-agent.sh@238700d).
while IFS='=' read -r _key _rest; do
    [[ -z "$_key" ]] && continue
    declare "$_key"="$_rest"
done < <(python3 - \
    "$PLUGIN_DIR/config.json" \
    "$EVENT" \
    "${NPS_AGENT_ID:-}" \
    "${NPS_TASK_ID:-unknown}" \
    "${NPS_COST_NPT:-0}" \
<<'PYEOF'
import json, sys

config_path, event, agent_id, task_id, cost_npt = sys.argv[1:]
d = json.load(open(config_path))

channel = d.get('channel_id', '')
token   = d.get('bot_token', '')

accounts = d.get('accounts', {})
account  = accounts.get(agent_id, accounts.get('default', agent_id or 'agent'))

defaults = {
    'task_claimed':   '\U0001f528 {account} claimed {task_id}',
    'task_completed': '\u2705 {account} completed {task_id} ({cost_npt} NPT)',
    'task_failed':    '\u274c {account} failed {task_id}',
}
template = d.get('messages', {}).get(event, defaults.get(event, '{account} {event} {task_id}'))
message  = template.format(account=account, task_id=task_id, cost_npt=cost_npt, event=event)

print(f'CHANNEL={channel}')
print(f'TOKEN={token}')
print(f'MESSAGE={message}')
PYEOF
)

# Safe fallback — empty credentials = suppress silently.
[[ -z "${CHANNEL:-}" || -z "${TOKEN:-}" ]] && exit 0

curl -s -X POST "https://discord.com/api/v10/channels/$CHANNEL/messages" \
    -H "Authorization: Bot $TOKEN" \
    -H "Content-Type: application/json" \
    -d "$(python3 -c "import json,sys; print(json.dumps({'content':sys.argv[1]}))" "$MESSAGE")" \
    > /dev/null || true
