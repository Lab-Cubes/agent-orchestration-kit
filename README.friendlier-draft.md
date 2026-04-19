# agent-orchestration-kit

> We built this to run multi-agent work ourselves. It saves us tokens and
> makes orchestration tractable. Sharing it so others can too.

---

## What problem does this solve?

Running one AI agent on a big task works — until the task gets complex, the
context window balloons, and you're paying for the same background knowledge
on every turn.

**This kit lets you run multiple AI agents in parallel, each on its own git
worktree, with token budgets (NPT — NPS Token, a cross-runtime unit for
tracking spend) and a mailbox-based task flow.** Agents receive a task file,
do their work, and write a result. The orchestrator moves on without waiting
for slow work to finish.

The result: smaller contexts per agent, parallel execution, and a clear audit
trail of what each agent did and how much it cost.

---

## Why use this instead of just running Claude Code directly?

| Situation | Claude Code alone | This kit |
|---|---|---|
| One task, one agent | Great fit | Overkill |
| Many tasks, many agents in parallel | Manual, error-prone | Built-in dispatch |
| You need to cap token spend per task | No built-in mechanism | NPT budget per task |
| You want an audit trail of agent work | Conversation history only | JSON result files + git history |
| You need agents on different branches | Switch manually | Automatic git worktree per task |

If you're orchestrating more than one agent, or want cost visibility and
isolation, this kit is for you.

---

## Quick start — token-savings demo in 5 minutes

**Step 1 — Clone and enter the kit:**

```bash
git clone https://github.com/Lab-Cubes/agent-orchestration-kit.git
cd agent-orchestration-kit/kits/agents
```

You should see the `kits/agents/` directory with `bin/`, `agents/`, and
`hooks/` subdirectories.

**Step 2 — Run setup:**

```bash
./bin/setup
```

This installs Node dependencies and wires up the hook scripts. You should see
a confirmation line like `setup complete` with no errors.

**Step 3 — Run the demo:**

```bash
./bin/demo
```

The demo runs the same task two ways — naive prompt-embedded context vs NOP
(NPS Orchestration Protocol — the mailbox dispatch layer) — and shows real
token savings on your machine. You should see a NOP worker complete in ~30s
and a side-by-side NPT comparison printed to the terminal.

**What success looks like:** both runs finish, a result file appears in
`done/`, and the NPT summary shows the mailbox approach using fewer tokens.

---

## What's in the box

```
agent-orchestration-kit/
├── kits/              # Adopter kits (clone, set up, run)
│   └── agents/        # NOP multi-agent orchestration — mailbox + spawn + workers
└── plugins/           # Optional hook plugins for the kits
    ├── cost-monitor/  # Per-task NPT cost logging and reporting
    └── discord/       # Discord notifications for kits/agents
```

- **`kits/agents/`** is where you'll spend most of your time. It contains the
  dispatcher, worker templates, and bin scripts.
- **`plugins/`** are optional add-ons you bolt on with a single hook line.
  Start with `cost-monitor` if you want spend tracking; add `discord` if you
  want task notifications in a channel.

Every directory also has an `AGENTS.md` with exact install steps — useful if
you're having an AI agent set things up for you.

---

## Who is this for?

| You are… | Start here |
|---|---|
| An operator wanting multi-agent orchestration now | [`kits/agents`](./kits/agents) — clone, `./bin/setup`, run |
| A plugin author | [`plugins/cost-monitor`](./plugins/cost-monitor) (minimal: one hook, no credentials) or [`plugins/discord`](./plugins/discord) as templates; see [`kits/agents/hooks/README.md`](./kits/agents/hooks/README.md) for the contract |
| An AI agent scanning this repo for an operator | Every directory has an `AGENTS.md` with exact install steps |
| A developer needing NPS protocol SDKs | [labacacia/NPS-Release](https://github.com/labacacia/NPS-Release) — SDKs in 8 languages |

---

## Requirements

- Node.js ≥ 22
- pnpm ≥ 10
- git
- Python 3 (for JSON processing in shell scripts)
- An AI agent CLI — the reference implementation uses
  [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code); adopters
  can wrap any runtime's equivalent. No API keys managed by this kit — use
  your own runtime subscription.

---

## Status

v0.1.0. Agent orchestration kit + Discord + cost-monitor plugins. Tested
across 40+ real tasks in our own workflow before public release.

---

## License

Apache 2.0 — see [LICENSE](./LICENSE) and [NOTICE](./NOTICE). Copyright 2026
INNO LOTUS PTY LTD.

---

## For protocol nerds

If you want to understand the protocol layer underneath this kit, here's the
full picture. None of this is required reading to run the kit — it's here for
contributors and integrators.

NPS (NPS Protocol Suite) is five sub-protocols that compose. This kit covers
the orchestration layer (NOP):

| Protocol | Role | In this kit |
|---|---|---|
| **NCP** | Frame format (wire) | via `@labacacia/nps-sdk` |
| **NWP** | Web access | (future) |
| **NIP** | Identity + CA | via `@labacacia/nps-sdk` |
| **NDP** | Discovery | (future) |
| **NOP** | Orchestration | `kits/agents` (reference implementation) |

The protocol layer is language- and runtime-agnostic: any agent that can read
a file and write a result can implement it. This kit ships a reference
dispatcher written in bash + TypeScript that wraps the Claude Code CLI;
adopters can replace the wrapper with any AI agent runtime.

Protocol spec and language SDKs (TypeScript, Python, .NET, Java, Rust, Go and
more) live at [labacacia/NPS-Release](https://github.com/labacacia/NPS-Release).
This repo is the **application pattern layer** — clone it, set it up, run it.
