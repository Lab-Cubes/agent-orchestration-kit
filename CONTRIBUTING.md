# Contributing to agent-orchestration-kit

This is a small OSS project. The goal of this guide is to make contributing straightforward — not to simulate enterprise process.

## Scope

This repo is the **agent orchestration kit**: the NOP reference implementation for multi-agent task dispatch. It includes the dispatcher, worker harness, plugin system, and spec documents.

Protocol SDKs (NPS-sdk-*) live at [labacacia/NPS-sdk-*](https://github.com/labacacia) — out of scope here.

## Getting started

```bash
git clone https://github.com/Lab-Cubes/agent-orchestration-kit.git
cd agent-orchestration-kit/kits/agents
./bin/setup
./bin/demo
```

## Making changes

**Branch naming:**
- `feat/<topic>` — new capability
- `fix/<topic>` — bug fix
- `docs/<topic>` — documentation only

**Commit discipline:**
- One logical change per commit (atomic commits)
- No backward-compat shims — make clean cuts
- No deprecation notices — if something's removed, remove it

**Commit message convention** ([Conventional Commits](https://www.conventionalcommits.org/)):

```
feat(agents): add priority-based inbox ordering
fix(discord): handle rate-limit retry on 429
docs(spec): clarify NPS-5 §3.2 scope carving
chore(pkg): update OSS metadata
```

## Before pushing

Run the secrets check locally — it's the same check CI runs:

```bash
./scripts/check-secrets.sh
```

The script blocks hardcoded personal home-directory paths (macOS, Linux, WSL) and common secret patterns (Anthropic, OpenAI, GitHub, AWS, Discord tokens). Exit 0 is clean; exit 1 lists violations with file and line.

## Running tests

```bash
# TypeScript type checking across all packages
pnpm -r typecheck

# Discord plugin integration tests (requires bats)
bats plugins/discord/tests/
```

If you're touching the dispatcher or worker harness, run both. If you're only touching docs or config, typecheck is sufficient.

## PR expectations

- Rebase on `main` before opening
- Atomic commits — squash "wip" commits before requesting review
- Describe the **why** in the PR description, not just the what
- Include a test plan checklist

CODEOWNERS auto-assigns reviewers. No need to tag anyone manually.

The default merge strategy is **rebase-and-merge** — keep the history clean.

## Review flow

1. Open PR against `main`
2. CODEOWNERS are auto-assigned
3. Address review feedback with new commits (don't force-push during review)
4. Maintainer rebases and merges

