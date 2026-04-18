# Changelog

All notable changes to `@nps-kit/agents` are documented here.

---

## [Unreleased] — v0.2.0-planned

### Removed

- `packages/codec` — removed. NCP wire codec is now available via
  `@labacacia/nps-sdk`, which ships equivalent functionality in TypeScript,
  Python, .NET, Java, Rust, Go and more. See
  [labacacia/NPS-Release](https://github.com/labacacia/NPS-Release).
- `packages/identity` — removed. NIP identity + DevCA is likewise available
  via `@labacacia/nps-sdk`.

The kit is now atomic at the application layer: mailbox protocol, dispatcher,
worker templates, hooks. No in-repo SDK packages — use the upstream SDKs if
you need programmatic NPS frame construction.

### Changed

- Docs reframed: kit positioned as agent orchestration kit (language-agnostic
  at the protocol layer). Reference dispatcher wraps Claude Code CLI; adopters
  can replace with any AI agent runtime. See §11 of
  `docs/implementation-spec.md` for porting guidance.
- NPT approximation formula (§8) updated to be runtime-agnostic.
- Added §11 Runtime-specific touchpoints to `docs/implementation-spec.md`.

---

## [0.1.0] — 2026-04-19

Initial public release.

### Added

- NOP mailbox protocol (intent → active → done state machine)
- `scripts/spawn-agent.sh` dispatcher — setup, dispatch, status, clean, merge
  subcommands; git worktree isolation per dispatched task
- 3 default worker personas: coder, critic, researcher
- Template-driven worker bootstrap via persona files
- Hook contract for lifecycle events (`on-task-claimed`, `on-task-completed`,
  `on-task-failed`)
- CSV cost logging (13-col schema: timestamp, task_id, agent_id, model,
  category, priority, budget_npt, cost_npt, cost_usd_derived, turns,
  duration_s, denials, status)
- Discord plugin (`plugins/discord`)
- Cost-monitor plugin (`plugins/cost-monitor`)
- `bin/demo` — live NPT comparison (naive prompt vs NOP dispatch)
- Tested across 40+ real tasks before release

### Known approximations

- NPT cost is v0.1.0 approximation (`input + output + cache_read` tokens);
  full NPS-0 §4.3 normalization targets v0.2.0.
