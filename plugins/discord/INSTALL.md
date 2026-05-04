# INSTALL.md — Discord Plugin Install Spec

Install runbook for agent readers. Configures Discord notifications for the
`@nps-kit/agents` kit. Every step exact.

## Prerequisites

- `@nps-kit/agents` already set up (`kits/agents/bin/setup` has been run)
- A Discord channel where the operator wants notifications
- A Discord bot with `Send Messages` permission in that channel

## Operator inputs required

Before proceeding, ask the operator for:
1. **Channel ID** — right-click the target channel in Discord with Developer
   Mode enabled → Copy ID. Format: 18-digit integer.
2. **Bot token** — from https://discord.com/developers/applications →
   operator's bot → Bot tab → Reset Token. Format: long random string.

Store these securely. Do NOT log or echo them.

## Install

```bash
cd plugins/discord
cp config.example.json config.json
```

Edit `config.json`:
- Replace `"channel_id": ""` with the operator's channel ID
- In each `accounts` entry, replace `"token": ""` with a real Discord bot token
- Optionally edit `worker_map` to map NOP worker IDs to account names

```bash
./install.sh
```

Expected last-line output:

```
[discord-plugin] Installed 3 hooks into ../../kits/agents/hooks/
```

## Verify

```bash
ls ../../kits/agents/hooks/
```

Expected files: `README.md`, `on-task-claimed.sh`, `on-task-completed.sh`,
`on-task-failed.sh`. All three `.sh` files must be executable.

## Test

Dispatch a dry task:

```bash
cd ../../kits/agents
./scripts/spawn-agent.sh dispatch coder-01 "Echo test" --scope "$(pwd)" --max-turns 2
```

Expected Discord channel output (two messages within ~90s):

```
🔨 coder1 claimed task-operator-{timestamp}
✅ coder1 completed task-operator-{timestamp} (NNNN CGN)
```

If no messages appear:
- Check `config.json` — channel_id must be set and at least one account token must be non-empty
- Check bot has `Send Messages` in the channel
- Check `curl` is installed: `which curl`

## Uninstall

```bash
cd plugins/discord
./install.sh --uninstall
```

Or manually:

```bash
rm ../../kits/agents/hooks/on-task-claimed.sh
rm ../../kits/agents/hooks/on-task-completed.sh
rm ../../kits/agents/hooks/on-task-failed.sh
```

Reinstall by re-running `./install.sh`.

## Failure modes

| Symptom | Likely cause | Action |
|---------|--------------|--------|
| "curl: command not found" | curl missing | Install curl via system package manager |
| "401 Unauthorized" from Discord | Bad bot token | Operator resets token, updates config.json |
| "403 Forbidden" from Discord | Bot lacks permissions in channel | Operator grants `Send Messages` permission |
| No messages posting, no error | channel_id empty or all account tokens empty | Fill config.json with real values |

Hook failures never block worker lifecycle — the worker completes its task
even if Discord posts fail. The kit logs a warning and continues.
