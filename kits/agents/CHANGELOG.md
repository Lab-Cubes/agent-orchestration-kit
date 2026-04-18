# Changelog

## v0.1.0 — 2026-04-19

Initial public release.

### Added
- NOP worker lifecycle (setup, dispatch, status, clean, merge) via `scripts/spawn-agent.sh`
- 3 default worker personas: coder, critic, researcher
- Git worktree isolation per dispatched task
- CSV cost logging (13-col schema: timestamp, task_id, agent_id, model, category, priority, budget_npt, cost_npt, cost_usd_derived, turns, duration_s, denials, status)
- Hook contract for lifecycle events (task-claimed, task-completed, task-failed)
- Template-driven worker bootstrap via persona files

### Known approximations
- NPT cost is v0.1.0 approximation (input + output + cache_read tokens); full NPS-0 §4.3 normalization targets v0.2.0.
