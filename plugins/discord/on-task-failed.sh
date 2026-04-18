#!/usr/bin/env bash
# Discord plugin — task-failed hook.

set -euo pipefail

PLUGIN_DIR="$(cd "$(dirname "$0")/../../plugins/discord" 2>/dev/null && pwd || true)"
if [[ -z "$PLUGIN_DIR" || ! -f "$PLUGIN_DIR/config.json" ]]; then
    exit 0
fi

CONFIG="$PLUGIN_DIR/config.json"
CHANNEL=$(python3 -c "import json; print(json.load(open('$CONFIG')).get('channel_id', ''))")
TOKEN=$(python3   -c "import json; print(json.load(open('$CONFIG')).get('bot_token', ''))")
[[ -z "$CHANNEL" || -z "$TOKEN" ]] && exit 0

ACCOUNT=$(python3 -c "
import json
c = json.load(open('$CONFIG')).get('accounts', {})
print(c.get('${NPS_AGENT_ID:-}', c.get('default', '${NPS_AGENT_ID:-agent}')))
")

TEMPLATE=$(python3 -c "
import json
print(json.load(open('$CONFIG')).get('messages', {}).get('task_failed', '\u274c {account} failed {task_id}'))
")

MESSAGE=$(python3 -c "
t = '''$TEMPLATE'''
print(t.format(account='$ACCOUNT', task_id='${NPS_TASK_ID:-unknown}', cost_npt='${NPS_COST_NPT:-0}'))
")

curl -s -X POST "https://discord.com/api/v10/channels/$CHANNEL/messages" \
    -H "Authorization: Bot $TOKEN" \
    -H "Content-Type: application/json" \
    -d "$(python3 -c "import json; print(json.dumps({'content': '''$MESSAGE'''}))")" \
    > /dev/null || true
