# @nps-kit/plugin-discord

Discord notification plugin for [`@nps-kit/agents`](../../kits/agents/). Posts
worker lifecycle events (claimed, completed, failed) to a Discord channel via
a bot account.

Works with any NPS-kit agents install. Zero coupling to the core kit — installs
three hook scripts into `kits/agents/hooks/`, reads its own config, runs only
when events fire. Uninstall is `rm` the hook files.

## Quick start

```bash
cd plugins/discord
cp config.example.json config.json
$EDITOR config.json            # fill in channel ID + bot token
./install.sh
```

Next agent dispatch will post to Discord.

## Config

```json
{
  "channel_id": "123456789012345678",
  "bot_token":  "your-discord-bot-token",
  "accounts": {
    "coder-01":      "coder1",
    "coder-02":      "coder2",
    "critic-01":     "critic",
    "researcher-01": "research",
    "default":       "agent"
  }
}
```

| Field | Meaning |
|-------|---------|
| `channel_id` | Discord channel where messages post. Get from Discord client → right-click channel → Copy ID (Developer Mode) |
| `bot_token`  | Your Discord bot's auth token. Create a bot at https://discord.com/developers/applications |
| `accounts`   | Optional per-agent display name map. Default used when worker ID isn't listed |

## Events

| Event | Message format |
|-------|----------------|
| `task-claimed`   | `🔨 {account} claimed {task_id}` |
| `task-completed` | `✅ {account} completed {task_id} ({cost_npt} NPT)` |
| `task-failed`    | `❌ {account} failed {task_id}` |

All messages suppressed if `channel_id` or `bot_token` are empty — safe fallback.

## Uninstall

```bash
rm ../../kits/agents/hooks/on-task-claimed.sh
rm ../../kits/agents/hooks/on-task-completed.sh
rm ../../kits/agents/hooks/on-task-failed.sh
```

Leaves `config.json` in place. Re-install by running `./install.sh` again.

## Writing your own plugin

This plugin is a worked example of the kit's hook contract. See
`kits/agents/hooks/README.md` for the full contract. The pattern:

1. Script reads relevant config from its own dir
2. Script reads `NPS_TASK_ID` / `NPS_AGENT_ID` / `NPS_STATUS` / `NPS_COST_NPT` env vars
3. Script does its thing (Slack post, webhook POST, metric emit, etc.)
4. `install.sh` copies or symlinks the scripts into `kits/agents/hooks/`

Zero coupling, trivial to extend.

## License

Apache 2.0.
