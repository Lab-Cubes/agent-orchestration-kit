---
title: NOP Worker Implementation Spec
version: "@nps-kit/agents@0.1.0"
audience: agent or developer porting a NOP-speaking wrapper to another runtime
---

# NOP Worker Implementation Spec

Runbook format. Do X. Do Y. Verify Z. No prose.

---

## 1. Directory Layout

```
{agents_home}/
  {worker-id}/
    inbox/          ← pending intent files (PENDING state)
    active/         ← claimed intent files (RUNNING state)
    done/           ← completed/failed intents + result files (terminal states)
    blocked/        ← blocked intent files (BLOCKED state)
    CLAUDE.md       ← worker bootstrap (identity + protocol)
    .claude/
      settings.json ← tool permissions

{worktrees_dir}/
  {task-id}/        ← git worktree, one per task (isolated from target branch)

{logs_dir}/
  dispatch-costs.csv
```

`{agents_home}` defaults to `./agents` (`NPS_AGENTS_HOME` env var overrides).
`{worktrees_dir}` defaults to `./worktrees` (`NPS_WORKTREES_HOME` env var overrides).
Worker ID format: `{type}-{NN}` — e.g. `coder-01`, `researcher-01`.

---

## 2. Intent Message Schema (wire format)

```json
{
  "_ncp": 1,
  "type": "intent",
  "intent": "<imperative verb phrase describing the task>",
  "confidence": 0.95,
  "payload": {
    "_nop": 1,
    "id": "task-{issuer_agent_id}-{YYYYMMDD}-{HHMMSS}",
    "from": "urn:nps:agent:{issuer_domain}:{issuer_agent_id}",
    "to": "urn:nps:agent:{issuer_domain}:{worker_id}",
    "created_at": "2026-04-18T10:42:48.000Z",
    "priority": "urgent | normal | low",
    "category": "code | docs | test | research | refactor | ops",
    "mailbox": { "base": "./" },
    "context": {
      "files": ["path/to/relevant/file"],
      "knowledge": ["key fact 1", "key fact 2"],
      "branch": "git-branch-name"
    },
    "constraints": {
      "model": "haiku | sonnet | opus",
      "time_limit": 900,
      "scope": ["/absolute/path/to/worktree"],
      "proceed_gate": false
    }
  }
}
```

File name: `{payload.id}.intent.json`

All keys are snake_case. `_ncp` and `_nop` are protocol version markers — always `1`.

---

## 3. Result Message Schema (wire format)

```json
{
  "_ncp": 1,
  "type": "result",
  "value": "Human-readable summary of what was done",
  "probability": 0.9,
  "alternatives": [],
  "payload": {
    "_nop": 1,
    "id": "<same as intent payload.id>",
    "status": "completed | failed | timeout | blocked | cancelled",
    "from": "urn:nps:agent:{issuer_domain}:{worker_id}",
    "picked_up_at": "2026-04-18T10:42:50.000Z",
    "completed_at": "2026-04-18T10:43:32.000Z",
    "duration": 42,
    "files_changed": ["path/to/modified/file"],
    "commits": ["abc1234 — commit summary"],
    "follow_up": ["discovered task not in scope — describe here"],
    "error": null
  }
}
```

File name: `{payload.id}.result.json`
Written to `done/` after completing the task.
`duration` is integer seconds.
`error` is null on success; a string describing the failure otherwise.

---

## 4. State Machine

```
PENDING   inbox/{id}.intent.json       ← task arrives, not yet claimed
  ↓  atomic rename (inbox → active)
RUNNING   active/{id}.intent.json      ← worker is executing
  ↓  terminal transition
COMPLETED done/{id}.intent.json        ← intent archived, work done
           done/{id}.result.json        ← result written
FAILED    done/{id}.intent.json        ← intent archived, work failed
           done/{id}.result.json        ← result with error field set
TIMEOUT   done/{id}.intent.json        ← intent archived, time limit exceeded
           done/{id}.result.json        ← partial summary + error
BLOCKED   blocked/{id}.intent.json     ← needs external input before resuming
CANCELLED done/{id}.intent.json        ← abandoned, no result required
```

Valid transitions:

| From      | To                                          |
|-----------|---------------------------------------------|
| PENDING   | RUNNING, CANCELLED                          |
| RUNNING   | COMPLETED, FAILED, TIMEOUT, BLOCKED         |
| BLOCKED   | RUNNING, CANCELLED                          |
| COMPLETED | (terminal — no further transitions)         |
| FAILED    | (terminal)                                  |
| TIMEOUT   | (terminal)                                  |
| CANCELLED | (terminal)                                  |

---

## 5. Worker Loop Pseudocode

Single-shot mode (execute one task and exit):

```
START
  scan inbox/ for files matching *.intent.json
  if none found:
    exit(0)

  sort files lexicographically, take first
  attempt atomic rename: inbox/{file} → active/{file}
  if rename fails with ENOENT:
    # another worker claimed it — exit cleanly
    exit(0)

  parse intent from active/{file}
  record picked_up_at = now()

  execute task:
    read files in constraints.scope
    make changes
    run verification (type-check, tests)
    commit to git with message "worker(type): summary"

  record completed_at = now()
  duration = completed_at - picked_up_at

  rename active/{file} → done/{file}
  write done/{id}.result.json

  run on-task-completed hook (if present)
  post Discord notification (if configured)
  exit(0)

ON ERROR:
  rename active/{file} → done/{file}  (if not already done)
  write done/{id}.result.json with status=failed, error=<message>
  run on-task-failed hook (if present)
  exit(1)
```

Loop mode (continuous — drain inbox until empty, then exit):

```
LOOP:
  scan inbox/ for *.intent.json
  if none: exit(0)
  execute single-shot logic for first file
  goto LOOP
```

---

## 6. Hook Contract

Hooks are optional executable scripts placed in `hooks/`. The dispatch script
runs them at lifecycle events. A broken or missing hook never blocks the worker.

### Event list

| Event            | Script name               | When it fires                              |
|------------------|---------------------------|--------------------------------------------|
| `task-claimed`   | `on-task-claimed.sh`      | After intent is written to inbox, before worker launches |
| `task-completed` | `on-task-completed.sh`    | After `result.json` is written             |
| `task-failed`    | `on-task-failed.sh`       | After fallback result is generated         |

### Environment variables passed to every hook

| Variable       | Value                                        |
|----------------|----------------------------------------------|
| `NPS_TASK_ID`  | Full task ID (`task-{issuer}-{timestamp}`)   |
| `NPS_AGENT_ID` | Worker ID that handled the task              |
| `NPS_STATUS`   | Lifecycle status string (`pending`, `completed`, `failed`) |
| `NPS_COST_NPT` | NPT consumed (integer; 0 for pre-completion events) |
| `NPS_EVENT`    | Event name (`task-claimed`, `task-completed`, `task-failed`) |

### Exit codes

| Exit code | Meaning                           |
|-----------|-----------------------------------|
| 0         | Hook succeeded — no action taken  |
| non-zero  | Hook failed — logged as warning, worker continues |

### Stdin

Currently empty. Reserved for future task-JSON streaming — do not rely on it.

### File naming

Any file in `hooks/` named `on-<event>` with a shebang and executable bit is
a valid hook. Extensions allowed: `.sh`, `.py`, `.js`, or any other interpreted
language. Example: `on-task-completed.sh`, `on-task-completed.py`.

---

## 7. NID URN Format

```
urn:nps:<entity-type>:<issuer-domain>:<identifier>
```

| Component       | Values                        | Constraints                        |
|-----------------|-------------------------------|------------------------------------|
| `entity-type`   | `agent`, `node`, `org`        | Literal, one of three values       |
| `issuer-domain` | RFC 1034 domain               | `[A-Za-z0-9.-]+`                   |
| `identifier`    | Agent or node identifier      | `[A-Za-z0-9._-]+`, required for agent/node |

Org NIDs omit `identifier`:

```
urn:nps:org:<issuer-domain>
```

### Regex patterns

Agent/node NID:
```
/^urn:nps:(agent|node|org):([A-Za-z0-9.-]+):([A-Za-z0-9._-]+)$/
```

Org NID:
```
/^urn:nps:org:([A-Za-z0-9.-]+)$/
```

### Examples

```
urn:nps:agent:cloverthe.ai:coder-01
urn:nps:agent:dev.localhost:researcher-01
urn:nps:org:dev.localhost
urn:nps:org:cloverthe.ai
```

Dev mode uses domain `dev.localhost`. Production uses your org's registered domain.

---

## 8. NPT Approximation Formula

NPT (NPS Token) is the cross-model standardized unit from NPS-0 §4.3.

**v0.1.0 approximation:** sum of all token counts from the Claude Code CLI output.

```
NPT ≈ input_tokens + output_tokens + cache_read_tokens
```

Do not include cache_write_tokens — write overhead is not consumed compute.

### Per-model token rates (approximate, as of 2026-04-18)

| Model   | Input ($/MT) | Output ($/MT) | Cache read ($/MT) |
|---------|-------------|---------------|-------------------|
| haiku   | 0.80        | 4.00          | 0.08              |
| sonnet  | 3.00        | 15.00         | 0.30              |
| opus    | 15.00       | 75.00         | 1.50              |

MT = million tokens. Use these to convert NPT budget to approximate USD ceiling.

USD estimate (for budget planning only):

```
USD ≈ (input_tokens × input_rate + output_tokens × output_rate + cache_read_tokens × cache_rate) / 1_000_000
```

This is an approximation. Actual billing depends on Anthropic pricing at time of use.

---

## 9. Configuration Keys

Copy `config.example.json` to `config.json`. Edit before first use.

| Key                           | Type     | Default         | Description                                                    |
|-------------------------------|----------|-----------------|----------------------------------------------------------------|
| `issuer_domain`               | string   | `dev.localhost` | Domain fragment in NIDs. Use org domain for production.        |
| `issuer_agent_id`             | string   | `operator`      | Agent ID of the orchestrator/dispatcher.                       |
| `default_capabilities`        | string[] | `["nop:execute"]` | Capabilities granted to all workers by default.              |
| `default_budget_npt`          | integer  | `20000`         | Per-task NPT cap when no category budget applies.              |
| `category_budget_npt.code`    | integer  | `30000`         | NPT cap for `code` category tasks.                             |
| `category_budget_npt.docs`    | integer  | `40000`         | NPT cap for `docs` category tasks.                             |
| `category_budget_npt.test`    | integer  | `30000`         | NPT cap for `test` category tasks.                             |
| `category_budget_npt.research`| integer  | `60000`         | NPT cap for `research` category tasks.                         |
| `category_budget_npt.refactor`| integer  | `40000`         | NPT cap for `refactor` category tasks.                         |
| `category_budget_npt.ops`     | integer  | `30000`         | NPT cap for `ops` category tasks.                              |
| `default_model`               | string   | `sonnet`        | Model used when `constraints.model` is not set in intent.      |
| `default_time_limit_s`        | integer  | `900`           | Wall-clock seconds before timeout. Hard stop.                  |
| `default_max_turns`           | integer  | `100`           | Safety net turn count for Claude Code CLI.                     |

Env var overrides (set in `.env`):

| Variable             | Overrides                  |
|----------------------|----------------------------|
| `NPS_AGENTS_HOME`    | Path to agents directory   |
| `NPS_WORKTREES_HOME` | Path to worktrees directory|
| `NPS_LOGS_HOME`      | Path to logs directory     |
| `NPS_ISSUER_DOMAIN`  | `config.json issuer_domain`|
| `NPS_ISSUER_AGENT_ID`| `config.json issuer_agent_id` |

---

## 10. Port Verification Checklist

Use this checklist to verify a new runtime port implements the protocol correctly.

### Mailbox protocol

- [ ] Worker scans `inbox/` for `*.intent.json` on startup.
- [ ] Worker claims via atomic rename: `inbox/{id}.intent.json` → `active/{id}.intent.json`.
- [ ] Rename failure with ENOENT is handled as "already claimed" — exit cleanly, do not error.
- [ ] Worker writes `done/{id}.result.json` for every task — including failures.
- [ ] Worker moves intent to `done/` before or immediately after writing result.
- [ ] Blocked tasks are moved to `blocked/{id}.intent.json` (not `done/`).

### Intent parsing

- [ ] `_ncp == 1` check passes before processing.
- [ ] `type == "intent"` check passes before processing.
- [ ] `payload.id` is used as the canonical task ID throughout.
- [ ] `payload.constraints.scope` is respected — worker stays within scope.
- [ ] `payload.constraints.time_limit` is enforced — write timeout result on exceed.
- [ ] `payload.constraints.proceed_gate == true` causes worker to pause before file changes.

### Result writing

- [ ] `result.payload.id` matches `intent.payload.id`.
- [ ] `result.payload.from` is the worker's own NID.
- [ ] `result.payload.status` is one of: `completed`, `failed`, `timeout`, `blocked`, `cancelled`.
- [ ] `result.payload.picked_up_at` is set at claim time.
- [ ] `result.payload.completed_at` is set when work finishes.
- [ ] `result.payload.duration` is integer seconds (`completed_at - picked_up_at`).
- [ ] `result.payload.files_changed` lists all modified files.
- [ ] `result.payload.commits` lists commit hashes + summaries.
- [ ] `result.payload.follow_up` lists discovered tasks outside current scope.
- [ ] `result.payload.error` is `null` on success; non-null string on failure.

### NID format

- [ ] NIDs match regex: `^urn:nps:(agent|node|org):([A-Za-z0-9.-]+):([A-Za-z0-9._-]+)$`
- [ ] `from` and `to` in both intent and result are valid NIDs.
- [ ] Issuer domain matches `config.json issuer_domain`.

### Hooks

- [ ] Hooks are called after the triggering event, not before.
- [ ] Hook failure (non-zero exit) is logged as warning — worker continues.
- [ ] Hook env vars `NPS_TASK_ID`, `NPS_AGENT_ID`, `NPS_STATUS`, `NPS_COST_NPT`, `NPS_EVENT` are set.
- [ ] Missing hook script is treated as no-op (not an error).

### Git worktree (if implementing worktree isolation)

- [ ] Worktree is created before writing the intent to inbox.
- [ ] Worktree path replaces the original scope path in `constraints.scope`.
- [ ] Worker commits all changes before writing result.
- [ ] Worker does not push — orchestrator squash-merges after review.
- [ ] Worktree and branch are cleaned up after merge.

### Error cases

- [ ] Unparseable intent → write `failed` result with `NOP-TASK-PARSE-FAILED` in error field.
- [ ] Scope file missing → write `failed` result with `NOP-TASK-SCOPE-MISSING`.
- [ ] Time limit exceeded → write `timeout` result with `NOP-TASK-TIMEOUT`.
- [ ] Needs external input → write `blocked` result with `NOP-TASK-BLOCKED`.
- [ ] Git conflict → write `failed` result with `NOP-TASK-GIT-CONFLICT`.
- [ ] Unclear instructions → write `blocked` result with `NOP-TASK-UNCLEAR`.
- [ ] Scope expansion attempted → write `failed` result with `NOP-DELEGATE-SCOPE-VIOLATION`.
