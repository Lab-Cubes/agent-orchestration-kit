#!/usr/bin/env bash
# setup-kiro.sh — Configure the kit to use Kiro CLI as the default runtime.
#
# Run once. After this, all spawn-agent.sh commands use Kiro automatically:
#   ./scripts/spawn-agent.sh dispatch coder-01 "Fix the bug in auth.ts" --scope /path/to/repo

set -euo pipefail

KIT_DIR="$(cd "$(dirname "$0")" && pwd)/kits/agents"
CONFIG="$KIT_DIR/config.json"

# Check kiro-cli is installed
if ! command -v kiro-cli &>/dev/null; then
    echo "Error: kiro-cli not found. Install it first." >&2
    exit 1
fi

# Run base setup if not done
"$KIT_DIR/bin/setup"

# Patch config.json to use kiro runtime
if [[ -f "$CONFIG" ]]; then
    python3 -c "
import json, sys
path = '$CONFIG'
d = json.load(open(path))
d['runtime'] = 'kiro'
open(path, 'w').write(json.dumps(d, indent=2) + '\n')
print(f'Updated {path}: runtime = kiro')
"
else
    cp "$KIT_DIR/config.example.json" "$CONFIG"
    python3 -c "
import json
path = '$CONFIG'
d = json.load(open(path))
d['runtime'] = 'kiro'
open(path, 'w').write(json.dumps(d, indent=2) + '\n')
print(f'Created {path}: runtime = kiro')
"
fi

echo ""
echo "Kiro CLI adapter configured. Usage:"
echo ""
echo "  # Dispatch a task on a repo (creates git worktree)"
echo "  ./kits/agents/scripts/spawn-agent.sh dispatch coder-01 \"Fix the bug\" --scope /path/to/repo"
echo ""
echo "  # Dispatch without a repo"
echo "  ./kits/agents/scripts/spawn-agent.sh dispatch coder-01 \"Write a CSV parser\""
echo ""
echo "  # Check status"
echo "  ./kits/agents/scripts/spawn-agent.sh status coder-01"
echo ""
echo "  # Merge worker's branch"
echo "  ./kits/agents/scripts/spawn-agent.sh merge task-operator-XXXXXXXX-XXXXXX --no-push"
