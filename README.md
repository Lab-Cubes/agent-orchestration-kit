# nps-kit

> We built this to run multi-agent work ourselves. It saves us tokens and
> makes orchestration tractable. Sharing it so others can too.

**Reference implementation and adoption kits for [NPS (Neural Protocol Suite)](https://github.com/labacacia/NPS-Release)** — the protocol that replaces HTTP/REST for AI agent communication. See the upstream repo for spec + language SDKs; this repo is the **kit** layer that turns the protocol into something you can clone and run.

## What's in here

```
nps-kit/
├── packages/          # Developer SDK (npm packages, TypeScript)
│   ├── codec/         # NPS wire codec (NCP + NIP + all sub-protocol frame types)
│   └── identity/      # NIP identity + DevCA (Ed25519 signing, dev-mode identity)
├── kits/              # Adopter kits (clone, set up, run)
│   └── agents/        # NOP multi-agent orchestration — mailbox + spawn + workers
└── plugins/           # Optional hook plugins for the kits
    ├── discord/       # Discord notifications for kits/agents
    └── cost-monitor/  # Per-task NPT/USD cost logging and reporting
```

## Quick start — token-savings demo in 5 minutes

```bash
git clone https://github.com/Lab-Cubes/nps-kit.git
cd nps-kit && pnpm install
cd kits/agents && ./bin/setup && ./bin/demo
```

The demo runs the same task two ways — naive prompt-embedded context vs NPS
NOP mailbox dispatch — and shows real NPT saved on your machine.

## Audiences

| You are… | Start here |
|---|---|
| A developer using NPS in your code | [`packages/codec`](./packages/codec) — wire codec — and [`packages/identity`](./packages/identity) — Ed25519 identity |
| An operator wanting multi-agent orchestration now | [`kits/agents`](./kits/agents) — clone, `./bin/setup`, run |
| An AI agent scanning this repo for an operator | Every directory has an `AGENTS.md` with exact install steps |
| A plugin author | [`plugins/cost-monitor`](./plugins/cost-monitor) (minimal: one hook, no credentials) or [`plugins/discord`](./plugins/discord) as templates; see [`kits/agents/hooks/README.md`](./kits/agents/hooks/README.md) for the contract |

## The NPS protocol family

NPS is five sub-protocols that compose. This kit covers the stack up to orchestration:

| Protocol | Role | In this kit |
|---|---|---|
| **NCP** | Frame format (wire) | `packages/codec` |
| **NWP** | Web access | (future) |
| **NIP** | Identity + CA | `packages/identity` (dev mode) |
| **NDP** | Discovery | (future) |
| **NOP** | Orchestration | `kits/agents` (reference implementation) |

Protocol spec lives at [labacacia/NPS-Release](https://github.com/labacacia/NPS-Release). Language SDKs in .NET, Python, TypeScript, Java, Rust, Go live alongside it. This kit is the adoption ramp.

## Requirements

- Node.js ≥ 22
- pnpm ≥ 10
- [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) (for `kits/agents` workers — uses your own Claude subscription, no API keys managed by this kit)
- Python 3 (for JSON processing in shell scripts)

## Status

v0.1.0. Wire codec + identity dev mode + agent orchestration kit + Discord
plugin. Dogfooded across 40+ real tasks in our own workflow before public
release.

## License

Apache 2.0 — see [LICENSE](./LICENSE) and [NOTICE](./NOTICE). Copyright 2026
INNO LOTUS PTY LTD.
