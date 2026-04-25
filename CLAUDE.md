# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```bash
# Root (pnpm workspaces)
pnpm build        # build all workspaces
pnpm test         # test all workspaces
pnpm typecheck    # typecheck all workspaces
pnpm clean        # clean all workspaces

# Kit setup and demo
kits/agents/bin/setup   # first-run: creates runtime dirs + default workers
kits/agents/bin/demo    # runs naive vs NOP path, reports NPT savings

# Worker lifecycle (spawn-agent.sh)
./scripts/spawn-agent.sh setup <id> <type>              # type: coder|critic|researcher
./scripts/spawn-agent.sh dispatch <id> "<intent>" [opts] # --budget N --scope PATH --category CAT
./scripts/spawn-agent.sh status <id>
./scripts/spawn-agent.sh merge <task-id>
./scripts/spawn-agent.sh clean <id>

# Integration tests (requires bats-core)
bats kits/agents/tests/

# TypeScript check (kit level)
cd kits/agents && npm run typecheck

# Plugins
plugins/discord/install.sh       # Discord notification hooks
plugins/cost-monitor/install.sh  # per-task NPT/USD logging
bin/report                       # cost report CLI (after cost-monitor install)
```

## Architecture

**What this is:** A reference implementation of NOP (Neural Orchestration Protocol, NPS-5) — a file-based mailbox protocol for multi-agent task dispatch. The protocol is runtime-agnostic; this kit wraps the Claude Code CLI as the agent runtime.

### Runtime state lives outside the repo

By design, all runtime state lands at `$NPS_STATE_HOME` (falls back to `$XDG_STATE_HOME/nps-kit`, then `$HOME/.nps-kit`), not inside the repo. This prevents worker commits from landing on kit branches. The kit's `kits/agents/.env` configures these paths; `kits/agents/config.json` holds the issuer domain, budgets, and model rates.

```
$HOME/.nps-kit/
├── agents/{worker-id}/
│   ├── inbox/      ← pending intents (PENDING)
│   ├── active/     ← claimed intents (RUNNING) — atomic mv from inbox/ is the claim lock
│   ├── done/       ← completed + result files (terminal)
│   ├── blocked/    ← blocked intents (awaiting external input)
│   ├── CLAUDE.md   ← worker bootstrap (identity + protocol)
│   └── .claude/settings.json
├── worktrees/{task-id}/   ← isolated git worktree per task
└── logs/dispatch-costs.csv
```

### Task lifecycle (state machine)

```
PENDING (inbox/{task-id}.intent.json)
  ↓ atomic mv (POSIX rename — first mover wins)
RUNNING (active/{task-id}.intent.json)
  ↓ execute in isolated worktree
COMPLETED | FAILED | TIMEOUT | BLOCKED (done/ or blocked/)
```

Each state transition is a filesystem rename. The worker always writes a result file — even on failure or timeout.

### NOP wire protocol

Two JSON schemas govern orchestrator↔worker communication (`src/nop-types.ts`):

- **`IntentMessage`** (`NcpVersion=1`, `type: "intent"`) — orchestrator writes to `inbox/`. Contains the task ID, worker NID (`urn:nps:agent:{domain}:{id}`), intent verb phrase, constraints (scope, budget, time limit, model), and context (files, knowledge, branch).
- **`ResultMessage`** (`type: "result"`) — worker writes to `done/`. Contains status, files changed, commits, follow-up tasks, `cost_npt`, and error if any.

File naming: `{payload.id}.intent.json` / `{payload.id}.result.json`.

### TypeScript layer (`src/`)

Intentionally minimal — types only + test utilities. No production business logic lives here.

| File | Purpose |
|---|---|
| `nop-types.ts` | NOP/NCP wire types, `buildNid()`, `NipError` — inlined from `@nps-kit/codec` + `@nps-kit/identity` |
| `types.ts` | Filesystem layer types: `TaskState`, `STATE_DIRECTORY` map, `MAILBOX_DEFAULTS` |
| `dispatch.ts` | Minimal orchestrator (writes intent to inbox) |
| `nop-agent.ts` | No-op test agent — used by BATS tests via mock Claude CLI |

### Worker identity (NPS-3 NIP)

NID format: `urn:nps:agent:{issuer_domain}:{agent_id}` — e.g. `urn:nps:agent:example.com:coder-01`.

Worker instances live under `kits/agents/agents/` as starter configs; the runtime copies these to `$NPS_STATE_HOME/agents/` on setup. Each worker has a `CLAUDE.md` bootstrapped from `templates/AGENT-CLAUDE.md` and a `templates/personas/{type}.md` overlay.

### Scope carving (NOP §3.2)

`constraints.scope` is always narrowing — workers read only what's listed, never expand. Orchestrators set scope; workers enforce it.

### Hook system (plugin extensibility)

Hooks fire after task state transitions. They are language-agnostic executables in `kits/agents/hooks/`. Hook failures are suppressed — they never block the worker.

Environment variables available to hooks: `NPS_TASK_ID`, `NPS_AGENT_ID`, `NPS_STATUS`, `NPS_COST_NPT`.

Plugins (`plugins/discord/`, `plugins/cost-monitor/`) symlink their hooks into the hooks directory via their `install.sh`.

### Token efficiency (the core value proposition)

Naive orchestration inlines full context into the prompt — every token counts against the budget. NOP separates the intent (~200 tokens) from the context (worker reads from scope on demand). `bin/demo` measures this delta on live hardware.
