#!/usr/bin/env bash
# cost-monitor plugin — on-task-completed hook.
#
# Emits to stderr:
#   [cost] {agent} {task_id}: {NPT} NPT (~${USD}) · {duration}s · {category}
#
# Env vars (from NPS invoker): NPS_TASK_ID, NPS_AGENT_ID, NPS_COST_NPT, NPS_EVENT

set -euo pipefail

PLUGIN_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG="$PLUGIN_DIR/config.json"

AGENT="${NPS_AGENT_ID:-unknown}"
TASK_ID="${NPS_TASK_ID:-unknown}"
NPT="${NPS_COST_NPT:-0}"

# Load NPT→USD rate from config (default: 0.001).
# Config path passed as argv to avoid shell interpolation into Python source.
read -r NPT_USD_RATE < <(python3 - "$CONFIG" <<'PYEOF'
import json, sys
config_path = sys.argv[1]
rate = 0.001
try:
    d = json.load(open(config_path))
    rate = float(d.get('npt_usd_rate', 0.001))
except Exception:
    pass
print(rate)
PYEOF
)

# Resolve duration from result.json written by the worker.
# Hook scripts live in kits/agents/hooks/; result.json is under agents/{id}/done/.
RESULT_JSON="$(dirname "$PLUGIN_DIR")/../../kits/agents/agents/${AGENT}/done/${TASK_ID}.result.json"
DURATION="-"
CATEGORY="-"
if [[ -f "$RESULT_JSON" ]]; then
    read -r DURATION CATEGORY < <(python3 - "$RESULT_JSON" <<'PYEOF'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    dur = str(d.get('payload', {}).get('duration', '-'))
    cat = str(d.get('payload', {}).get('category', '-'))
    print(dur, cat)
except Exception:
    print("- -")
PYEOF
    )
fi

# Calculate USD from NPT, pass values as argv for safety.
USD=$(python3 - "$NPT" "$NPT_USD_RATE" <<'PYEOF'
import sys
try:
    npt = float(sys.argv[1])
    rate = float(sys.argv[2])
    print(f'{npt * rate:.4f}')
except Exception:
    print('?')
PYEOF
)

echo "[cost] $AGENT $TASK_ID: $NPT NPT (~\$$USD) · ${DURATION}s · $CATEGORY" >&2
