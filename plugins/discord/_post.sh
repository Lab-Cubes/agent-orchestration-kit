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

# Resolve account, token, and format message in one Python call.
# Config path and all substitution values pass as argv — no shell interpolation
# into Python source (injection hardening, same pattern as spawn-agent.sh).
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
import json, sys, os

config_path, event, agent_id, task_id, cost_npt = sys.argv[1:]
d = json.load(open(config_path))

channel = d.get('channel_id', '')

# Resolve account name: worker_map[agent_id] → account_name, fallback 'default'
worker_map   = d.get('worker_map', {})
account_name = worker_map.get(agent_id, 'default')

# Resolve display name from accounts block
accounts     = d.get('accounts', {})
account_data = accounts.get(account_name) or accounts.get('default') or {}
if isinstance(account_data, str):
    # Legacy schema compat: accounts was {worker_id: display_name}
    display_name = account_data
    token = ''
else:
    display_name = account_data.get('display_name', account_name)
    token        = account_data.get('token', '')

# token_from_openclaw: read token from openclaw.json at runtime if configured
openclaw_path = d.get('token_from_openclaw', '')
if not token and openclaw_path and os.path.exists(openclaw_path):
    try:
        ocd = json.load(open(openclaw_path))
        token = (ocd.get('channels', {})
                    .get('discord', {})
                    .get('accounts', {})
                    .get(account_name, {})
                    .get('token', ''))
        # Fall back to 'default' account token if named account not found
        if not token:
            token = (ocd.get('channels', {})
                        .get('discord', {})
                        .get('accounts', {})
                        .get('default', {})
                        .get('token', ''))
    except (json.JSONDecodeError, OSError):
        pass

defaults = {
    'task_claimed':   '\U0001f528 {account} claimed {task_id}',
    'task_completed': '\u2705 {account} completed {task_id} ({cost_npt} NPT)',
    'task_failed':    '\u274c {account} failed {task_id}',
}
template = d.get('messages', {}).get(event, defaults.get(event, '{account} {event} {task_id}'))
message  = template.format(account=display_name, task_id=task_id, cost_npt=cost_npt, event=event)

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
    -H "User-Agent: DiscordBot (https://github.com/Lab-Cubes/agent-orchestration-kit, 1.0)" \
    -d "$(python3 -c "import json,sys; print(json.dumps({'content':sys.argv[1]}))" "$MESSAGE")" \
    > /dev/null || true
