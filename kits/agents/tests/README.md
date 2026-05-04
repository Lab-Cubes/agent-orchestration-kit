# kits/agents/tests — Integration Tests

Bats-based integration tests for the dispatch lifecycle.

## What's tested

`spawn-agent.sh dispatch` from end to end: setup → worker claims intent → worker runs → result captured → cost CSV row appended → hook fires. Tests run against an **isolated kit tree** in `$BATS_TMPDIR` with a **mock Claude CLI** — no network, no real `claude` process, no mutation of the real kit.

## Structure

```
tests/
├── README.md                     # this file
├── bin/
│   └── claude                    # mock Claude CLI (switchable via MOCK_CLAUDE_MODE)
├── fixtures/
│   └── config-minimal.json       # minimal CGN-only config for tests
├── helpers/
│   └── build-kit-tree.bash       # build_kit_tree() — isolated per-test kit tree
└── test_dispatch_lifecycle.bats  # happy path, budget flow, failure, dry-run
```

## Running

```bash
# From repo root or from kits/agents/tests/
bats kits/agents/tests/
```

Requires [bats-core](https://github.com/bats-core/bats-core). Install: `brew install bats-core` or `apt install bats`.

## Writing new tests

Tests that verify a bug-fix should follow the **failing-first pattern**: add a test that exercises the bug against current code, confirm it fails, then fix the bug and confirm it passes. Each of the bug inventory items in session 003's log is a future test candidate.

The `build_kit_tree()` helper does the heavy lifting — a test's `setup()` typically just calls it and `teardown()` just removes the temp dir. Each test file is self-contained.

## Mock Claude CLI modes

Set `MOCK_CLAUDE_MODE` before invoking the spawner:

- `happy` (default) — exits 0, emits realistic JSON with token usage
- `timeout` — exits 1, writes `timed out` to stderr, no JSON
- `error` — exits 1, emits JSON with `is_error: true`

The mock writes its received args to `$MOCK_CLAUDE_ARGS_FILE` if set — useful for asserting which flags the spawner passed.
