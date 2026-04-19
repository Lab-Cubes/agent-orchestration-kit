# OpenClaw NOP Adapter — v1

NOP adapter for dispatching tasks to an [OpenClaw](https://github.com/openclaw/openclaw) agent runtime.
Implements the NOP Adapter Contract v0.2 (`adapter-contract-draft.md`).

## What it does

`adapter.sh` accepts a **TaskPacket** JSON document on stdin and invokes
`openclaw agent --agent <id> --message <prompt> --json` synchronously.
Lifecycle events are written as NDJSON to the file given by `--event-log`.

## Usage

```sh
echo '<TaskPacket JSON>' | ./adapter.sh --event-log /tmp/events.ndjson
```

**Required fields in TaskPacket:**

| Field | Description |
|---|---|
| `subtask_id` | NOP subtask UUID |
| `parent_task_id` | Parent DAG task ID |
| `params.prompt` | Prompt string sent to the agent |
| `params.context.agent_id` | OpenClaw agent id (default: `main`) |

## Event log format

Each line is a JSON object (NDJSON) per the NOP Adapter Contract §"Event envelope":

```
{"event":"lifecycle.spawning","stream_id":"...","task_id":"...","subtask_id":"...","sender_nid":"...","timestamp":"...","seq":0}
{"event":"lifecycle.running",  ...,"seq":1}
{"event":"lifecycle.done",     ...,"seq":2, "data":{"result":{...},"cost":{...}}}
```

Terminal events: `lifecycle.done`, `lifecycle.failed`, `lifecycle.timed_out`.

## Dependencies

- `bash` 4+
- `python3` (stdlib only — `json`, `uuid`, `subprocess`, `datetime`)
- `openclaw` CLI on `$PATH`
- A running OpenClaw gateway (default `localhost:18789`)

## Running the tests

Install [bats-core](https://github.com/bats-core/bats-core) then:

```sh
bats tests/test_adapter.bats
```

Tests use a stub `openclaw` in `tests/bin/` — no live gateway needed.
Stub behaviour is controlled by `MOCK_OPENCLAW_MODE` (`happy` / `timeout` / `failure`).

## manifest.json

```json
{
  "adapter_id": "openclaw",
  "adapter_version": "0.1.0",
  "runtimes_supported": ["openclaw"],
  "nop_version": "v0.2",
  "preflight_supported": false,
  "streaming_supported": false,
  "cancel_supported": false
}
```

## TODOs / Non-goals for v1

The following are explicitly out of scope and should be addressed in future iterations:

- **ACP runtime routing** — currently hardcoded to the direct `openclaw agent` CLI.
  Routing through the ACP layer (multi-runtime dispatch) is not implemented.
- **Real preflight** — `preflight_supported: false`. The adapter does not respond to
  `action="preflight"` DelegateFrames. Add a fast capability-probe code path.
- **Idempotency cache** — `idempotency_key` in the TaskPacket is accepted but ignored.
  Implement 24 h cache backed by artifact existence check per the contract spec.
- **HTTP/SSE transport** — only file-backed NDJSON is implemented. Add an optional
  SSE endpoint so orchestrators can subscribe instead of tail-polling the event log.
- **Cancel DelegateFrame handling** — `cancel_supported: false`. SIGTERM/SIGINT
  handling and cancel-action DelegateFrame processing are not implemented.
- **`openclaw tasks show` authoritative status** — on non-zero exit the adapter
  currently classifies by stderr pattern only. Add a `openclaw tasks show <runId>`
  fallback to get the authoritative `status` field per the contract appendix.
