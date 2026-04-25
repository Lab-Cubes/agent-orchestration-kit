#!/usr/bin/env python3
"""Trivial-fallback Decomposer — single-node TaskListMessage from a plan.

Reads JSON from stdin; writes TaskListMessage JSON to stdout.
Run with --self-test for an in-process smoke check.

Not a production Decomposer. Makes bin/demo runnable without an LLM.
Adopters override decomposer_cmd in config.json with a sophisticated impl.
"""

import json
import os
import re
import sys
from datetime import datetime, timezone


_ISSUER_DOMAIN = os.environ.get('ISSUER_DOMAIN', 'example.com')
CREATED_BY = f"urn:nps:agent:{_ISSUER_DOMAIN}:decomposer-trivial"
DEFAULT_AGENT = f"urn:nps:agent:{_ISSUER_DOMAIN}:coder-01"


def _parse_frontmatter(plan_text: str) -> dict[str, str]:
    """Extract key: value pairs from YAML frontmatter (between --- delimiters)."""
    lines = plan_text.splitlines()
    in_front = False
    fields: dict[str, str] = {}
    for line in lines:
        stripped = line.strip()
        if stripped == "---":
            if not in_front:
                in_front = True
                continue
            else:
                break
        if in_front and ":" in stripped:
            key, _, val = stripped.partition(":")
            fields[key.strip()] = val.strip()
    return fields


def _derive_action(title: str) -> str:
    """First 50 chars of title → lowercased, non-alphanumeric runs → single dash."""
    slug = re.sub(r"[^a-z0-9]+", "-", title[:50].lower()).strip("-")
    return slug or "execute-plan"


def _emit(inp: dict) -> dict:
    plan_text: str = inp.get("plan", "")
    prior_version = inp.get("prior_version")
    pushback = inp.get("pushback")

    fm = _parse_frontmatter(plan_text)
    plan_id = fm.get("plan_id", "").strip()
    if not plan_id:
        raise ValueError("plan_id not found in plan frontmatter")

    title = fm.get("title", "execute-plan")
    action = _derive_action(title)
    if isinstance(prior_version, dict):
        version_id = prior_version.get('version_id', 0) + 1
    elif isinstance(prior_version, int):
        version_id = prior_version + 1
    else:
        version_id = 1

    return {
        "_ncp": 1,
        "type": "task_list",
        "schema_version": 1,
        "plan_id": plan_id,
        "version_id": version_id,
        "created_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "created_by": CREATED_BY,
        "prior_version": (prior_version if isinstance(prior_version, int)
                          else prior_version.get('version_id') if isinstance(prior_version, dict)
                          else None),
        "pushback_reason": str(pushback) if pushback is not None else None,
        "dag": {
            "nodes": [
                {
                    "id": "node-1",
                    "action": action,
                    "agent": DEFAULT_AGENT,
                    "input_from": [],
                    "input_mapping": {},
                    "scope": ["."],
                    "budget_npt": 20000,
                    "timeout_ms": 3600000,
                    "retry_policy": {"max_retries": 1, "backoff_ms": 5000},
                    "condition": None,
                    "success_criteria": {},
                }
            ],
            "edges": [],
        },
    }


def _self_test() -> None:
    fixture = {
        "plan": (
            "---\n"
            "plan_id: plan-example.com-20260425-120000\n"
            "title: Refactor the login handler\n"
            "status: pending\n"
            "created_at: 2026-04-25T12:00:00Z\n"
            "created_by: urn:nps:agent:example.com:opus-overseer\n"
            "---\n\n"
            "Strategic intent body here."
        ),
        "context": {"files": [], "knowledge": [], "branch": "main"},
        "prior_version": None,
        "prior_state": None,
        "pushback": None,
    }
    out = _emit(fixture)

    assert out["plan_id"] == "plan-example.com-20260425-120000", "plan_id mismatch"
    assert out["version_id"] == 1, "version_id should be 1 on first emission"
    assert out["prior_version"] is None, "prior_version should be null"
    assert out["pushback_reason"] is None, "pushback_reason should be null"
    assert len(out["dag"]["nodes"]) == 1, "should have exactly one node"
    assert out["dag"]["nodes"][0]["action"] == "refactor-the-login-handler", (
        f"bad action: {out['dag']['nodes'][0]['action']}"
    )
    assert out["dag"]["edges"] == [], "edges should be empty"
    assert out["_ncp"] == 1
    assert out["type"] == "task_list"
    assert out["schema_version"] == 1

    # pushback path
    fixture2 = dict(fixture, prior_version=1, pushback="scope_insufficient")
    out2 = _emit(fixture2)
    assert out2["version_id"] == 2, "version_id should bump on pushback"
    assert out2["prior_version"] == 1
    assert out2["pushback_reason"] == "scope_insufficient"

    # long title truncation
    fixture3 = dict(fixture)
    fixture3["plan"] = fixture["plan"].replace(
        "Refactor the login handler",
        "A" * 60,
    )
    out3 = _emit(fixture3)
    assert len(out3["dag"]["nodes"][0]["action"]) <= 50, "action should be ≤50 chars"

    print("self-test: PASS")


def main() -> None:
    if len(sys.argv) > 1 and sys.argv[1] == "--self-test":
        try:
            _self_test()
            sys.exit(0)
        except Exception as exc:
            print(f"self-test: FAIL — {exc}", file=sys.stderr)
            sys.exit(1)

    try:
        raw = sys.stdin.read()
        inp = json.loads(raw)
    except json.JSONDecodeError as exc:
        print(f"trivial-decomposer: invalid JSON on stdin — {exc}", file=sys.stderr)
        sys.exit(1)

    try:
        result = _emit(inp)
    except ValueError as exc:
        print(f"trivial-decomposer: {exc}", file=sys.stderr)
        sys.exit(2)

    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
