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
PERSONA_SET="personas"

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
DEFAULT_BUDGET_CGN=20000
DEFAULT_SHUTDOWN_GRACE_S=15
DEFAULT_SOFT_CAP_RATIO=0.9
DEFAULT_RUNTIME="claude"
CGN_EXCHANGE_RATES_JSON='{"unknown":1.0}'
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
print(f"DEFAULT_BUDGET_CGN={d.get('default_budget_cgn', 40000)}")
print(f"DEFAULT_SHUTDOWN_GRACE_S={d.get('default_shutdown_grace_s', 15)}")
print(f"DEFAULT_SOFT_CAP_RATIO={d.get('default_soft_cap_ratio', 0.9)}")
print(f"DEFAULT_RUNTIME={d.get('runtime', 'claude')}")
_raw = d.get('cgn_exchange_rates') or dict()
_rates = dict((k, v) for k, v in _raw.items() if not k.startswith('$'))
_fallback = dict((('unknown', 1.0),))
print(f"CGN_EXCHANGE_RATES_JSON={json.dumps(_rates or _fallback)}")
print(f"DEFAULT_DECOMPOSER_CMD={d.get('decomposer_cmd', 'python3 scripts/lib/decomposers/trivial.py')}")
print(f"DEFAULT_DECOMPOSER_TIMEOUT_MS={d.get('decomposer_timeout_ms', 60000)}")
print(f"MERGE_HOLD_ENFORCE={'true' if d.get('merge_hold_enforce', True) else 'false'}")
print(f"PERSONA_SET={d.get('persona_set', 'personas')}")
PYEOF
)
fi

PERSONAS_DIR="$NPS_DIR/templates/$PERSONA_SET"

# --- Colours ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[nps]${NC} $*"; }
warn() { echo -e "${YELLOW}[nps]${NC} $*"; }
err()  { echo -e "${RED}[nps]${NC} $*" >&2; }
