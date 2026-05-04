#!/usr/bin/env python3
"""Test decomposer that accepts pushback and emits a valid v2 task-list."""

import json
import re
import sys
from datetime import datetime, timezone


def parse_plan_id(plan_text: str) -> str:
    match = re.search(r"^plan_id:\s*(.+)$", plan_text, re.MULTILINE)
    if not match:
        raise ValueError("plan_id not found in plan frontmatter")
    return match.group(1).strip()


inp = json.load(sys.stdin)
prior = inp.get("prior_version") or {}
plan_id = prior.get("plan_id") or parse_plan_id(inp.get("plan", ""))
version_id = int(prior.get("version_id", 1)) + 1

out = {
    "_ncp": 1,
    "type": "task_list",
    "schema_version": 1,
    "plan_id": plan_id,
    "version_id": version_id,
    "created_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "created_by": "urn:nps:agent:test.localhost:decomposer-pushback-success",
    "prior_version": prior.get("version_id"),
    "pushback_reason": inp.get("pushback"),
    "dag": {
        "nodes": [
            {
                "id": "node-1",
                "action": "handle-pushback-scope-insufficient",
                "agent": "urn:nps:agent:test.localhost:coder-01",
                "input_from": [],
                "input_mapping": {},
                "scope": ["."],
                "budget_cgn": 20000,
                "timeout_ms": 3600000,
                "retry_policy": {"max_retries": 0, "backoff_ms": 0},
                "condition": None,
                "success_criteria": {},
            }
        ],
        "edges": [],
    },
}

print(json.dumps(out, indent=2))
