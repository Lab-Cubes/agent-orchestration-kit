# Discord Plugin Tests

Unit tests for `plugins/discord/` using [bats](https://github.com/bats-core/bats-core) (Bash Automated Testing System).

## Prerequisites

bats must be installed before running these tests:

```bash
# macOS
brew install bats-core

# Ubuntu / Debian
apt-get install bats

# From source (any OS)
git clone https://github.com/bats-core/bats-core.git
cd bats-core && ./install.sh /usr/local
```

## Running the tests

From the `plugins/discord/` directory:

```bash
bats tests/
```

Or run individual files:

```bash
bats tests/test_post.bats
bats tests/test_hooks.bats
bats tests/test_install.bats
```

## What each file covers

| File | Coverage |
|------|----------|
| `test_post.bats` | `_post.sh` — silent fallback when config is missing, User-Agent header, placeholder substitution (`{task_id}`, `{account}`, `{cost_npt}`), token from `accounts` block, empty `channel_id` suppression |
| `test_hooks.bats` | `on-task-claimed.sh`, `on-task-completed.sh`, `on-task-failed.sh` — correct event name passed to `_post.sh`, exit 0 with no config (hook never blocks worker), NPS env vars (`NPS_TASK_ID`, `NPS_AGENT_ID`, `NPS_COST_NPT`) flow through |
| `test_install.bats` | `install.sh` — copies hook files, sets them executable, idempotency (double-run safe), graceful failure when target dir or config is missing, `--uninstall` removes hooks and preserves config |

## Mock strategy

- **curl**: `tests/bin/curl` is a shim that writes all args to a temp file (`$CURL_ARGS_FILE`) and exits 0. Each test prepends `tests/bin` to `$PATH` so the real Discord API is never called.
- **Config fixtures**: `tests/fixtures/valid_config.json` uses obvious placeholder tokens (`TEST_TOKEN_*_FAKE`). The file is named `valid_config.json` (not `config.json`) because the root `.gitignore` excludes `config.json` to prevent real credentials from being committed.
- **Isolated plugin dirs**: each test creates a fresh `mktemp -d` tree so tests don't interfere with each other or with the real plugin source.

## Adding new tests

1. Add a `@test "description" { ... }` block to the appropriate `.bats` file.
2. Use `run <command>` to capture exit status and output; check with `[ "$status" -eq 0 ]` and `grep -q "..." <<< "$output"`.
3. If you need curl inspection, export `CURL_ARGS_FILE` and prepend `tests/bin` to `PATH` in your test's setup.
4. Never write to `BATS_TEST_DIRNAME/../` (the plugin source) — tests are read-only against plugin code.
