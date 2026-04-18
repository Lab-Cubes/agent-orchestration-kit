# @nps-kit/plugin-discord

Standalone Discord notification plugin for nps-kit agents. Works with any
Discord bot token — no external services or special infrastructure required.
Posts worker lifecycle events (claimed, completed, failed) to a Discord channel
via per-worker bot accounts.

Zero coupling to the core kit — installs three hook scripts into
`kits/agents/hooks/`, reads its own config, runs only when events fire. Uninstall
is `rm` the hook files.

**Optional convenience:** if you already store bot tokens in an `openclaw.json`
file, set `token_from_openclaw` to read tokens from there and avoid duplicating
secrets. This is entirely optional — the plugin works standalone with tokens
in `config.json`.

## Quick start

```bash
cd plugins/discord
cp config.example.json config.json
$EDITOR config.json            # fill in channel_id + account tokens
./install.sh
```

Next agent dispatch will post to Discord.

## Config

```json
{
  "channel_id": "123456789012345678",

  "accounts": {
    "default":      { "token": "Bot token for fallback account", "display_name": "agent" },
    "coder1":       { "token": "Bot token for coder-01 bot",     "display_name": "coder-01" },
    "coder2":       { "token": "Bot token for coder-02 bot",     "display_name": "coder-02" },
    "critic":       { "token": "Bot token for critic bot",       "display_name": "critic" },
    "researcher":   { "token": "Bot token for researcher bot",   "display_name": "researcher" },
    "orchestrator": { "token": "Bot token for orchestrator bot", "display_name": "orchestrator" }
  },

  "worker_map": {
    "coder-01":     "coder1",
    "coder-02":     "coder2",
    "critic-01":    "critic",
    "researcher-01":"researcher",
    "dispatcher":   "orchestrator"
  }
}
```

| Field | Meaning |
|-------|---------|
| `channel_id` | Discord channel where messages post. Get from Discord client → right-click channel → Copy Channel ID (Developer Mode) |
| `accounts` | Map of account name → `{ token, display_name }`. Each account is a separate Discord bot. `default` is the fallback when no worker_map entry matches |
| `worker_map` | Map of NOP worker ID → account name. Workers not listed fall back to `default` |

### Token from openclaw.json (avoid duplicating secrets)

If you already store bot tokens in `openclaw.json`, set `token_from_openclaw` instead of
copying tokens into `config.json`:

```json
{
  "channel_id": "123456789012345678",
  "token_from_openclaw": "/path/to/openclaw.json",
  "worker_map": {
    "coder-01":     "coder1",
    "coder-02":     "coder2",
    "critic-01":    "critic",
    "researcher-01":"researcher"
  }
}
```

Tokens are read at runtime from `channels.discord.accounts.{account_name}.token` in the
openclaw.json file. Worker display names still come from `accounts[account_name].display_name`
if set, or fall back to the account name.

## Events

| Event | Message format |
|-------|----------------|
| `task-claimed`   | `🔨 {account} claimed {task_id}` |
| `task-completed` | `✅ {account} completed {task_id} ({cost_npt} NPT)` |
| `task-failed`    | `❌ {account} failed {task_id}` |

All messages suppressed if `channel_id` is empty or no token can be resolved — safe fallback.

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
