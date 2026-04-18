# @nps-kit/agents — NOP Orchestration, Clone and Run

> We use this to dispatch coder/critic/researcher agents to Claude Code every
> day. It saves us tokens and makes multi-agent work tractable. Try it.

**What it is:** a reference implementation of [NPS-5 NOP](https://github.com/labacacia/NPS-Release)
that wraps any Claude Code instance as a mailbox-based worker. One orchestrator,
many workers, file-based task dispatch, git worktree isolation per task.

**Why use it:**
- **Token savings.** Workers read context from their local scope. Orchestrators
  don't have to stuff the whole context into a prompt — they write a small intent
  message. See `bin/demo` for a live NPT comparison on your machine.
- **Runtime-agnostic.** The mailbox protocol works with any agent runtime that
  can read a file and write a result. This kit ships a Claude Code wrapper;
  the same pattern wraps OpenClaw, LangChain, CrewAI, or your own runtime.
- **Git worktree isolation.** Each task runs on its own branch in a dedicated
  worktree. Parallel workers don't conflict. Squash-merge when the work is good.
- **Hook-based extensibility.** Notifications, metrics, custom behaviour plug
  in via `hooks/on-task-*.sh` — no core changes.

## Quick start

```bash
git clone https://github.com/Lab-Cubes/nps-kit.git
cd nps-kit/kits/agents
./bin/setup
./bin/demo
```

That's it. `bin/setup` creates your runtime directories and three default
workers. `bin/demo` runs a canonical task two ways (naive vs NOP) and shows
NPT saved on your machine.

**Prerequisites:** Node 22+, pnpm 10+, [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code),
Python 3 (for JSON processing in shell).

## How it works

```
Orchestrator (you, or your own agent)
    │
    ├─ write intent.json ──→ inbox/
    │                         │
    │                         ├─ mv ──→ active/   (worker claims)
    │                         │           │
    │                         │           ├─ execute (Claude Code runs)
    │                         │           │
    │                         ├─ mv ──→ done/     (intent archived)
    │                         │           │
    │                  done/result.json ←┘         (worker reports)
    │
    └─ review + squash-merge worktree branch
```

The orchestrator writes a small intent message. The worker reads context from
its scope. Their conversation is the task intent + result, not the whole context.

## Usage

### Dispatch a task

```bash
./scripts/spawn-agent.sh dispatch coder-01 "Fix null check in auth.ts" \
    --scope /path/to/your/repo \
    --category code \
    --budget 30000   # NPT
```

Auto-creates a git worktree on branch `agent/coder-01/task-…`. Worker operates
there. You review + merge when done.

### Inspect a worker

```bash
./scripts/spawn-agent.sh status coder-01
```

### Merge a completed task

```bash
./scripts/spawn-agent.sh merge task-operator-20260418-143022
```

### Add a new worker type

Create `templates/personas/{type}.md` following the pattern of `coder.md`,
`critic.md`, `researcher.md`. Then `./scripts/spawn-agent.sh setup my-agent {type}`.

## Configuration

- `.env` — paths (`NPS_AGENTS_HOME`, `NPS_WORKTREES_HOME`, `NPS_LOGS_HOME`)
- `config.json` — issuer domain, default model, NPT budgets, time limits

Both copied from `.env.example` / `config.example.json` on first setup.
Defaults work out of the box for single-machine use.

## Notifications (plugins)

Core kit is notification-free. Install an optional plugin for Discord, Slack,
custom webhooks — see `../../plugins/` at the repo root.

Discord plugin: `cd ../../plugins/discord && ./install.sh`.

## Cost

Runs on your Claude Code subscription — no API keys managed by this kit.
NPT budgets cap per-task spend (NPS-0 §4.3 standardized unit, approximated as
input + output + cache_read tokens for v0.1.0; full NPS-0 §4.3 normalization
across model tiers arrives in v0.2.0).

## Status

v0.1.0. Proven in our own dev workflow across 40+ tasks (coder, critic,
researcher roles). First public release — adopter feedback welcome.

## License

Apache 2.0. Copyright 2026 INNO LOTUS PTY LTD.
