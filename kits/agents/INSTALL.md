# INSTALL.md — Install Spec for Agent Readers

This document is the install runbook for AI agents scanning the repo on behalf
of a non-technical operator. Every step is exact. No prose.

## Prerequisites (check before proceeding)

```bash
node --version     # must be >= 22
pnpm --version     # must be >= 10
claude --version   # Claude Code CLI must be installed
python3 --version  # must be >= 3.8
git --version      # any recent version
```

If any fails:
- Node: install via nvm or brew (`brew install node@22`)
- pnpm: `npm install -g pnpm@10`
- Claude Code: https://docs.anthropic.com/en/docs/claude-code
- Python 3: usually pre-installed on macOS/Linux
- Git: `brew install git` or system package manager

## Install

From the repo root:

```bash
cd kits/agents
./bin/setup
```

Expected output (last line):

```
[setup] Install mark written to .nps-installed
```

If this fails, stop and report the error to the operator. Do not proceed.

## Verify

```bash
ls agents/
```

Expected: three directories — `coder-01`, `critic-01`, `researcher-01`.

```bash
./scripts/spawn-agent.sh status coder-01
```

Expected output contains: `=== Worker: coder-01 ===` followed by `inbox:`,
`active:`, `done:`, `blocked:` sections (all empty on a fresh install).

## Run the token-savings benchmark

```bash
./bin/benchmark
```

Expected behaviour:
1. Prints a header `NPS NOP — Token-Savings Demonstration`
2. Runs Path 1 (naive) — takes ~30s, reports NPT + USD
3. Runs Path 2 (NOP dispatch via researcher-01) — takes ~60s, reports NPT
4. Prints comparison table with savings percentage

Success criteria: Path 2 NPT < Path 1 NPT by >=50%.

Typical result on a fresh clone: Path 1 ~7,000 NPT, Path 2 ~1,200 NPT, savings ~83%.

## Dispatch a real task

```bash
./scripts/spawn-agent.sh dispatch coder-01 "Describe what this kit does in exactly 3 sentences" \
    --scope "$(pwd)" \
    --category docs \
    --model sonnet
```

Expected: worker writes `agents/coder-01/done/task-*.result.json` within ~90s.

Inspect result:

```bash
./scripts/spawn-agent.sh status coder-01
```

Expected output's "Latest result:" section shows:
- Task: `task-operator-{timestamp}`
- Status: `completed`
- Duration: number of seconds
- Cost NPT: integer
- Summary: the worker's 3-sentence description

## Configuration

Edit these files only if the operator requests changes:

- `.env` — runtime paths. Defaults work for single-machine use.
- `config.json` — issuer domain, default model, NPT budgets. The `issuer_domain`
  defaults to `dev.localhost`; change it to your org's domain when deploying
  beyond dev experimentation.

## Failure modes

| Symptom | Likely cause | Action |
|---------|--------------|--------|
| `./bin/setup` says "claude: command not found" | Claude Code CLI not installed | Point operator to install docs |
| `./bin/benchmark` hangs past 3 minutes | Claude API overloaded or network issue | Interrupt (Ctrl-C), retry after 2 min |
| `spawn-agent.sh dispatch` fails with "Worker not set up" | Setup never ran | Run `./bin/setup` |
| `result.json` never appears in `done/` | Worker hit budget limit or error | Check `done/*.raw-output.json` for the last Claude response |
| Hook script error (`[nps] hook ... exited non-zero`) | Broken hook in `hooks/` | Delete or fix the hook — never blocks the worker |

## Uninstall

```bash
rm -rf agents/ worktrees/ logs/ .env config.json .nps-installed
```

Leaves the kit intact; removes only operator-specific state.

## Version

This install spec targets `@nps-kit/agents@0.1.0`. Check `package.json` for the
current version. Breaking changes will be listed in `CHANGELOG.md`.
