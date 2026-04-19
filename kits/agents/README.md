# @nps-kit/agents — NOP Orchestration, Clone and Run

> We use this to dispatch coder/critic/researcher agents every day. It saves
> us tokens and makes multi-agent work tractable. Try it.

**What it is:** a reference implementation of [NPS-5 NOP](https://github.com/labacacia/NPS-Release)
that wraps an AI agent runtime as a mailbox-based worker. One orchestrator,
many workers, file-based task dispatch, git worktree isolation per task.
The reference dispatcher invokes the `claude` CLI; to port to another runtime,
see [§11 of the implementation spec](./docs/implementation-spec.md#11-runtime-specific-touchpoints).

**Why use it:**
- **Token savings.** Workers read context from their local scope. Orchestrators
  don't have to stuff the whole context into a prompt — they write a small intent
  message. See `bin/demo` for a live NPT comparison on your machine.
- **Runtime-agnostic protocol.** The mailbox protocol works with any agent runtime
  that can read a file and write a result. This kit ships a reference wrapper for
  Claude Code CLI; the same pattern wraps any other runtime.
- **Git worktree isolation.** Each task runs on its own branch in a dedicated
  worktree. Parallel workers don't conflict. Squash-merge when the work is good.
- **Hook-based extensibility.** Notifications, metrics, custom behaviour plug
  in via `hooks/on-task-*.sh` — no core changes.

## Quick start

```bash
git clone https://github.com/Lab-Cubes/agent-orchestration-kit.git
cd agent-orchestration-kit/kits/agents
./bin/setup
./bin/demo
```

That's it. `bin/setup` creates your runtime directories and three default
workers. `bin/demo` runs a canonical task two ways (naive vs NOP) and shows
NPT saved on your machine.

**Prerequisites:** Node 22+, pnpm 10+, git, Python 3 (for JSON processing in shell),
and an AI agent CLI. The reference implementation uses
[Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code);
adopters can replace the wrapper with any runtime's equivalent.

## How it works

```
Orchestrator (you, or your own agent)
    │
    ├─ write intent.json ──→ inbox/
    │                         │
    │                         ├─ mv ──→ active/   (worker claims)
    │                         │           │
    │                         │           ├─ execute (agent runtime runs)
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

- `.env` — override runtime paths if you want a custom layout
  (`NPS_AGENTS_HOME`, `NPS_WORKTREES_HOME`, `NPS_LOGS_HOME`)
- `config.json` — issuer domain, default model, NPT budgets, time limits

Both copied from `.env.example` / `config.example.json` on first setup.

### Where runtime state lives

By default, your workers' mailboxes, worktrees, and logs live under
**`$HOME/.nps-kit/`**, not inside the cloned kit. This keeps the kit repo
code-only and stops a worker's `git commit` from accidentally landing on
a kit branch.

```
$HOME/.nps-kit/
├── agents/       # worker mailboxes (inbox/, active/, done/, blocked/)
├── worktrees/    # per-task git worktrees
└── logs/         # dispatch-costs.csv, hooks.log
```

**Path resolution** (highest priority first):

1. `NPS_AGENTS_HOME` / `NPS_WORKTREES_HOME` / `NPS_LOGS_HOME` — per-dir overrides
2. `NPS_STATE_HOME` — one root for all three (`$NPS_STATE_HOME/{agents,worktrees,logs}`)
3. `XDG_STATE_HOME` — Linux XDG convention (`$XDG_STATE_HOME/nps-kit/...`)
4. Fallback — `$HOME/.nps-kit/...`

If you prefer everything inside the kit (per-clone isolation), set
`NPS_STATE_HOME="$NPS_DIR"` — or override each path individually.

### Platforms

Runs on **macOS**, **Linux**, and **Windows** (via Git Bash, WSL, MSYS2,
or Cygwin). The kit is bash scripts; native Windows PowerShell / cmd
can't run them. Linux users with `XDG_STATE_HOME` set get the XDG-
compliant location automatically.

## Notifications (plugins)

Core kit is notification-free. Install an optional plugin for Discord, Slack,
custom webhooks — see `../../plugins/` at the repo root.

Discord plugin: `cd ../../plugins/discord && ./install.sh`.

## Cost

Runs on your runtime subscription — no API keys managed by this kit.
NPT budgets cap per-task spend (NPS-0 §4.3 standardized unit, approximated as
input + output + cache_read tokens for v0.1.0; full NPS-0 §4.3 normalization
across model tiers arrives in v0.2.0).

## Status

v0.1.0. Proven in our own dev workflow across 40+ tasks (coder, critic,
researcher roles). First public release — adopter feedback welcome.

## License

Apache 2.0. Copyright 2026 INNO LOTUS PTY LTD.
