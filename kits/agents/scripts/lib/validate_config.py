#!/usr/bin/env python3
# Validate kits/agents/config.json.
# Usage: validate_config.py <path>
# Exits 0 on success; exits 1 and prints errors to stderr on failure.
# Version 1 (scaffold — replaced in commit 2): no-op passthrough.
import json, sys
path = sys.argv[1]
try:
    config = json.load(open(path))
except (FileNotFoundError, json.JSONDecodeError) as e:
    print(f"config error: {e}", file=sys.stderr)
    sys.exit(1)
sys.exit(0)
