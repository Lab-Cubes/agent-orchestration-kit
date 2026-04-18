# @nps-kit/plugin-cost-monitor

Cost visibility plugin for [`@nps-kit/agents`](../../kits/agents/). Logs per-task
NPT/USD spend to stderr at completion, and provides a CLI report over the full
dispatch history.

Zero config — works with sensible defaults out of the box.

## Quick start

```bash
cd plugins/cost-monitor

# (Optional) override NPT→USD rate or log path:
# cp config.example.json config.json && $EDITOR config.json

./install.sh
```

Every completed task now emits a cost line to stderr. Run the report any time:

```bash
bin/report
```

## Hook output

When a task completes, `on-task-completed.sh` writes to stderr:

```
[cost] coder-01 task-sage-20260418-201245: 1.23 NPT (~$0.0012) · 136s · code
```

| Field | Source |
|-------|--------|
| `agent` | `$NPS_AGENT_ID` |
| `task_id` | `$NPS_TASK_ID` |
| `NPT` | `$NPS_COST_NPT` |
| `~$USD` | NPT × `npt_usd_rate` from config (default `0.001`) |
| `duration` | `result.json` payload (falls back to `-`) |
| `category` | `result.json` payload (falls back to `-`) |

## Report

```
bin/report [--log PATH] [--rate RATE]
```

Prints:

- All-time and today totals (tasks + USD + NPT)
- Cost by agent (all-time)
- Cost by category (all-time)
- Cost by agent (today)
- Top-5 most expensive tasks

```
────────────────────────────────────────────────────────────
  Cost Monitor Report — 2026-04-18
────────────────────────────────────────────────────────────
  All-time    79 tasks   $54.2381
  Today        2 tasks    $1.0024
  All-time  54238.1 NPT  (at $0.001/NPT)
  Today     1002.4 NPT

By agent (all-time)
────────────────────────────────────────────────────────────
  Agent                 Tasks    Cost USD    Avg/task
  ──────────────────────────────────────────────────
  coder-01                 28   $21.3410    $0.7622
  ...
```

## Config

```json
{
  "npt_usd_rate": 0.001,
  "log_path": "/custom/path/to/dispatch-costs.csv"
}
```

| Field | Default | Meaning |
|-------|---------|---------|
| `npt_usd_rate` | `0.001` | NPT→USD conversion rate for `~$USD` display |
| `log_path` | `../../nop/logs/dispatch-costs.csv` (relative to plugin dir) | Override CSV path |

Both fields are optional. No config file = defaults used silently.

## Install / uninstall

```bash
./install.sh             # copy on-task-completed.sh into kits/agents/hooks/
./install.sh --uninstall # remove it (config.json preserved)
```

## Writing your own plugin

See `plugins/discord/README.md` for the hook contract pattern.
The cost-monitor is a minimal example: one hook, one report script, no
external credentials required.

## License

Apache 2.0.
