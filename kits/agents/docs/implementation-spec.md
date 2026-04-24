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
      "scope": ["/absolute/path/to/worktree"]
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
urn:nps:agent:your-org.example.com:coder-01
urn:nps:agent:dev.localhost:researcher-01
urn:nps:org:dev.localhost
urn:nps:org:your-org.example.com
```

Dev mode uses domain `dev.localhost`. Production uses your org's registered domain.

---

## 8. NPT Formula and Budget Enforcement

NPT (NPS Token) is the cross-model standardized unit from NPS-0 §4.3.

### 8.1 Four-channel formula (v0.2.0)

All four token channels reported by the runtime are counted, multiplied by the model-family exchange rate, and rounded up:

```
NPT = ceil((input_tokens + output_tokens + cache_read_input_tokens + cache_creation_input_tokens) × rate)
```

Exchange rates by model family (`config.json::npt_exchange_rates`; values below are the shipped defaults):

| Family    | Rate | Notes |
|-----------|------|-------|
| `claude`  | 1.05 | Context overhead per NPS-0 §4.3 |
| `gpt`     | 1.0  | |
| `gemini`  | 0.95 | |
| `llama`   | 1.02 | |
| `mistral` | 0.98 | |
| `unknown` | 1.0  | Fallback for unrecognised families |

Model strings (`sonnet`, `haiku`, `opus`, full IDs such as `claude-sonnet-4-6`) are resolved to their family via `scripts/lib/calc_npt.py::detect_family`. Override the table via `config.json::npt_exchange_rates`.

### 8.2 Soft cap and overshoot reporting

Enforcement fires at the **soft cap**, not the hard budget, giving the worker a margin to emit a final result:

```
soft_cap = ceil(budget_npt × soft_cap_ratio)   # default ratio: 0.90
```

`soft_cap_ratio` is sourced from `config.json::default_soft_cap_ratio` (default `0.90`); override per-dispatch with `--soft-cap-ratio`. When the soft cap fires, `stop_reason` in the raw-output JSON is `soft_cap`.

`dispatch-costs.csv` includes an `overshoot_ratio` column:

```
overshoot_ratio = round(cost_npt / budget_npt, 4)
```

### 8.3 Graceful shutdown ladder

The signal sequence depends on which limit fires:

| Trigger      | Signal sequence |
|--------------|-----------------|
| `soft_cap`   | SIGINT → wait(`grace_s`) → SIGTERM → wait(2 s) → SIGKILL |
| `time_limit` | SIGTERM directly (hard wall-clock deadline; no grace period) |

`grace_s` is sourced from `config.json::default_shutdown_grace_s` (default 15 s); override per-dispatch with `--shutdown-grace-s`. When `claude -p` receives SIGINT it emits a result event and exits 0. If the process exits within the grace window the result event flows through the normal result path (`forced = False`). If the grace window expires, escalation continues and the forced path applies.

### 8.4 Forced-result token reporting

When the forced path applies (worker terminated before completing, or grace window expired), the raw-output JSON shape is:

```json
{
  "usage": {
    "input_tokens":                <per-channel count accumulated across all assistant events>,
    "output_tokens":               <per-channel count>,
    "cache_read_input_tokens":     <per-channel count>,
    "cache_creation_input_tokens": <per-channel count>
  },
  "_terminated_npt": <dispatcher-computed NPT total>,
  "stop_reason":     "soft_cap" | "time_limit",
  "is_error":        true
}
```

`usage` holds real per-channel native counts — not a derived NPT total. The parse block uses `_terminated_npt` directly when present, skipping `calc_npt` to avoid double-counting.

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
| `default_max_turns`           | integer  | `100`           | Safety net turn count for the agent runtime CLI.               |
| `default_shutdown_grace_s`    | integer  | `15`            | Seconds to wait for graceful exit after SIGINT (soft cap path). |
| `default_soft_cap_ratio`      | number   | `0.90`          | Fraction of budget at which soft cap fires (0 < ratio ≤ 1).   |
| `npt_exchange_rates`          | object   | see §8.1        | Per-family NPT multipliers. Keys are family names; `$`-prefixed keys are comments. |

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

---

## 11. Runtime-specific touchpoints (reference impl = Claude Code CLI)

The NOP mailbox protocol (§2–7) is runtime-agnostic: files + JSON, any language
or runtime can implement it. The reference dispatcher wraps the Claude Code CLI.
The items below are the integration points a port must customize.

### Subprocess invocation

The reference calls:

```bash
claude -p '<prompt>' \
  --add-dir <scope> \
  --max-budget-usd <cap> \
  --output-format json \
  --model <model> \
  --permission-mode dontAsk \
  --allowedTools '...' \
  --max-turns <n>
```

A port replaces this line with the target runtime's equivalent invocation.

### Cost reporting

The reference parses `total_cost_usd`, `usage.input_tokens`,
`usage.output_tokens`, `usage.cache_read_input_tokens` from the Claude CLI's
JSON output. Other runtimes report differently — OpenAI API returns
`usage.prompt_tokens` + `usage.completion_tokens`; local models may report
nothing. The port adjusts the parser and the NPT-approximation formula (§8)
accordingly.

### Scope permissions

`--add-dir` grants the Claude CLI read/write access to a directory. Other
runtimes use different mechanisms — the OpenAI API has no direct equivalent;
scope is then enforced by tool-call validation in the wrapper. The port
implements scope enforcement appropriate to its runtime.

### Budget ceiling

`--max-budget-usd` is the Claude CLI's hard kill-switch. Other runtimes may
lack an equivalent; ports can implement their own budget tracking via the turn
counter or a cost accumulator that aborts when `budget_npt` is exceeded.

### Model selection

The `--model` flag accepts Claude model names (`haiku`, `sonnet`, `opus`). For
other runtimes, pass the appropriate model identifier for that API.

### Bootstrap convention

Workers read `CLAUDE.md` at their agent directory to bootstrap identity and
protocol. Claude Code loads this file automatically. Other runtimes may require
a different file name or loading mechanism — adjust `templates/AGENT-CLAUDE.md`
and the worker spawn logic accordingly.

### Output format

The reference expects `--output-format json` with a single top-level JSON
document. Other runtimes may stream tokens or emit a different shape. The
parser in `spawn-agent.sh`'s dispatch function is the integration point.
