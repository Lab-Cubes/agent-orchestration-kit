# Orch-kit Patterns

Practical notes for recurring implementation and test shapes in the agents kit.
These documents sit below the canonical architecture and implementation specs:
use them when you need the local conventions behind a test fixture, dispatcher
edge case, or worker-result path.

## Current patterns

- [`bats-fixtures.md`](bats-fixtures.md) - isolated Bats kit trees, mock worker
  modes, scope fixture choices, and worker-written result simulation.
- [`status-translation.md`](status-translation.md) - how runtime output,
  fallback result files, worker-written results, scope validation, and
  task-list node outcomes map onto each other.

## Planned patterns

- Decomposer fixtures and semantic validation failures.
- Worktree branch lifecycle and merge-hold verification.
- Scope carving and read-only context handling.
- Hook fixtures and cost-log assertions.
- Worker pushback and re-decompose recovery.
