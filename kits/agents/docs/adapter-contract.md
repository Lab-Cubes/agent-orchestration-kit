# Runtime Adapter Contract

Adapters wrap agent CLI runtimes so the dispatcher stays runtime-agnostic.
Each adapter lives in `scripts/lib/adapters/<name>.py` and extends `AdapterBase`.

## Interface (6 methods)

| Method | Signature | Purpose |
|--------|-----------|---------|
| `build_cmd` | `(prompt, model, max_turns, add_dirs) → list[str]` | Construct the subprocess command |
| `parse_event` | `(line: str) → dict \| None` | Parse one stdout line into an event dict, or None to skip |
| `extract_usage` | `(event: dict) → dict` | Extract native token usage from an event (empty dict if none) |
| `extract_result` | `(event: dict) → dict \| None` | Extract final result dict, or None if not a result event |
| `model_family` | `(model: str) → str` | Resolve model string to family for NPT rate lookup |
| `shutdown_signal` | `() → signal` | Signal for graceful shutdown (e.g. SIGINT, SIGTERM) |

## Shipped adapters

| Adapter | Runtime | Output format | Usage reporting | Shutdown |
|---------|---------|---------------|-----------------|----------|
| `claude.py` | Claude Code CLI | stream-json (per-event) | Per-assistant-event | SIGINT |
| `kiro.py` | Kiro CLI | Raw text | None (no token reporting) | SIGTERM |

## Adding a new adapter

1. Create `scripts/lib/adapters/<name>.py`
2. Extend `AdapterBase`, implement all 6 methods
3. Add the runtime name to the preflight check in `spawn-agent.sh` `cmd_dispatch()`
4. Add a loader branch in the dispatch Python heredoc (`if runtime_name == '<name>':`)
5. Add a mock in `tests/bin/<cli-name>` and BATS tests in `tests/test_runtime_adapter.bats`

## Limitations

- Runtimes without stream-json output (e.g. Kiro) get synthetic results from collected text
- Runtimes without per-event token reporting have no NPT budget enforcement; `--time-limit` is the safety net
- `add_dirs` scope enforcement is runtime-specific: Claude uses `--add-dir`, Kiro has no equivalent — `constraints.scope` is advisory-only under Kiro until upstream adds a filesystem-scope flag

## Security surface differences

| Adapter | Tool trust mechanism | Scope |
|---------|---------------------|-------|
| Claude | `--permission-mode dontAsk --allowedTools Read,Edit,Write,Bash,Glob,Grep` (explicit allowlist) | `--add-dir` restricts filesystem access |
| Kiro | `--trust-tools=fs_read,fs_write,execute_bash,glob,grep,code,web_search,web_fetch,use_aws` (named tools, full capability) | No filesystem restriction — worker can access any path |

Operators should be aware that Kiro workers have broader filesystem access than Claude workers.

## References

- Issue #57 — runtime adapter layer design
- `scripts/lib/adapters/__init__.py` — `AdapterBase` ABC
