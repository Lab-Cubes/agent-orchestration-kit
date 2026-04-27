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

    if prior_version is not None or pushback is not None:
        print(
            "trivial-decomposer: cannot respond to pushback; this decomposer emits identical\n"
            "output regardless of pushback_reason. Configure a sophisticated decomposer via\n"
            "config.json::decomposer_cmd, or escalate to the OSer for manual re-decomposition.",
            file=sys.stderr,
        )
        sys.exit(2)

    fm = _parse_frontmatter(plan_text)
    plan_id = fm.get("plan_id", "").strip()
    if not plan_id:
        raise ValueError("plan_id not found in plan frontmatter")

    title = fm.get("title", "execute-plan")
    action = _derive_action(title)
    version_id = 1

    return {
        "_ncp": 1,
        "type": "task_list",
        "schema_version": 1,
        "plan_id": plan_id,
        "version_id": version_id,
        "created_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "created_by": CREATED_BY,
        "prior_version": None,
        "pushback_reason": None,
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

    # pushback path — trivial decomposer must refuse, not re-emit
    import io
    import contextlib
    import subprocess
    fixture2 = dict(fixture, prior_version=1, pushback="scope_insufficient")
    stderr_buf = io.StringIO()
    pushback_exit = None
    try:
        with contextlib.redirect_stderr(stderr_buf):
            _emit(fixture2)
        pushback_exit = 0  # should not reach here
    except SystemExit as exc:
        pushback_exit = exc.code
    assert pushback_exit == 2, f"pushback path should exit 2, got {pushback_exit}"
    stderr_text = stderr_buf.getvalue()
    assert "trivial-decomposer: cannot respond to pushback" in stderr_text, (
        f"expected refusal message in stderr, got: {stderr_text!r}"
    )
    assert "pushback_unsupported" not in stderr_text  # reason emitted by cmd_decompose, not here

    # prior_version-only path (no pushback text) also refuses
    fixture3_pv = dict(fixture, prior_version={"version_id": 1}, pushback=None)
    stderr_buf2 = io.StringIO()
    pv_exit = None
    try:
        with contextlib.redirect_stderr(stderr_buf2):
            _emit(fixture3_pv)
        pv_exit = 0
    except SystemExit as exc:
        pv_exit = exc.code
    assert pv_exit == 2, f"prior_version-only path should exit 2, got {pv_exit}"

    # long title truncation
    fixture_long = dict(fixture)
    fixture_long["plan"] = fixture["plan"].replace(
        "Refactor the login handler",
        "A" * 60,
    )
    out_long = _emit(fixture_long)
    assert len(out_long["dag"]["nodes"][0]["action"]) <= 50, "action should be ≤50 chars"

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
