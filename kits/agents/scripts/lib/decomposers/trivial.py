#!/usr/bin/env python3
"""Trivial-fallback Decomposer — single-node TaskListMessage from a plan.

Reads JSON from stdin; writes TaskListMessage JSON to stdout.
Run with --self-test for an in-process smoke check.

Not a production Decomposer. Makes bin/demo runnable without an LLM.
Adopters override decomposer_cmd in config.json with a sophisticated impl.

Supported frontmatter format (strict subset of YAML):
  - delimiters: --- on their own lines
  - body: key: value pairs, one per line
  - keys: alphanumeric + underscore + dash, no whitespace
  - values: plain strings; no comments, quotes, brackets, pipes,
    or leading whitespace beyond one optional space after the colon

Plans with richer frontmatter require a sophisticated decomposer.
"""

import json
import os
import re
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional


_ISSUER_DOMAIN = os.environ.get('ISSUER_DOMAIN', 'example.com')
CREATED_BY = f"urn:nps:agent:{_ISSUER_DOMAIN}:decomposer-trivial"
DEFAULT_AGENT = f"urn:nps:agent:{_ISSUER_DOMAIN}:coder-01"
FALLBACK_BUDGET_NPT = 40000
FALLBACK_TIMEOUT_MS = 900000


_FRONTMATTER_KEY_RE = re.compile(r"^[A-Za-z0-9_-]+$")


def _default_config_path() -> Path:
    nps_dir = os.environ.get("NPS_DIR")
    if nps_dir:
        return Path(nps_dir) / "config.json"

    cwd_config = Path.cwd() / "config.json"
    if cwd_config.exists():
        return cwd_config

    return Path(__file__).resolve().parents[3] / "config.json"


def _load_config_defaults(config_path: Optional[Path] = None) -> tuple[int, int]:
    path = config_path or _default_config_path()
    try:
        with path.open(encoding="utf-8") as fh:
            config = json.load(fh)
    except (OSError, json.JSONDecodeError) as exc:
        print(
            "trivial-decomposer: warning: could not read config.json "
            f"at {path}: {exc}; using fallback defaults",
            file=sys.stderr,
        )
        return FALLBACK_BUDGET_NPT, FALLBACK_TIMEOUT_MS

    budget_npt = config.get("default_budget_npt", FALLBACK_BUDGET_NPT)
    time_limit_s = config.get("default_time_limit_s", FALLBACK_TIMEOUT_MS // 1000)
    try:
        budget_npt = int(budget_npt)
        timeout_ms = int(time_limit_s) * 1000
    except (TypeError, ValueError):
        print(
            "trivial-decomposer: warning: config.json has invalid default_budget_npt "
            "or default_time_limit_s; using fallback defaults",
            file=sys.stderr,
        )
        return FALLBACK_BUDGET_NPT, FALLBACK_TIMEOUT_MS

    if budget_npt <= 0 or timeout_ms <= 0:
        print(
            "trivial-decomposer: warning: config.json defaults must be positive; "
            "using fallback defaults",
            file=sys.stderr,
        )
        return FALLBACK_BUDGET_NPT, FALLBACK_TIMEOUT_MS

    return budget_npt, timeout_ms


DEFAULT_BUDGET_NPT, DEFAULT_TIMEOUT_MS = _load_config_defaults()


def _parse_frontmatter(plan_text: str) -> dict[str, str]:
    """Extract strict key: value frontmatter pairs, failing loud on richer YAML."""
    lines = plan_text.splitlines()
    in_front = False
    fields: dict[str, str] = {}
    for line_no, line in enumerate(lines, start=1):
        stripped = line.strip()
        if stripped == "---":
            if not in_front:
                in_front = True
                continue
            else:
                break
        if not in_front:
            continue
        if not stripped:
            continue
        if line.startswith((" ", "\t")):
            raise ValueError(f"frontmatter line {line_no}: multi-line value not supported")
        if stripped.startswith("#"):
            raise ValueError(f"frontmatter line {line_no}: comments not supported")
        if "#" in stripped:
            raise ValueError(f"frontmatter line {line_no}: comments not supported")
        if ":" not in stripped:
            raise ValueError(f"frontmatter line {line_no}: expected key: value pair")

        key, _, raw_val = line.partition(":")
        key = key.strip()
        if raw_val.startswith("\t") or raw_val.startswith("  "):
            raise ValueError(f"frontmatter line {line_no}: multi-line value not supported")
        val = raw_val[1:] if raw_val.startswith(" ") else raw_val
        val = val.rstrip()
        if not _FRONTMATTER_KEY_RE.fullmatch(key):
            raise ValueError(f"frontmatter line {line_no}: invalid key")
        if "'" in val or '"' in val:
            raise ValueError(f"frontmatter line {line_no}: quoted value not supported")
        if "[" in val or "]" in val:
            raise ValueError(f"frontmatter line {line_no}: list value not supported")
        if "|" in val or val == ">" or val.startswith("> "):
            raise ValueError(f"frontmatter line {line_no}: block scalar not supported")

        fields[key] = val
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
                    "budget_npt": DEFAULT_BUDGET_NPT,
                    "timeout_ms": DEFAULT_TIMEOUT_MS,
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
    assert out["dag"]["nodes"][0]["budget_npt"] == 40000, "budget_npt should match config default"
    assert out["dag"]["nodes"][0]["timeout_ms"] == 900000, "timeout_ms should match config default"

    # missing config path falls back to documented defaults with a clear warning
    import io
    import contextlib
    stderr_missing_config = io.StringIO()
    with contextlib.redirect_stderr(stderr_missing_config):
        fallback_budget, fallback_timeout = _load_config_defaults(
            Path("/tmp/nps-trivial-decomposer-missing-config.json")
        )
    assert fallback_budget == 40000, f"fallback budget mismatch: {fallback_budget}"
    assert fallback_timeout == 900000, f"fallback timeout mismatch: {fallback_timeout}"
    assert "could not read config.json" in stderr_missing_config.getvalue()

    # strict frontmatter subset — unsupported YAML must fail loud
    negative_cases = [
        ('title: "Plan: with colon"', "quoted value not supported"),
        ("tags: [a, b, c]", "list value not supported"),
        ("title: |", "block scalar not supported"),
        ("  multi-line title", "multi-line value not supported"),
        ("# comment", "comments not supported"),
    ]
    for frontmatter_line, expected_error in negative_cases:
        bad_fixture = dict(fixture)
        bad_fixture["plan"] = (
            "---\n"
            "plan_id: plan-example.com-20260425-120000\n"
            f"{frontmatter_line}\n"
            "---\n\n"
            "Strategic intent body here."
        )
        try:
            _emit(bad_fixture)
        except ValueError as exc:
            assert expected_error in str(exc), (
                f"expected {expected_error!r} for {frontmatter_line!r}, got {exc!r}"
            )
        else:
            raise AssertionError(f"expected ValueError for {frontmatter_line!r}")

    # pushback path — trivial decomposer must refuse, not re-emit
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
