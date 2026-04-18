# Hook Contract

Hooks are optional post-event scripts the kit runs at lifecycle transitions.
They let you plug notifications, metrics, or custom behaviour into the kit
**without modifying the core**.

## How it works

After a lifecycle event, `scripts/spawn-agent.sh` checks this directory for a
corresponding hook script. If the script exists and is executable, it runs with:

- **Environment variables:**
  - `NPS_TASK_ID` — the full task identifier
  - `NPS_AGENT_ID` — the worker handling the task
  - `NPS_STATUS` — the current lifecycle status (`pending`, `completed`, `failed`)
  - `NPS_COST_NPT` — NPT consumed by the task (0 for pre-completion events)
  - `NPS_EVENT` — the event name (`task-claimed`, `task-completed`, `task-failed`)
- **Stdin:** currently empty; reserved for future task-JSON streaming

Hook output is suppressed (logged as a warning on non-zero exit) so a broken
hook never blocks the worker's lifecycle. The kit keeps working if you remove,
rename, or break a hook.

## Event list

| Event | Trigger | When it fires |
|-------|---------|---------------|
| `task-claimed` | A new intent lands in `inbox/` via `spawn-agent.sh dispatch` | Before the worker process launches |
| `task-completed` | Worker finishes successfully | After `result.json` is written, before logging |
| `task-failed` | Worker errors or times out | After fallback result is generated |

## Contract

Each hook is a single executable file named `on-<event>.sh` (or `.py`, `.js` —
anything with a shebang and the executable bit). Language-agnostic by design.

**Example — `on-task-completed.sh`:**

```bash
#!/usr/bin/env bash
# Log every completion to a local file
echo "[$(date +%Y-%m-%dT%H:%M:%S)] $NPS_AGENT_ID completed $NPS_TASK_ID — ${NPS_COST_NPT} NPT" \
  >> "$HOME/.nps-agents.log"
```

Install:

```bash
chmod +x hooks/on-task-completed.sh
```

## Writing your own

1. Create the script in this directory (or install a plugin — see `plugins/` at the repo root).
2. Make it executable.
3. The hook fires on the next matching event — no restart needed.

Uninstall:

```bash
rm hooks/on-task-completed.sh
```

## Plugins

`plugins/` at the repo root contains open-source hook collections you can install
into this directory. See `plugins/discord/` for a Discord notification plugin as
a worked example, and a template for writing your own (Slack, webhooks, metrics,
anything).

Plugin install scripts copy (or symlink) their hook files into this directory.
Nothing fancier — the kit stays trivial to reason about.
