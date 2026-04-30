# agent-orchestration-kit

> We built this to run multi-agent work ourselves. It saves us tokens and
> makes orchestration tractable. Sharing it so others can too.

**Agent orchestration kit — NOP reference implementation for multi-agent task dispatch.** File-based mailbox protocol (JSON over the filesystem), git worktree isolation per task, hook-based extensibility. The protocol layer is language- and runtime-agnostic: any agent that can read a file and write a result can implement it. This kit ships a reference dispatcher written in bash + TypeScript that wraps the Claude Code CLI; adopters can replace the wrapper with any AI agent runtime.

For NPS protocol SDKs in TypeScript, Python, .NET, Java, Rust, Go and more, see [labacacia/NPS-Release](https://github.com/labacacia/NPS-Release). This repo is the **application pattern layer** — clone it, set it up, run it.

## What's in here

```
agent-orchestration-kit/
├── kits/              # Adopter kits (clone, set up, run)
│   └── agents/        # NOP multi-agent orchestration — mailbox + spawn + workers
└── plugins/           # Optional hook plugins for the kits
    ├── cost-monitor/  # Per-task NPT cost logging and reporting
    └── discord/       # Discord notifications for kits/agents
```

## Quick start — token-savings benchmark in 5 minutes

```bash
git clone https://github.com/Lab-Cubes/agent-orchestration-kit.git
cd agent-orchestration-kit/kits/agents && ./bin/setup && ./bin/benchmark
```

The benchmark runs the same task two ways — naive prompt-embedded context vs
NOP mailbox dispatch — and shows real NPT saved on your machine.

## Audiences

| You are… | Start here |
|---|---|
| An operator wanting multi-agent orchestration now | [`kits/agents`](./kits/agents) — clone, `./bin/setup`, run |
| A plugin author | [`plugins/cost-monitor`](./plugins/cost-monitor) (minimal: one hook, no credentials) or [`plugins/discord`](./plugins/discord) as templates; see [`kits/agents/hooks/README.md`](./kits/agents/hooks/README.md) for the contract |
| An AI agent scanning this repo for an operator | Every directory has an `AGENTS.md` with exact install steps |
| A developer needing NPS protocol SDKs | [labacacia/NPS-Release](https://github.com/labacacia/NPS-Release) — SDKs in 8 languages |

## The NPS protocol family

NPS is five sub-protocols that compose. This kit covers the orchestration layer (NOP):

| Protocol | Role | In this kit |
|---|---|---|
| **NCP** | Frame format (wire) | via `@labacacia/nps-sdk` |
| **NWP** | Web access | (future) |
| **NIP** | Identity + CA | via `@labacacia/nps-sdk` |
| **NDP** | Discovery | (future) |
| **NOP** | Orchestration | `kits/agents` (reference implementation) |

Protocol spec and language SDKs live at [labacacia/NPS-Release](https://github.com/labacacia/NPS-Release). This kit is the adoption ramp.

## Requirements

- Node.js ≥ 22
- pnpm ≥ 10
- git
- Python 3 (for JSON processing in shell scripts)
- bats (bats-core) — for running the test suite. Install: `brew install bats-core` (macOS) / `apt install bats` (Linux) / see https://bats-core.readthedocs.io
- An AI agent CLI — the reference implementation uses [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code); adopters can wrap any runtime's equivalent. No API keys managed by this kit — use your own runtime subscription.
- Claude Code CLI version — must support `--setting-sources` (recent builds). Verify: `claude --help | grep setting-sources`. Upgrade: `npm i -g @anthropic-ai/claude-code`.

## Status

v0.1.0. Agent orchestration kit + Discord + cost-monitor plugins. Tested
across 40+ real tasks in our own workflow before public release.

## License

Apache 2.0 — see [LICENSE](./LICENSE) and [NOTICE](./NOTICE). Copyright 2026
INNO LOTUS PTY LTD.
