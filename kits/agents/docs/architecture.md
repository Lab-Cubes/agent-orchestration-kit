---
title: Orch-kit Architecture
version: "@nps-kit/agents@0.2.4-draft"
audience: kit adopters, orchestrator implementers, NPS contributors
---

# Orch-kit Architecture

This document describes the architectural model of Orch-kit: the layers, artifacts, gate boundaries, and NPS alignment. For the wire-format runbook, see [`implementation-spec.md`](implementation-spec.md).

---

## 1. Purpose

Orch-kit is a reference implementation of NPS (Neural Protocol Suite), centred on NOP (NPS-5, Neural Orchestration Protocol) for multi-agent task dispatch. It demonstrates how NPS protocols compose to enable:

- Cross-vendor agent cooperation under a single NPT budget (NPS-0 + NPS-3 + NPS-5)
- Identity-enforced scope carving at delegation time (NPS-3 NIP)
- DAG-based task orchestration with typed data flow (NPS-5 NOP)
- Filesystem-based transport as a simpler alternative to `nwp://` for local single-host deployments

The kit targets a human-in-loop operational model: an Overseer ("OSer") approves plans and decomposed task-lists, while workers execute narrow intents in isolated worktrees.

---

## 2. Four-layer model

```
┌─────────────────┐
│   Plan          │  Human operator + OSer — strategic intent, scope, success criteria
│                 │  Artifact: plans/{plan-id}/plan.md
└────────┬────────┘
         ↓ OSer-ack
┌─────────────────┐
│   Decompose     │  OSer + Decomposer (LLM-backed) — plan → versioned task-list JSON
│                 │  Artifact: task-lists/{plan-id}/pending/v{N}.json
└────────┬────────┘
         ↓ OSer-ack (rename pending/v{N}.json → v{N}.json)
┌─────────────────┐
│   Dispatch      │  Dispatcher (programmatic, no LLM) — consume task-list,
│                 │  spawn workers, track state, hold merges until green
│                 │  Artifact: task-list-state.json + escalation.jsonl
└────────┬────────┘
         ↓ per-task intent
┌─────────────────┐
│   Execute       │  Workers (per-task, isolated worktree, narrow intent)
│                 │  Artifacts: inbox/ → active/ → done/ mailbox
└─────────────────┘
         ↓ results
   OSer verification via git/gh/bats → merge
```

Each layer has one responsibility. Boundaries are filesystem artifacts, making the system composable (new layers can be inserted between existing ones by reading one artifact and producing another).

### 2.1 Layer responsibilities

| Layer | Owner | Input | Output | LLM? |
|---|---|---|---|---|
| Plan | Human operator + OSer | Human intent | `plans/{plan-id}/plan.md` | No |
| Decompose | OSer + Decomposer | Plan artifact | `task-lists/{plan-id}/pending/v{N}.json` | Yes (Decomposer) |
| Dispatch | Dispatcher | Acked task-list | Worker intents + `task-list-state.json` + `escalation.jsonl` | No |
| Execute | Workers | Intent | Result file + git commits on worktree branch | Yes (worker runtime) |

### 2.2 Gate boundaries

Three human-in-loop gates:

1. **Plan → Decompose:** OSer acks the plan (manual). Plan artifact gains `osi_ack_at` and `osi_ack_by`.
2. **Decompose → Dispatch:** OSer reviews task-list JSON. Ack = rename `pending/v{N}.json` → `v{N}.json` via `cmd_ack <plan-id> <version>`.
3. **Execute → Done:** OSer verifies worker claims via git/gh/bats. Dispatcher enforces merge-hold until full task-list-state is green.

Verification is the admission condition between layers, not a layer itself.

---

## 3. Artifact layout

```
$NPS_STATE_HOME/
├── plans/
│   └── {plan-id}/
│       └── plan.md                             # OSer-authored, YAML frontmatter + body
├── task-lists/
│   └── {plan-id}/
│       ├── pending/
│       │   └── v{N}.json                       # Decomposer emitted, awaiting OSer ack
│       ├── v1.json, v2.json, ...               # OSer-acked, consumed by Dispatcher
│       ├── task-list-state.json                # graph-level state (one active version at a time)
│       └── escalation.jsonl                    # append-only JSONL, schema_version 1
├── agents/
│   └── {worker-id}/
│       ├── inbox/        active/  done/  blocked/
│       ├── CLAUDE.md     .claude/settings.json
├── worktrees/
│   ├── {task-id}/                              # active per-task worktree
│   └── superseded/{plan-id}/v{N}/{agent-id}/{task-id}/   # on re-decompose supersede
└── logs/
    └── dispatch-costs.csv                      # pre-existing NPT CSV log
```

`$NPS_STATE_HOME` falls back to `$XDG_STATE_HOME/nps-kit` then `$HOME/.nps-kit`.

---

## 4. Schemas

### 4.1 Plan artifact (`plans/{plan-id}/plan.md`)

YAML frontmatter + markdown body. Human-editable.

```yaml
---
plan_id: plan-{issuer}-{YYYYMMDD}-{HHMMSS}
created_at: 2026-04-24T12:34:56Z
created_by: urn:nps:agent:example.com:opus-overseer
osi_ack_at: 2026-04-24T12:40:01Z     # set on OSer ack; absent = pending
osi_ack_by: urn:nps:agent:example.com:overseer-01    # or OSer's NID when automated
title: Short plan title
status: pending | acked | executing | completed | cancelled
---

# Body

Strategic intent in free-form markdown. Scope, success criteria, constraints,
context references. Human-authored.
```

**Plan authoring is out of kit scope.** The kit ingests plans; authoring tools (markdown editor or adopter-specific workflow) are adopter's choice.

### 4.2 Task-list JSON (`task-lists/{plan-id}/{pending/,}v{N}.json`)

Aligned with NOP TaskFrame (NPS-5 §3.1). Kit-specific additions flagged.

```json
{
  "_ncp": 1,
  "type": "task_list",
  "schema_version": 1,
  "plan_id": "plan-...",
  "version_id": 1,
  "created_at": "2026-04-24T12:45:00Z",
  "created_by": "urn:nps:agent:example.com:decomposer-01",
  "prior_version": null,
  "pushback_reason": null,
  "dag": {
    "nodes": [
      {
        "id": "node-1",
        "action": "research-login-flow",
        "agent": "urn:nps:agent:example.com:researcher-01",
        "input_from": [],
        "input_mapping": {},
        "scope": ["src/auth/**", "docs/auth.md"],
        "budget_npt": 8000,
        "timeout_ms": 600000,
        "retry_policy": { "max_retries": 1, "backoff_ms": 5000 },
        "condition": null,
        "success_criteria": {
          "files_touched": ["docs/auth-flow.md"],
          "tests": []
        }
      },
      {
        "id": "node-2",
        "action": "refactor-login-handler",
        "agent": "urn:nps:agent:example.com:coder-01",
        "input_from": ["node-1"],
        "input_mapping": { "research_doc": "node-1.files_touched[0]" },
        "scope": ["src/auth/login.ts", "src/auth/__tests__/**"],
        "budget_npt": 15000,
        "timeout_ms": 1200000,
        "retry_policy": { "max_retries": 1, "backoff_ms": 5000 },
        "condition": null,
        "success_criteria": {
          "commits": "≥1",
          "tests": ["login.test.ts"]
        }
      }
    ],
    "edges": [
      { "from": "node-1", "to": "node-2" }
    ]
  }
}
```

**Field alignment with NOP TaskFrame (NPS-5 §3.1):**

| Kit field | NOP TaskFrame field | Notes |
|---|---|---|
| `dag.nodes[].id` | `dag.nodes[].id` | Direct |
| `dag.nodes[].action` | `dag.nodes[].action` | Kit uses verb phrase (not `nwp://` URL) — deviation, documented |
| `dag.nodes[].agent` | `dag.nodes[].agent` | Direct, NIDs |
| `dag.nodes[].input_from` | `dag.nodes[].input_from` | Direct |
| `dag.nodes[].input_mapping` | `dag.nodes[].input_mapping` | Direct, but limited to result-field references in kit v1 |
| `dag.nodes[].timeout_ms` | `dag.nodes[].timeout_ms` | Direct |
| `dag.nodes[].retry_policy` | `dag.nodes[].retry_policy` | Direct |
| `dag.nodes[].condition` | `dag.nodes[].condition` | Kit uses subset of CEL syntax or null |
| `dag.nodes[].scope` | (via DelegateFrame.delegated_scope) | Kit promotes to task-node level for filesystem dispatch |
| `dag.nodes[].budget_npt` | (via `TaskFrame.context.estimated_npt`) | Kit promotes to node-level for per-task budget |
| `dag.nodes[].success_criteria` | **Kit extension** | Machine-checkable DoD; not in NOP spec |

**Kit-specific additions (not in NOP):**

- `schema_version` — for v1→v2 log-format evolution
- `plan_id` — parent plan reference (links back to human-authored plan)
- `version_id` — re-decomposition version number
- `prior_version`, `pushback_reason` — for v_{N+1} re-decompose context
- `success_criteria` — machine-checkable done-definition

### 4.3 Task-list state (`task-lists/{plan-id}/task-list-state.json`)

Graph-level execution state. One active version at a time.

```json
{
  "schema_version": 1,
  "plan_id": "plan-...",
  "active_version": 2,
  "superseded_versions": [1],
  "node_states": {
    "node-1": {
      "status": "completed",
      "task_id": "task-coder-20260424-124712",
      "started_at": "2026-04-24T12:47:12Z",
      "completed_at": "2026-04-24T12:51:48Z",
      "result_path": "agents/researcher-01/done/task-coder-20260424-124712.result.json",
      "retries": 0
    },
    "node-2": {
      "status": "pending",
      "task_id": null,
      "started_at": null,
      "completed_at": null,
      "result_path": null,
      "retries": 0
    }
  },
  "merge_hold": true,
  "updated_at": "2026-04-24T12:52:00Z"
}
```

Status enum: `pending | running | completed | failed | superseded | blocked`. `superseded` is set when a higher version supersedes in-flight work.

### 4.4 Escalation log (`task-lists/{plan-id}/escalation.jsonl`)

Append-only JSONL. Kit-level mandated schema enables cross-implementation compatibility.

```json
{"schema_version":1,"timestamp":"2026-04-24T12:47:12Z","plan_id":"plan-...","prior_version":1,"pushback_source":"node-3","pushback_reason":"scope_insufficient","dispatcher_acted":"invoked_decomposer","decomposer_output_version":2,"osi_ack_at":"2026-04-24T12:47:45Z","osi_ack_verdict":"approve","duration_s":33,"escalation_level":"task"}
```

Fields: `schema_version, timestamp, plan_id, prior_version, pushback_source, pushback_reason, dispatcher_acted, decomposer_output_version, osi_ack_at, osi_ack_verdict, duration_s, escalation_level`.

`escalation_level` enum (v1): `"task" | "version"`. `"plan"` reserved for v2.

Change-class classification (`change_class`, `scope_patch | graph_restructure | task_add | task_remove`) is v2 territory, tied to batch-ack. Not present in v1 schema — when v2 ships, the field is added and `schema_version: 2` events carry it while v1 events (without the field) continue to parse via the `schema_version` discriminator.

### 4.5 Intent + Result payloads (NPS-1/5)

`NopIntentPayload` and `NopResultPayload` in [`src/nop-types.ts`](../src/nop-types.ts) gain a `plan_id` field. Additive, non-breaking. Optional in v1; required once Dispatcher 4a (#63) is the only intent-emitting caller — at which point every intent carries its plan_id by construction.

```typescript
interface NopIntentPayload {
  _nop: 1;
  id: string;              // task-{issuer}-{YYYYMMDD}-{HHMMSS}
  plan_id?: string;        // Optional in v1; required post-#63 (Dispatcher 4a)
  from: string;
  to?: string;
  // ... existing fields
}
```

`NopResultPayload` carries the same optional `plan_id?: string` back-pointer, enabling cross-plan worker reuse with flat inbox.

### 4.6 Schema validator

JSON Schema documents (draft-2020-12) for §4.1–§4.4 live at `src/schemas/*.schema.json`:

- `task-list.schema.json` — mirrors `TaskListMessage`
- `task-list-state.schema.json` — mirrors `TaskListState` + `NodeState`
- `escalation-event.schema.json` — mirrors `EscalationEvent`
- `plan-frontmatter.schema.json` — plan frontmatter fields

A Python validator at `scripts/lib/validate_schema.py` accepts `<schema-path> <instance-path>`, exits 0 on valid and 1 on validation failure. `cmd_decompose` (#66) will invoke it to validate Decomposer output against `task-list.schema.json` before writing `pending/v{N}.json` — schema violations become `decomposer_failed` escalation events with the specific errors captured.

`additionalProperties: false` is deliberate on all four schemas. Unknown fields are rejected so schema drift between Decomposer output and kit expectations is visible at ingest, not at runtime.

---

## 5. Decomposer interface

The kit mandates an interface; it does not mandate an implementation.

### 5.1 Invocation contract

Command: `cmd_decompose` (in `spawn-agent.sh`). Stdin receives JSON, stdout emits JSON, exit 0 = success.

**Input:**

```json
{
  "plan": "<full plan.md content, YAML frontmatter + body>",
  "context": { "files": [], "knowledge": [], "branch": "main" },
  "prior_version": null,          // task-list JSON of v_N (null on first emission)
  "prior_state": null,            // task-list-state.json at time of pushback
  "pushback": null                // pushback message text or null
}
```

**Output:** task-list JSON per §4.2.

**Exit codes:** 0 = success, non-zero = decomposer failure (logged as `decomposer_failed` escalation event).

### 5.2 Configuration

`config.json::decomposer_cmd` (default: `python3 scripts/lib/decomposers/trivial.py`). Adopter swaps via config. Runtime-agnostic — any executable that honours the stdin/stdout protocol works.

`config.json::decomposer_timeout_ms` (default `60000`). `cmd_decompose` enforces the timeout; exceeded invocations are killed and logged as `decomposer_failed` with `reason: "timeout"`. Prevents adopter Decomposers wedged on slow LLM calls from stalling the whole dispatch pipeline.

### 5.3 NOP DAG validation

`cmd_decompose` validates the Decomposer's output against NOP DAG constraints (per NPS-5 §3.1.1) before accepting it:

- **Maximum node count: 32.** Violation → `NOP-TASK-DAG-TOO-LARGE` escalation event; output rejected.
- **Acyclicity.** Violation → `NOP-TASK-DAG-CYCLE` escalation event; output rejected.

Rejected output does not become a pending task-list. Escalation-log event written; OSer sees the Decomposer failure and decides whether to retry or escalate.

**Delegation-chain depth (NPS-5 §3.1.1, max 3) is not enforced in v1.** The limit governs chained `DelegateFrame` across agent boundaries (Orchestrator → Worker → Sub-Worker). The kit's filesystem dispatch has no sub-worker delegation path — every worker executes within a single hop from the Dispatcher. Chain depth is always 1. Re-introduce the check when the kit implements agent-to-agent sub-delegation.

### 5.4 Trivial-fallback Decomposer

The kit ships `scripts/lib/decomposers/trivial.py`:

- One task per plan
- `scope = cwd`
- `depends_on = []`
- `success_criteria = {}`
- `agent` = first available worker of type `coder`

Makes `bin/demo` runnable without external LLM integration. Adopters ship sophisticated Decomposers via config override.

**Compatibility caveat with tightened personas.** The trivial-fallback emits broad-scope intents (`scope = ["."]`, empty `success_criteria`). Tightened personas from issue 9 assume narrow Decomposer output — broad intents combined with tightened personas can starve workers (no strategic planning allowed, no narrow direction provided). Adopters running the trivial decomposer should keep the current untightened personas; tightened personas ship alongside a sophisticated Decomposer. See issue 9 DoD.

**Anti-drift counterpart.** Tightened personas (issue 108) add a role-specific exploration baseline to each worker type: coders stop at the files in `constraints.scope` and their tests; critics stop at the diff, files it touches, and one level of dependents; researchers stop at the sources directly named in `context.files` and `context.knowledge`. Exceeding this baseline triggers a `BLOCKED` result with `pushback_reason: "intent under-specified, drifted into research mode"`. This is the symmetric counterpart to the trivial-decomposer caveat: the trivial decomposer produces intents that violate the baseline by construction, so running trivial-decomposer intents against anti-drift personas will produce BLOCKED results for under-specified tasks. Narrow Decomposer output is required for anti-drift personas to function as intended.

### 5.5 Statelessness

Kit-side stateless: the kit holds no Decomposer state between invocations. Inputs fully determine output. Decomposer implementations may maintain internal state (e.g., prompt caching, LLM context) but the kit does not rely on it.

On re-decompose: `prior_version` and `prior_state` are passed so the Decomposer can emit a coherent v_{N+1}.

---

## 6. Dispatcher behaviour

### 6.1 Hard contract

**The Dispatcher never emits a task-list.** Task-lists are always Decomposer output, always OSer-gated via `cmd_ack`.

The Dispatcher MAY invoke the Decomposer on worker pushback. Every invocation:

1. Logs an escalation event (`dispatcher_acted: invoked_decomposer`).
2. Receives Decomposer output in `pending/v{N+1}.json`.
3. Requires real-time OSer ack (v1). Batch-ack deferred to v2 alongside `change_class` classification.

**Pushback resumption ritual (v1 cost).** When Dispatcher invokes Decomposer mid-dispatch, it exits cleanly after the new `pending/v{N+1}.json` is written. OSer then runs `cmd_ack <plan-id> N+1` to promote the version, then re-invokes `cmd_dispatch_tasklist <plan-id>` to resume execution. Three-step manual sequence per pushback. Known v1 friction; classification-based batch-ack lifts it in v2.

### 6.2 One-shot per dispatch (v1)

Dispatcher is one-shot-per-dispatch: process starts, reads acked task-list, spawns workers, tracks state, exits when graph is green (or escalates). No long-running daemon in v1.

**Concurrency guard:** two accidental `cmd_dispatch_tasklist` invocations on the same `plan_id` would race read-modify-write on `task-list-state.json` (worker-claim renames are POSIX-safe; state-file writes are not). Dispatcher acquires `flock` on `$STATE/task-lists/{plan-id}/.dispatcher.lock` before state-file access; second invocation waits or fails fast with a clear error message.

### 6.3 Merge hold

Dispatcher holds all worker merges until the full task-list-state is green. This prevents partial-completion landing.

**Escape hatch:** `config.json::merge_hold_enforce: false` — every merge becomes manual `cmd_ack`-style approval; warning logged. For emergency recovery from 4b bugs without code change.

### 6.4 Versioning + supersede

When `v_{N+1}.json` is acked while v_N is still active, Dispatcher processes every v_N node (not just `running` ones):

1. **Per-node routing by current status + result-file presence:**
   - **`running`** (worker still alive): SIGINT via existing shutdown ladder (`spawn-agent.sh:547-559`), then proceed to step 2.
   - **`blocked` with a result file carrying `pushback_reason`** (pushback-blocked): worker already exited; its pushback is what triggered v_{N+1}. Skip SIGINT + HEAD check + commit. Rename branch to `superseded/...`, set node status `superseded`, emit event `dispatcher_acted: "pushback_superseded"`. These nodes do NOT gate the drain — v_{N+1} is explicitly the resolution.
   - **`blocked` with no pushback result file** (complex-HEAD from a prior drain attempt): stays `blocked`; no action. Gates drain (step 6).
   - **Terminal** (`completed | failed | cancelled | timeout | superseded`): **branch rename only** — rename `agent/{agent-id}/{task-id}` → `superseded/{plan-id}/v{N}/...`. Node status unchanged. Emit event `dispatcher_acted: "supersede_archived"`. Why: un-renamed terminal branches at `agent/...` would otherwise remain mergeable by `cmd_merge` after the version flip, causing v_N terminal work to land alongside v_{N+1} work (duplication or conflict). Archiving keeps the work preservable (cherry-pick from `superseded/...`) without it being treated as current.
2. **HEAD state check** (for `running` workers after SIGINT). `git symbolic-ref --quiet HEAD` on the worktree:
   - **Normal** (HEAD on expected `agent/{agent-id}/{task-id}` branch): proceed to step 3.
   - **Abnormal** (detached HEAD, or HEAD on an unexpected branch — worker mid-rebase, mid-bisect, or checked-out commit): skip steps 3-4, mark node status `blocked`, emit event `dispatcher_acted: "supersede_complex_state"`. OSer investigates the worktree manually. These nodes gate the drain.
3. **Dispatcher-side commit** (normal HEAD only): `git -C {worktree} add -A && git commit -m "supersede: partial work at v{N}" --allow-empty --no-verify`. `--no-verify` skips adopter pre-commit hooks (this is a preservation snapshot, not a contribution); `--allow-empty` ensures the commit lands even if the worktree was clean.
4. **Branch rename**: `agent/{agent-id}/{task-id}` → `superseded/{plan-id}/v{N}/{agent-id}/{task-id}`. Mark node status `superseded`. Per-node escalation event with `dispatcher_acted: "supersede_applied"`.
5. Worktrees left mounted throughout (removal would nuke state; `cmd_supersede_gc` handles later cleanup).
6. **Drain gate — `active_version` flip gated on full v_N termination**:
   - **If all v_N nodes are terminal** (`superseded | completed | failed | cancelled | timeout`): flip `active_version` to N+1, append N to `superseded_versions`, spawn v_{N+1}'s root nodes, resume normal execution.
   - **If any v_N node is `blocked`** (complex-HEAD awaiting OSer triage): supersede is *incomplete*. `active_version` stays at N. Dispatcher exits non-zero with `KIT-SUPERSEDE-INCOMPLETE` and a list of blocked nodes. State file preserves the v_N `node_states` for auditor reconstruction. v_{N+1} execution does **not** begin until the drain completes.

**Why iterate all v_N nodes (not just `running`):** (a) pushback-blocked workers are already exited and have result files — ignoring them would deadlock the drain gate against the very pushback that caused v_{N+1} to exist. (b) Terminal v_N nodes with un-renamed `agent/...` branches would otherwise be mergeable by `cmd_merge` after the flip, polluting v_{N+1}'s result. Branch rename archives them safely. Discriminating by *result-file presence* (pushback-blocked has one; complex-HEAD does not) keeps semantics correct: pushback-blocked are superseded naturally; complex-HEAD gate the drain legitimately; terminal are archived.

**OSer triage of a `blocked` (complex-HEAD) node:** investigate the worktree manually, then either (a) re-attach HEAD and manually mark the node `running` to re-dispatch, or (b) manually rename the branch to `superseded/{plan-id}/v{N}/...` and set node status `superseded` to discard. **Write an escalation event** with `dispatcher_acted: "supersede_resolved"` after either action — closes the audit loop for the triage step. Once all v_N nodes are terminal, re-run `cmd_dispatch_tasklist` to complete the version flip; the Dispatcher spawns v_{N+1}'s root nodes and resumes normal execution.

Merge-hold (§6.3) keys on the current `active_version`'s node states. Because the flip doesn't advance until v_N drains, merge-hold correctly refuses merges while blocked nodes exist — silent partial-version landing is prevented by construction.

**Event granularity:** one escalation event per node transition, not per supersede invocation. A mixed-HEAD supersede (some workers normal, some abnormal) writes one event per worker so audit can reconstruct the per-worker path. Events share `plan_id` + `prior_version` + `decomposer_output_version` — this tuple uniquely identifies a supersede operation without needing a separate op_id UUID.

**Why `blocked` status for complex-HEAD workers** (not a new enum value): `blocked` already means "awaiting external input" in the filesystem state machine at `src/types.ts:41-49`. Detached-HEAD worktrees awaiting OSer triage fit that semantic exactly — no enum expansion needed. The specific blocking reason is captured in the escalation-log `dispatcher_acted` field (`supersede_complex_state`), which OSer reads alongside state during triage.

**Why Dispatcher-side commit** (not worker-side): audit completeness survives workers that don't cooperate on SIGINT. Uncommitted work would otherwise be invisible in git log.

**Helper command for v2:** a `cmd_supersede_resolve` command to automate OSer triage (re-attach HEAD, transition blocked→superseded or blocked→running with state edits). Deferred — v1 uses manual state-file editing documented here.

**Worktree cleanup:** superseded worktrees accumulate at `$NPS_WORKTREES_HOME`. Run `spawn-agent.sh supersede-gc --older-than=N` to bulk-remove by age; `--plan-id` scopes to a single plan. Each removal appends a `dispatcher_acted: "supersede_gc"` escalation event for audit.

### 6.5 Escalation triggers

**Worker → Dispatcher:**
- Result `is_error: true`
- Time or budget cap reached (forced result, existing behaviour)
- Worker reports scope-insufficient / intent-unclear pushback

**Dispatcher → OSer:**
- Same task fails twice (one retry, then escalate)
- Multiple workers fail in one decomposition
- Dependency deadlock

**OSer → Human operator:**
- Scope expansion beyond acked plan
- Cost > 2× plan estimate
- N=3 pushback loop on same plan
- Novel architectural decision not covered by plan
- Any destructive action

Triggers are minimal in v1; adjust as patterns emerge.

---

## 7. NPS alignment and deviations

The kit is a reference implementation of NPS, not a full conformant node.

### 7.1 What the kit implements

- **NPS-3 NIP:** NIDs on all identities (`urn:nps:agent:{domain}:{id}`), scope carving at worker boundary, enforced narrowing (never expansion).
- **NPS-1 NCP:** `_ncp: 1` envelope versioning, type-tagged messages (`intent`, `result`, `task_list`).
- **NPS-0 NPT:** per-family token rates in `config.json::npt_exchange_rates`, `detect_family()` for runtime inference.
- **NPS-5 NOP:** DAG shape (TaskFrame-aligned), scope-carving (DelegateFrame-aligned), filesystem mailbox transport for local single-host dispatch. DAG validation per NPS-5 §3.1.1 enforced at `cmd_decompose`: max 32 nodes, acyclic. Violations emit `NOP-TASK-DAG-TOO-LARGE` / `NOP-TASK-DAG-CYCLE`. Delegation-chain depth not enforced (kit has no sub-worker delegation path; every worker is one hop from Dispatcher).

### 7.2 What the kit defers

- **`nwp://` transport (NPS-2 NWP):** kit uses filesystem mailboxes. Network transport is future work.
- **AlignStream backpressure (NPS-5 §3.4):** workers emit single final result, not streamed intermediates.
- **Resource preflight (NPS-5 §4):** no worker-availability probe before DAG commit.
- **NDP discovery (NPS-4):** worker NIDs hardcoded in config; no `AnnounceFrame` / `ResolveFrame`.
- **NIP signature enforcement on delegation:** delegation validation is at application level, not cryptographic.
- **Anchors for token savings (NPS-1 AnchorFrame):** not used in v1.
- **K-of-N SyncFrame semantics (NPS-5 §3.3):** kit uses all-or-nothing merge-hold in v1. `aggregate: "fastest_k" | "first"` deferred.

### 7.3 Kit-specific additions (not in NPS)

- **Versioned task-lists** (`v1.json`, `v2.json` on re-decompose): NOP has no re-decomposition semantics.
- **Pending-ack filesystem flow** (`pending/v{N}.json` → rename on OSer ack): human-in-loop is not a first-class NOP concept.
- **Supersede branch/worktree lifecycle:** NOP has `DelegateFrame action="cancel"` but no branch-rename convention.
- **Escalation log (JSONL):** kit operational layer.
- **`cmd_ack` CLI:** ergonomic wrapper for the pending-ack rename.
- **`success_criteria` field on DAG nodes:** machine-checkable DoD beyond NOP.

### 7.4 Why deviate on transport

Filesystem mailboxes simplify the single-host demo: no network infra, no discovery, no TLS, no daemon. Artifacts are human-inspectable, hand-editable, auditable. The tradeoff is no remote dispatch; when that matters, layer `nwp://` on top of the same artifact structure.

---

## 8. Extensibility

New layers can be inserted between existing layers by reading one artifact and producing another. Examples of layers adopters may add without kit changes:

- **Risk review** between Decompose and Dispatch: reads `pending/v{N}.json`, writes `approved/v{N}.json`, Dispatcher reads approved.
- **Context enrichment** between Plan and Decompose: reads `plan.md`, writes `enriched-plan.md`.
- **Multi-plan coordinator** above Plan: manages dependencies across plans.
- **Test/validation** between worker completion and merge-hold: reads `result.json`, writes `validation.json`.
- **Monitoring** layer: read-only on state + log, emits reports.

Layer replacement (e.g., changing the Dispatcher from one-shot to long-running daemon) is v2+ work. Additive composition is supported by default; replacement requires kit updates.

---

## 9. Relationship to other docs

- [`implementation-spec.md`](implementation-spec.md) — wire-format runbook (message shapes, state transitions, hook system)
- [`NPT.md`](NPT.md) — NPT token accounting details
- [NPS-Release/spec/protocols/](https://github.com/labacacia/NPS-Release/tree/main/spec/protocols) — canonical NPS spec

---

## 10. Change log

| Version | Date | Changes |
|---|---|---|
| 0.2.0-draft | 2026-04-24 | Initial architecture doc. Adds Plan/Decompose/Dispatch/Execute four-layer model, NOP TaskFrame-aligned task-list schema, versioned re-decomposition, escalation log, gate boundaries, NPS alignment notes. |
| 0.2.1-draft | 2026-04-24 | Cold-critic revisions: dropped `change_class_hint` dead field from v1 log schema (§4.4), added `decomposer_timeout_ms` config + NOP DAG limit enforcement (§5.2, §5.3), added flock concurrency guard on Dispatcher state-file access (§6.2), specified Dispatcher-side partial commit on supersede (§6.4), added pushback resumption ritual (§6.1), flagged trivial-decomposer + tightened-persona incompatibility (§5.4). Post-round-2: dropped delegation-depth check (misapplied — kit has no sub-worker delegation); renumbered §5.4/§5.5. Post-round-3: synced §6.4 with issue-04 (`--no-verify`, HEAD-state check, per-node event granularity); complex-HEAD workers route via existing `blocked` status instead of a new enum value. Post-round-4: gated `active_version` flip on full v_N drain — complex-HEAD `blocked` nodes prevent silent version advance past untriaged worktrees (§6.4 step 6). Post-round-5: supersede pass now iterates all v_N nodes (not just `running`); pushback-blocked workers (with result file) resolve as `pushback_superseded`, complex-HEAD-blocked gate drain correctly; renamed `NOP-SUPERSEDE-INCOMPLETE` to `KIT-SUPERSEDE-INCOMPLETE` (kit-specific, not NOP canon); added `supersede_resolved` event for OSer manual triage audit. Post-round-6: terminal v_N nodes archive via branch rename (event `supersede_archived`) — prevents `cmd_merge` picking up orphan v_N branches after version flip (§6.4 step 1). |
| 0.2.2-draft | 2026-04-24 | §4.5 plan_id optionality sync with #61 ruling A — TS snippet and prose updated to `plan_id?: string` (optional in v1, required post-#63). Closes #74. |
| 0.2.3-draft | 2026-04-24 | §4.6 added: four JSON Schema documents under `src/schemas/`, Python validator at `scripts/lib/validate_schema.py`, forward-reference to `cmd_decompose` validation hook (#66). Closes #62. |
| 0.2.4-draft | 2026-04-25 | `osi_ack_by` added to EscalationEvent TS type + schema (closes #80). Required field; emitted by cmd_ack (#67). |
