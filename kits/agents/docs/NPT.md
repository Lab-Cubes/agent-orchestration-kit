<!-- SPDX-License-Identifier: Apache-2.0 -->

# NPT — Operator Guide

_Who this is for: you just ran a dispatch and saw "NPT" in the cost log. This page explains what it means and how to tune it._

---

## What is NPT?

NPT (NPS Token) is the cross-model standardized unit from NPS-0 §4.3. All four token channels reported by the runtime are counted:

```
NPT = ceil((input_tokens + output_tokens + cache_read_input_tokens + cache_creation_input_tokens) × rate)
```

`rate` is the model-family exchange rate from `config.json::npt_exchange_rates` (Claude family: 1.05). It tells you how much "thinking work" the worker did, normalized across model families.

You care about NPT because it's the number you use to set budgets, compare task costs, and decide when a task is getting too expensive.

---

## Why NPT instead of USD?

Token counts are exact — your runtime reports them directly. USD cost depends on which model, which API pricing tier, and which region you're on, and that math changes. NPT stays stable across all of those. Track NPT; convert to USD yourself if you need to, using current rates from your provider.

---

## Using --budget

Pass `--budget` to cap how many NPT a task may use:

```bash
./scripts/spawn-agent.sh dispatch \
  --agent coder-01 \
  --category code \
  --budget 5000 \
  "Add input validation to the login handler"
```

If you skip `--budget`, the dispatcher reads `category_budget_npt` from `config.json` and uses the value for that category (e.g. `"code": 40000`). The budget is a ceiling on the intent file — the worker sees it and should stop before exceeding it.

### USD-aware budgeting

If you want to reason about cost in USD rather than NPT, `config.json` exposes three knobs (full definitions in `config.example.json`):

| Key | What it does |
|-----|--------------|
| `model_rates.{sonnet\|haiku\|opus}.npt_usd` | USD cost per NPT for each model family — multiply by `cost_npt` for an approximate USD figure. |
| `category_usd_cap` | Per-category hard USD ceiling, checked alongside `category_budget_npt`; whichever is lower wins. |
| `nop_overhead_usd` | Fixed USD overhead per dispatch (infrastructure, API roundtrips) — added to the per-task estimate. |

NPT is still the primary budgeting unit; these knobs let you cross-check NPT ceilings against your actual spend targets without wiring the dispatcher directly to live pricing APIs.

**Example dispatch output:**
```
[nps] Creating worktree: .../kits/agents/worktrees/task-operator-20260419-142300 (branch: agent/coder-01/task-operator-20260419-142300)
[nps] Intent created: task-operator-20260419-142300
[nps] Launching worker: coder-01 (model: sonnet, budget: 5000 NPT, max-turns: 100)
[nps] Worker finished in 87s (cost: 3821 NPT, turns: 12, denials: 0)
```

---

## Reading the cost log

After each dispatch completes, a row is appended to `kits/agents/logs/dispatch-costs.csv`.

**CSV header:**
```
timestamp,task_id,agent_id,model,category,priority,budget_npt,cost_npt,turns,duration_s,denials,status,overshoot_ratio
```

Rows are written with every field wrapped in double quotes (e.g. `"5000"` not `5000`). The annotation below strips the quotes for readability.

**Sample row, annotated:**

```
2026-04-19T14:23:00.000Z,     ← when the task started (ISO-8601, UTC)
task-operator-20260419-142300,← task ID — matches the worktree and intent file
coder-01,                     ← which worker ran it
sonnet,                       ← model used
code,                         ← task category (maps to category_budget_npt)
normal,                       ← priority
5000,                         ← budget_npt — the ceiling you set
3821,                         ← cost_npt  ← THIS is what to watch
12,                           ← turns — how many back-and-forth rounds
87,                           ← duration_s — wall-clock seconds
0,                            ← denials — permission denials during run
success,                      ← status
0.7642                        ← overshoot_ratio = round(cost_npt / budget_npt, 4)
```

The column that matters most for tuning is **cost_npt** (column 8).

**Quick sum of cost_npt across all tasks:**

```bash
# bash
awk -F',' 'NR>1 {sum+=$8} END {print sum " NPT total"}' kits/agents/logs/dispatch-costs.csv
```

```python
# python
import csv
print(sum(int(r[7]) for r in csv.reader(open("kits/agents/logs/dispatch-costs.csv")) if r and r[0] != "timestamp"), "NPT total")
```

---

## Tuning category_budget_npt

Open `config.json` (copy from `config.example.json` if you haven't already):

```json
"category_budget_npt": {
  "code":     40000,
  "docs":     60000,
  "test":     30000,
  "research": 60000,
  "refactor": 60000,
  "ops":      40000
}
```

These defaults are calibrated for Sonnet on our workload. Your tasks will differ. The right method:

1. Run a few dispatches without changing anything.
2. Look at `cost_npt` in the CSV for each category.
3. If typical `cost_npt` is well under the budget, lower it — this gives workers a tighter ceiling and surfaces runaway tasks faster.
4. If tasks are hitting the budget and stopping early (status: `timeout` or incomplete), raise it.
5. Repeat. There's no formula — it's calibration against your actual patterns.

**Tip:** Sort the CSV by `cost_npt` descending to find your most expensive task types:

```bash
sort -t',' -k8 -rn kits/agents/logs/dispatch-costs.csv | head -10
```

---

## Glossary

One line each. Canonical definitions live in the [NPS-Release specs](https://github.com/labacacia/NPS-Release) — linked per entry.

| Acronym | What it means |
|---------|--------------|
| **NPT** | NPS Token — raw token count (input + output + cache_read + cache_creation) used by a worker, multiplied by a model-family exchange rate. [NPS-0 §4.3](https://github.com/labacacia/NPS-Release) |
| **NPS** | Neural Protocol Suite — the protocol family this kit implements. [NPS-0](https://github.com/labacacia/NPS-Release) |
| **NCP** | Neural Communication Protocol — AI-to-AI frame format, encoding, semantic compression. [NPS-1](https://github.com/labacacia/NPS-Release) |
| **NWP** | Neural Web Protocol — how AI agents access Web-like nodes. [NPS-2](https://github.com/labacacia/NPS-Release) |
| **NIP** | Neural Identity Protocol — how agents are credentialed and identified. [NPS-3](https://github.com/labacacia/NPS-Release) |
| **NID** | Neural Identity Descriptor — the `urn:nps:agent:{issuer}:{id}` string that names an agent. [NPS-3](https://github.com/labacacia/NPS-Release) |
| **NDP** | Neural Discovery Protocol — global discovery of nodes and agents. [NPS-4](https://github.com/labacacia/NPS-Release) |
| **NOP** | Neural Orchestration Protocol — how tasks are dispatched to workers and results returned. [NPS-5](https://github.com/labacacia/NPS-Release) |
