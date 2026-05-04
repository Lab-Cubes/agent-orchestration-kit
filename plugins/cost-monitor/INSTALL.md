# INSTALL.md — Cost Monitor Plugin Install Spec

Install runbook for agent readers. Configures per-task cost logging and report
for the `@nps-kit/agents` kit. Every step exact.

## Prerequisites

- `@nps-kit/agents` already set up (`kits/agents/bin/setup` has been run)
- `dispatch-costs.csv` is being written by `kits/agents/scripts/spawn-agent.sh`
- No credentials required

## Install

```bash
cd plugins/cost-monitor
./install.sh
```

Expected last-line output:

```
[cost-monitor] Installed 1 hook into ../../kits/agents/hooks/
[cost-monitor] Run bin/report at any time to see a cost summary.
```

## Optional: override defaults

If CGN→USD rate or log path differs from the defaults:

```bash
cp config.example.json config.json
$EDITOR config.json
```

Fields:
- `cgn_usd_rate` — float, default `0.001` (1 CGN = $0.001 USD)
- `log_path` — absolute or relative path to `dispatch-costs.csv`; default is
  `../../nop/logs/dispatch-costs.csv` relative to the plugin directory

Skip this step if defaults are acceptable.

## Verify

```bash
ls ../../kits/agents/hooks/
```

Expected: `on-task-completed.sh` present and executable.

## Test hook

Dispatch a task and check that stderr contains a cost line:

```bash
cd ../../kits/agents
./scripts/spawn-agent.sh dispatch coder-01 "Echo test" --scope "$(pwd)" --max-turns 2 2>&1 | grep '\[cost\]'
```

Expected output (may appear after task completes):

```
[cost] coder-01 task-operator-YYYYMMDD-HHMMSS: 0.12 CGN (~$0.0001) · 42s · -
```

If nothing appears:
- Check that `kits/agents/hooks/on-task-completed.sh` is executable: `ls -la ../../kits/agents/hooks/`
- Check that spawn-agent.sh is capturing stderr: run with `2>&1`
- Note: hook output is suppressed by default in spawn-agent.sh (`> /dev/null 2>&1`); the line is visible when the hook is invoked directly

## Test report

```bash
bin/report
```

Expected: a cost summary table printed to stdout. If the CSV is empty or not found, adjust `log_path` in `config.json`.

## Uninstall

```bash
cd plugins/cost-monitor
./install.sh --uninstall
```

Or manually:

```bash
rm ../../kits/agents/hooks/on-task-completed.sh
```

Re-install by running `./install.sh` again.

## Failure modes

| Symptom | Likely cause | Action |
|---------|--------------|--------|
| No `[cost]` lines in output | Hook output suppressed by spawn-agent.sh | Invoke hook directly to test: `NPS_AGENT_ID=coder-01 NPS_TASK_ID=test NPS_COST_CGN=1 ./on-task-completed.sh` |
| `Error: log file not found` in report | Wrong CSV path | Set `log_path` in `config.json` |
| `~$0.0000` for all tasks | `cgn_usd_rate` not set | Check `config.json` or use `--rate` flag |
| duration/category shows `-` | result.json not found at expected path | Expected at `kits/agents/agents/{agent_id}/done/{task_id}.result.json` |

Hook failures never block worker lifecycle — the worker completes its task
even if the cost hook fails.
