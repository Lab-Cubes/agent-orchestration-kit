# Bats Fixture Patterns

This pattern explains how the agents kit tests exercise dispatch without using
real workers or real operator state.

## Isolated Kit Trees

Bats tests load `kits/agents/tests/helpers/build-kit-tree.bash`. The helper
creates a throwaway kit tree, isolated `agents`, `worktrees`, `logs`, and
`hooks` directories, copies the real scripts and templates, installs a minimal
config fixture, and prepends the mock Claude binary to `PATH`
(`kits/agents/tests/helpers/build-kit-tree.bash:21-56`).

Use `run_spawner` for command tests. It wraps `spawn-agent.sh` with
`NPS_AGENTS_HOME`, `NPS_WORKTREES_HOME`, and `NPS_LOGS_HOME` pointed at the
fixture tree (`kits/agents/tests/helpers/build-kit-tree.bash:58-65`).

`test_dispatch_lifecycle.bats` documents the intent: every dispatch lifecycle
test uses the isolated kit tree plus the mock Claude CLI, so no real Claude
process runs and no real state is touched
(`kits/agents/tests/test_dispatch_lifecycle.bats:1-7`).

## Mailbox Lifecycle Assertions

The basic setup test verifies that worker setup creates the expected mailbox
directories and bootstrap file:

- `inbox/`
- `active/`
- `done/`
- `blocked/`
- `CLAUDE.md`

See `kits/agents/tests/test_dispatch_lifecycle.bats:24-33`.

The dispatch prompt also encodes the worker lifecycle directly: list `inbox`,
read the intent, claim it by moving to `active`, execute, archive the intent to
`done`, and write `result.json` to `done`
(`kits/agents/scripts/lib/cmd_dispatch.sh:230-234`).

## Mock Worker Modes

The mock worker is `kits/agents/tests/bin/claude`. It selects behavior from
`MOCK_CLAUDE_MODE` (`kits/agents/tests/bin/claude:4-18`,
`kits/agents/tests/bin/claude:33`).

| Mode | Signal |
|---|---|
| `happy` | Emits assistant and successful result stream events (`kits/agents/tests/bin/claude:35-40`). |
| `timeout` | Exits nonzero with timeout text on stderr and no stdout JSON (`kits/agents/tests/bin/claude:41-44`). |
| `error` | Emits a structured result with `is_error=true` (`kits/agents/tests/bin/claude:45-49`). |
| `slow` | Sleeps before emitting anything, for time-limit tests (`kits/agents/tests/bin/claude:50-52`). |
| `budget_exceeded` | Emits 5M input tokens, then sleeps so dispatcher budget logic can stop it (`kits/agents/tests/bin/claude:53-59`). |
| `cache_creation` | Emits nonzero `cache_creation_input_tokens` (`kits/agents/tests/bin/claude:60-67`). |
| `rate_check` | Emits round token counts for exchange-rate checks (`kits/agents/tests/bin/claude:68-74`). |
| `sigint_handler` | Emits high token usage, traps SIGINT, then emits a final success result (`kits/agents/tests/bin/claude:75-113`). |
| `scope_violation` | Writes a worker result with `files_changed` outside scope (`kits/agents/tests/bin/claude:114-142`). |
| `scope_clean` | Writes a worker result with `files_changed` inside `MOCK_SCOPE_DIR` (`kits/agents/tests/bin/claude:143-172`). |
| `commit_to_scope` | Commits inside `MOCK_COMMIT_DIR` to prove the old scope-escape shape (`kits/agents/tests/bin/claude:173-185`). |
| `commit_to_add_dir` | Commits to the runtime `--add-dir` path to verify worktree isolation (`kits/agents/tests/bin/claude:186-214`). |
| `malformed_result_missing_fields` | Writes a result file missing required NOP fields (`kits/agents/tests/bin/claude:215-233`). |
| `pushback` | Writes `status=blocked` and `pushback_reason=scope_insufficient` (`kits/agents/tests/bin/claude:234-263`). |
| `malformed_result_invalid_json` | Writes truncated invalid JSON (`kits/agents/tests/bin/claude:264-280`). |

## Scope Fixtures

Use `scope: []` when the test is proving empty-scope rejection. Use
`scope: ["."]` for task-list fixtures that should point at the current fixture
repo. Use concrete files or directories when the test needs to prove scope
translation, validation, or worktree isolation.

`decompose.bats` builds task-list nodes with `scope: ["."]` by default
(`kits/agents/tests/decompose.bats:107-115`) and has semantic variants for
empty and dot scope (`kits/agents/tests/decompose.bats:131-134`).

`dispatch_tasklist.bats` creates a minimal git repo for task-list dispatch
tests (`kits/agents/tests/dispatch_tasklist.bats:46-53`). Its `_write_acked`
helper copies a fixture into `task-lists/<plan>/vN.json`
(`kits/agents/tests/dispatch_tasklist.bats:80-86`).

For direct dispatch tests that need a scoped repo, `_init_scope_repo` creates a
throwaway repository with an initial commit
(`kits/agents/tests/test_dispatch_lifecycle.bats:178-184`).

## Worker-Written Results

Use worker-written results when the behavior depends on NOP payload semantics,
not just runtime stream output. The mock worker can write
`done/<task>.result.json` itself before emitting stream output.

Examples:

- `scope_violation` writes a completed result whose `files_changed` are outside
  scope, letting dispatcher scope validation rewrite it to failed.
- `scope_clean` writes a completed result inside scope.
- `malformed_result_missing_fields` and `malformed_result_invalid_json` test
  malformed result handling.
- `pushback` writes a blocked result with `pushback_reason`, which is the shape
  task-list dispatch treats as worker pushback.

End-to-end pushback tests set `MOCK_CLAUDE_MODE=pushback` and assert that the
node becomes blocked (`kits/agents/tests/end_to_end.bats:281-297`). Follow-up
tests assert trivial-decomposer refusal and custom-decomposer recovery
(`kits/agents/tests/end_to_end.bats:304-319`,
`kits/agents/tests/end_to_end.bats:338-359`).

## Result Discovery Fixtures

Task-list tests should assert through the state artifacts, not only command
stdout. `dispatch_tasklist.bats` includes helpers that:

- Assert all node states are `completed`
  (`kits/agents/tests/dispatch_tasklist.bats:88-100`).
- Find each worker result and assert `payload.plan_id`
  (`kits/agents/tests/dispatch_tasklist.bats:103-129`).
- Search `inbox`, `active`, `done`, and `blocked` for each intent and assert
  copied `success_criteria`
  (`kits/agents/tests/dispatch_tasklist.bats:131-157`).

That pattern keeps tests aligned with the filesystem lifecycle instead of the
current implementation detail that produced the artifact.
