# AGENTS.md

Guidance for Codex (Codex.ai/code) working in this repository.

## Read these first

Before authoring or briefing work in this kit, read the canonical kit docs in this order — they own the contracts that workers and the dispatcher implement:

- [`kits/agents/docs/architecture.md`](kits/agents/docs/architecture.md) — four-layer model (Plan → Decompose → Dispatch → Execute), task-list schema, gate boundaries, NPS alignment.
- [`kits/agents/docs/implementation-spec.md`](kits/agents/docs/implementation-spec.md) — wire-format runbook (intent + result schemas, state machine, hook contract, NPT formula, port-verification checklist).
- [`kits/agents/templates/AGENT-AGENTS.md`](kits/agents/templates/AGENT-AGENTS.md) — worker bootstrap; **Change Discipline** (surgical edits, simplicity bar, pushback over silent expansion) + **Debug Discipline** (3-failure / 15-min / repeat-question check-in triggers).
- [`kits/agents/templates/personas/{coder,critic,researcher}.md`](kits/agents/templates/personas) — per-role overlays with anti-drift triggers, epistemic tagging (`[VERIFIED]` / `[OBSERVED]` / `[INFERRED]` / `[INSUFFICIENT_EVIDENCE]`), and termination heuristics.
- [`kits/agents/docs/NPT.md`](kits/agents/docs/NPT.md) — NPT token accounting details.

Without these, briefs over-prescribe behaviour the worker bootstrap already owns.

## Commands

```bash
# Root (pnpm workspaces)
pnpm build        # build all workspaces
pnpm test         # test all workspaces
pnpm typecheck    # typecheck all workspaces
pnpm clean        # clean all workspaces

# Kit setup and demo
kits/agents/bin/setup    # first-run: runtime dirs + default workers (coder-01, critic-01, researcher-01)
kits/agents/bin/demo     # naive vs NOP token-savings demo

# Worker lifecycle (kits/agents/scripts/spawn-agent.sh)
./scripts/spawn-agent.sh setup <id> <type>                  # type: coder|critic|researcher
./scripts/spawn-agent.sh dispatch <id> "<intent>" [opts]    # --budget N --scope PATH --category CAT --model M
./scripts/spawn-agent.sh status <id>
./scripts/spawn-agent.sh merge <task-id>                    # squash-merge the worker's branch (merge-hold gated)
./scripts/spawn-agent.sh clean <id>

# Phased dispatch (post-#45) — task-lists from Decomposer, OSer-acked, dispatcher-driven
./scripts/spawn-agent.sh decompose <plan-id>                # invoke Decomposer (config.json::decomposer_cmd) → pending/v{N}.json
./scripts/spawn-agent.sh ack <plan-id> <version>            # OSer ack: rename pending/v{N}.json → v{N}.json
./scripts/spawn-agent.sh dispatch-tasklist <plan-id>        # consume acked task-list, spawn workers, track state
./scripts/spawn-agent.sh supersede-gc [--older-than N] [--plan-id ID]   # GC superseded worktrees

# Integration tests
bats kits/agents/tests/                  # requires bats-core (brew install bats-core)
cd kits/agents && npm run typecheck

# Plugins
plugins/discord/install.sh               # Discord notification hooks
plugins/cost-monitor/install.sh          # per-task NPT/USD logging
bin/report                               # cost report CLI (after cost-monitor install)
```

## Architecture

**What this is:** Reference implementation of NPS (Neural Protocol Suite), centred on **NOP (NPS-5, Neural Orchestration Protocol)** — a file-based mailbox protocol for multi-agent task dispatch. The protocol is runtime-agnostic; this kit wraps the Codex CLI as the agent runtime.

### Four-layer model (post-#45)

```
Plan         ← human + OSer authors plan.md (intent, scope, success criteria)
  ↓ OSer ack
Decompose    ← Decomposer (config-pluggable, LLM or trivial) emits pending/v{N}.json
  ↓ OSer ack via cmd_ack (rename pending/v{N}.json → v{N}.json)
Dispatch     ← Dispatcher (programmatic, no LLM) consumes acked task-list,
               spawns workers, tracks state, holds merges until graph is green
  ↓ per-task intent
Execute      ← Workers in isolated worktrees, narrow intent, single-shot
```

Each layer reads one filesystem artifact and produces another, so adopters can insert layers (risk review, context enrichment, validation) without modifying kit code. See [`docs/architecture.md`](kits/agents/docs/architecture.md) §2 for the gate boundaries and verification responsibilities.

The **Decomposer interface** is mandated; its implementation is not. The kit ships [`scripts/lib/decomposers/trivial.py`](kits/agents/scripts/lib/decomposers/trivial.py) (one task per plan, broad scope) for the demo. Adopters override via `config.json::decomposer_cmd`. Trivial is **first-emission only** — exits 2 on any pushback context, escalating to OSer (per #115).

### Runtime state lives outside the repo

By design, all runtime state lands at `$NPS_STATE_HOME` (falls back to `$XDG_STATE_HOME/nps-kit`, then `$HOME/.nps-kit`), not inside the repo. This prevents worker commits from landing on kit branches. `kits/agents/.env` configures these paths; `kits/agents/config.json` holds issuer domain, budgets, model rates, decomposer command, soft-cap ratio, shutdown grace.

```
$NPS_STATE_HOME/
├── plans/{plan-id}/
│   └── plan.md                                        # OSer-authored, YAML frontmatter + body
├── task-lists/{plan-id}/
│   ├── pending/v{N}.json                              # Decomposer output, awaiting OSer ack
│   ├── v{N}.json                                      # acked, Dispatcher input
│   ├── task-list-state.json                           # graph-level execution state
│   └── escalation.jsonl                               # append-only events, schema_version 1
├── agents/{worker-id}/
│   ├── inbox/                                         # pending intents (PENDING)
│   ├── active/                                        # claimed intents (RUNNING) — atomic mv from inbox/ is the claim lock
│   ├── done/                                          # completed + result files (terminal)
│   ├── blocked/                                       # blocked intents (awaiting external input)
│   ├── AGENTS.md                                      # worker bootstrap (identity + protocol)
│   └── .Codex/settings.json
├── worktrees/
│   ├── {task-id}/                                     # active per-task worktree
│   └── superseded/{plan-id}/v{N}/{agent-id}/{task-id}/   # archived on re-decompose
└── logs/
    └── dispatch-costs.csv
```

### Task lifecycle (state machine)

```
PENDING (inbox/{task-id}.intent.json)
  ↓ atomic mv (POSIX rename — first mover wins)
RUNNING (active/{task-id}.intent.json)
  ↓ execute in isolated worktree
COMPLETED | FAILED | TIMEOUT | BLOCKED (done/ or blocked/)
```

Every state transition is a filesystem rename. The worker always writes a result file — even on failure or timeout.

### NOP wire protocol

Two JSON schemas govern orchestrator↔worker communication ([`kits/agents/src/nop-types.ts`](kits/agents/src/nop-types.ts)):

- **`IntentMessage`** (`_ncp: 1`, `type: "intent"`) — orchestrator writes to `inbox/`. Carries task ID, worker NID (`urn:nps:agent:{domain}:{id}`), intent verb, constraints (scope, budget, time limit, model), context (files, knowledge, branch), and optional `plan_id` (post-#74 — required once Dispatcher is the only emitter).
- **`ResultMessage`** (`type: "result"`) — worker writes to `done/`. Carries status, files changed, commits, follow-up tasks, `cost_npt`, error if any, and `pushback_reason` for `BLOCKED` results.

File naming: `{payload.id}.intent.json` / `{payload.id}.result.json`.

JSON Schema documents (draft-2020-12) for the phased-dispatch artifacts live at `kits/agents/src/schemas/*.schema.json` (`task-list`, `task-list-state`, `escalation-event`, `plan-frontmatter`). [`scripts/lib/validate_schema.py`](kits/agents/scripts/lib/validate_schema.py) invokes them; `cmd_decompose` rejects schema-violating Decomposer output as a `decomposer_failed/schema_violation` escalation event.

### TypeScript layer (`kits/agents/src/`)

Intentionally minimal — types only + test utilities. No production business logic lives here.

| File | Purpose |
|---|---|
| `nop-types.ts` | NOP/NCP wire types, `buildNid()`, `NipError` — inlined from `@nps-kit/codec` + `@nps-kit/identity` |
| `types.ts` | Filesystem layer types: `TaskState`, `STATE_DIRECTORY` map, `MAILBOX_DEFAULTS` |
| `dispatch.ts` | Minimal orchestrator (writes intent to inbox) |
| `nop-agent.ts` | No-op test agent — used by BATS tests via mock Codex CLI |
| `schemas/*.schema.json` | JSON Schema documents for the phased-dispatch artifacts |

### Worker disciplines (post-#69 + #101 + #108/#112/#113/#114/#107 + #115)

Workers inherit [`templates/AGENT-AGENTS.md`](kits/agents/templates/AGENT-AGENTS.md) plus a per-role persona overlay. The disciplines tighten what workers will do under runtime pressure:

- **Change Discipline** (#69) — surgical changes, simplicity bar, pushback over silent expansion. Workers MUST NOT refactor adjacent code, add abstractions, or expand scope to make a task tractable.
- **Debug Discipline** (#101) — three mandatory surface triggers. At any of: 3+ failing tests on the same area / 15 minutes without a progress signal / same question investigated twice — the worker writes a status (assertion text + hypothesis) and PAUSES until the OSer acknowledges.
- **Anti-drift triggers** (#108) — exceeding the role-specific exploration baseline returns `BLOCKED` with `pushback_reason: "intent under-specified, drifted into research mode"`. Coders stop at scope files + tests; critics at the diff + one level of dependents; researchers at sources directly named in `context.files` and `context.knowledge`.
- **Epistemic tagging** (#112/#113/#114) — claims tagged `[VERIFIED]` (ran a check), `[OBSERVED]` (read but not executed), `[INFERRED]` (pattern-matched), `[INSUFFICIENT_EVIDENCE]` (not determinable). Silent omission reads as approval-by-absence.
- **Researcher termination** (#107) — explicit stop conditions (~8 sources / 15 tool calls) plus diminishing-returns trigger (3 calls without new info materially changing findings).
- **Trivial decomposer pushback refusal** (#115) — the bundled `trivial.py` refuses any non-null `prior_version` or `pushback`, escalating to OSer; sophisticated decomposers handle pushback themselves.

### Worker identity (NPS-3 NIP)

NID format: `urn:nps:agent:{issuer_domain}:{agent_id}` — e.g. `urn:nps:agent:example.com:coder-01`. Default issuer domain is `dev.localhost`; override via `config.json::issuer_domain`.

Worker instances live under `kits/agents/agents/` as starter configs; the runtime copies these to `$NPS_STATE_HOME/agents/` on `setup`. Each worker gets a `AGENTS.md` bootstrapped from `templates/AGENT-AGENTS.md` plus the matching `templates/personas/{type}.md` overlay.

### Scope carving (NOP §3.2)

`constraints.scope` is always narrowing — workers read only what's listed, never expand. Orchestrators set scope; workers enforce it. Scope-violation responses use `NOP-DELEGATE-SCOPE-VIOLATION`.

### Hook system (plugin extensibility)

Hooks fire after task state transitions. They are language-agnostic executables in `kits/agents/hooks/`. Hook failures are suppressed — they never block the worker.

Environment variables passed to every hook: `NPS_TASK_ID`, `NPS_AGENT_ID`, `NPS_STATUS`, `NPS_COST_NPT`, `NPS_EVENT`.

Plugins (`plugins/discord/`, `plugins/cost-monitor/`) symlink their hooks into the hooks directory via their `install.sh`.

### Token efficiency (the core value proposition)

Naive orchestration inlines full context into the prompt — every token counts against the budget. NOP separates the intent (~200 tokens) from the context (worker reads from scope on demand). `bin/demo` measures this delta on live hardware (~83% NPT savings on the typical 3-sentence describe-this-kit task).

## NPS spec source of truth

Protocol specs and language SDKs live at [labacacia/NPS-Release](https://github.com/labacacia/NPS-Release). Always consult `spec/NPS-{0..5}-*.md` there before inventing wire schemas in this kit; document any deviations in [`docs/architecture.md`](kits/agents/docs/architecture.md) §7.
