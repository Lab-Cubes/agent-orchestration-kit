#!/usr/bin/env bash
# install.sh — Copy (or remove) Discord hook scripts into the agents kit.
#
# Usage:
#   ./install.sh             # install (copies hook scripts into kit)
#   ./install.sh --uninstall # remove hook scripts (config.json preserved)

set -euo pipefail

PLUGIN_DIR="$(cd "$(dirname "$0")" && pwd)"
KIT_HOOKS_DIR="$PLUGIN_DIR/../../kits/agents/hooks"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'
say()  { echo -e "${GREEN}[discord-plugin]${NC} $*"; }
warn() { echo -e "${YELLOW}[discord-plugin]${NC} $*"; }

if [[ ! -d "$KIT_HOOKS_DIR" ]]; then
    warn "kits/agents/hooks/ not found at $KIT_HOOKS_DIR"
    warn "Make sure @nps-kit/agents is set up first (./bin/setup in that kit)."
    exit 1
fi

HOOKS=(on-task-claimed.sh on-task-completed.sh on-task-failed.sh _post.sh)

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

if [[ ! -f "$PLUGIN_DIR/config.json" ]]; then
    warn "config.json not found. Create it first:"
    warn "  cp config.example.json config.json"
    warn "  # then edit config.json to add channel_id + bot_token"
    exit 1
fi

for hook in "${HOOKS[@]}"; do
    cp "$PLUGIN_DIR/$hook" "$KIT_HOOKS_DIR/$hook"
    chmod +x "$KIT_HOOKS_DIR/$hook"
done

say "Installed ${#HOOKS[@]} hooks into $KIT_HOOKS_DIR/"
say "Next worker dispatch will post to Discord."
