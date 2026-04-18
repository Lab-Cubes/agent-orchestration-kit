#!/usr/bin/env bash
# install.sh — Copy (or remove) cost-monitor hook scripts into the agents kit.
#
# Usage:
#   ./install.sh             # install (copies hook script into kit)
#   ./install.sh --uninstall # remove hook script (config.json preserved)

set -euo pipefail

PLUGIN_DIR="$(cd "$(dirname "$0")" && pwd)"
KIT_HOOKS_DIR="$PLUGIN_DIR/../../kits/agents/hooks"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'
say()  { echo -e "${GREEN}[cost-monitor]${NC} $*"; }
warn() { echo -e "${YELLOW}[cost-monitor]${NC} $*"; }

if [[ ! -d "$KIT_HOOKS_DIR" ]]; then
    warn "kits/agents/hooks/ not found at $KIT_HOOKS_DIR"
    warn "Make sure @nps-kit/agents is set up first (./bin/setup in that kit)."
    exit 1
fi

HOOKS=(on-task-completed.sh)

if [[ "${1:-}" == "--uninstall" ]]; then
    for hook in "${HOOKS[@]}"; do
        if [[ -f "$KIT_HOOKS_DIR/$hook" ]]; then
            rm -f "$KIT_HOOKS_DIR/$hook"
            say "Removed $hook"
        fi
    done
    say "Uninstalled. config.json preserved at $PLUGIN_DIR/config.json"
    exit 0
fi

for hook in "${HOOKS[@]}"; do
    # Write a wrapper that exec's the real script from the plugin dir.
    # This preserves $0 so PLUGIN_DIR in the hook resolves correctly.
    cat > "$KIT_HOOKS_DIR/$hook" <<WRAP
#!/usr/bin/env bash
exec "$PLUGIN_DIR/$hook" "\$@"
WRAP
    chmod +x "$KIT_HOOKS_DIR/$hook"
done

say "Installed ${#HOOKS[@]} hook into $KIT_HOOKS_DIR/"
say "Run bin/report at any time to see a cost summary."
