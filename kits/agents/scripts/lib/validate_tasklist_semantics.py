#!/usr/bin/env python3
"""Validate TaskListMessage semantic invariants not expressible in JSON Schema.

Usage:
  INPUT_PLAN_ID=... PRIOR_VERSION_ID=... python3 validate_tasklist_semantics.py <task-list-json>

Exit codes:
  0 — valid
  1 — semantic validation failed; one CODE:message line per violation on stderr
  2 — invocation/input error
"""

import json
import os
import pathlib
import sys
import tempfile


PLAN_MISMATCH = "KIT-DECOMP-PLAN-MISMATCH"
VERSION_MISMATCH = "KIT-DECOMP-VERSION-MISMATCH"
PRIOR_VERSION_MISMATCH = "KIT-DECOMP-PRIOR-VERSION-MISMATCH"
NODE_ID_DUPLICATE = "KIT-DECOMP-NODE-ID-DUPLICATE"
EDGE_PHANTOM = "KIT-DECOMP-EDGE-PHANTOM"
INPUT_FROM_PHANTOM = "KIT-DECOMP-INPUT-FROM-PHANTOM"


def _load_json(path: str) -> dict:
    p = pathlib.Path(path)
    if not p.exists():
        print(f"error: file not found: {path}", file=sys.stderr)
        sys.exit(2)
    try:
        with p.open(encoding="utf-8") as fh:
            data = json.load(fh)
    except json.JSONDecodeError as exc:
        print(f"error: invalid JSON in {path}: {exc}", file=sys.stderr)
        sys.exit(2)
    if not isinstance(data, dict):
        print(f"error: expected JSON object in {path}", file=sys.stderr)
        sys.exit(2)
    return data


def _required_env(name: str) -> str:
    value = os.environ.get(name)
    if value is None or value == "":
        print(f"error: missing required env var {name}", file=sys.stderr)
        sys.exit(2)
    return value


def _prior_version_id() -> int:
    raw = _required_env("PRIOR_VERSION_ID")
    try:
        value = int(raw)
    except ValueError:
        print(f"error: PRIOR_VERSION_ID must be an integer, got {raw!r}", file=sys.stderr)
        sys.exit(2)
    if value < 0:
        print("error: PRIOR_VERSION_ID must be >= 0", file=sys.stderr)
        sys.exit(2)
    return value


def validate(data: dict, input_plan_id: str, prior_version_id: int) -> list[tuple[str, str]]:
    errors: list[tuple[str, str]] = []

    tasklist_plan_id = data.get("plan_id")
    if tasklist_plan_id != input_plan_id:
        errors.append((
            PLAN_MISMATCH,
            f"task-list plan_id {tasklist_plan_id!r} != input plan_id {input_plan_id!r}",
        ))

    expected_version = prior_version_id + 1
    tasklist_version = data.get("version_id")
    if tasklist_version != expected_version:
        errors.append((
            VERSION_MISMATCH,
            f"task-list version_id {tasklist_version!r} != expected {expected_version}",
        ))

    tasklist_prior = data.get("prior_version")
    if prior_version_id > 0 and tasklist_prior != prior_version_id:
        errors.append((
            PRIOR_VERSION_MISMATCH,
            f"task-list prior_version {tasklist_prior!r} != expected {prior_version_id}",
        ))

    dag = data.get("dag", {})
    nodes = dag.get("nodes", [])
    edges = dag.get("edges", [])

    seen_node_ids: set[str] = set()
    duplicate_node_ids: set[str] = set()
    for node in nodes:
        node_id = node.get("id")
        if node_id in seen_node_ids:
            duplicate_node_ids.add(node_id)
        else:
            seen_node_ids.add(node_id)

    for node_id in sorted(duplicate_node_ids):
        errors.append((
            NODE_ID_DUPLICATE,
            f"dag.nodes[].id {node_id!r} appears more than once",
        ))

    for edge in edges:
        src = edge.get("from")
        dst = edge.get("to")
        if src not in seen_node_ids:
            errors.append((
                EDGE_PHANTOM,
                f"dag.edges[].from {src!r} references missing node id",
            ))
        if dst not in seen_node_ids:
            errors.append((
                EDGE_PHANTOM,
                f"dag.edges[].to {dst!r} references missing node id",
            ))

    for node in nodes:
        node_id = node.get("id")
        for upstream_id in node.get("input_from", []):
            if upstream_id not in seen_node_ids:
                errors.append((
                    INPUT_FROM_PHANTOM,
                    f"node {node_id!r} input_from {upstream_id!r} references missing node id",
                ))

    return errors


def _sample_tasklist(**overrides) -> dict:
    data = {
        "_ncp": 1,
        "type": "task_list",
        "schema_version": 1,
        "plan_id": "plan-test-20260425-120000",
        "version_id": 1,
        "created_at": "2026-04-25T12:00:00Z",
        "created_by": "urn:nps:agent:test.localhost:decomposer",
        "prior_version": None,
        "pushback_reason": None,
        "dag": {"nodes": [], "edges": []},
    }
    data.update(overrides)
    return data


def _sample_node(node_id: str, input_from: list[str] | None = None) -> dict:
    return {
        "id": node_id,
        "action": "act",
        "agent": "urn:nps:agent:test.localhost:coder-01",
        "input_from": input_from or [],
        "input_mapping": {},
        "scope": ["."],
        "budget_npt": 1000,
        "timeout_ms": 60000,
        "retry_policy": {"max_retries": 0, "backoff_ms": 0},
        "condition": None,
        "success_criteria": {},
    }


def _self_test() -> None:
    assert validate(_sample_tasklist(), "plan-test-20260425-120000", 0) == []

    plan_errors = validate(_sample_tasklist(plan_id="wrong-plan"), "plan-test-20260425-120000", 0)
    assert plan_errors[0][0] == PLAN_MISMATCH, plan_errors

    version_errors = validate(_sample_tasklist(version_id=1), "plan-test-20260425-120000", 1)
    assert version_errors[0][0] == VERSION_MISMATCH, version_errors

    prior_errors = validate(
        _sample_tasklist(version_id=2, prior_version=None),
        "plan-test-20260425-120000",
        1,
    )
    assert prior_errors[0][0] == PRIOR_VERSION_MISMATCH, prior_errors

    duplicate_errors = validate(
        _sample_tasklist(dag={"nodes": [_sample_node("node-1"), _sample_node("node-1")], "edges": []}),
        "plan-test-20260425-120000",
        0,
    )
    assert duplicate_errors[0][0] == NODE_ID_DUPLICATE, duplicate_errors

    edge_errors = validate(
        _sample_tasklist(
            dag={
                "nodes": [_sample_node("node-1")],
                "edges": [{"from": "node-1", "to": "node-missing"}],
            },
        ),
        "plan-test-20260425-120000",
        0,
    )
    assert edge_errors[0][0] == EDGE_PHANTOM, edge_errors

    input_from_errors = validate(
        _sample_tasklist(dag={"nodes": [_sample_node("node-1", ["node-missing"])], "edges": []}),
        "plan-test-20260425-120000",
        0,
    )
    assert input_from_errors[0][0] == INPUT_FROM_PHANTOM, input_from_errors

    with tempfile.NamedTemporaryFile("w", encoding="utf-8") as fh:
        json.dump(_sample_tasklist(), fh)
        fh.flush()
        data = _load_json(fh.name)
        assert data["plan_id"] == "plan-test-20260425-120000"

    print("self-test: PASS")


def main() -> None:
    if len(sys.argv) > 1 and sys.argv[1] == "--self-test":
        _self_test()
        return

    if len(sys.argv) != 2:
        print("usage: validate_tasklist_semantics.py <task-list-json>", file=sys.stderr)
        sys.exit(2)

    input_plan_id = _required_env("INPUT_PLAN_ID")
    prior_version_id = _prior_version_id()
    data = _load_json(sys.argv[1])
    errors = validate(data, input_plan_id, prior_version_id)
    if errors:
        for code, message in errors:
            print(f"{code}:{message}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
