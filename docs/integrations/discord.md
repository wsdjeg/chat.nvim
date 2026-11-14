---
layout: default
title: Discord Integration
parent: IM Integration
nav_order: 1
---

<!-- prettier-ignore-start -->
# Discord Integration
{: .no_toc }
## Table of contents
{: .no_toc }
<!-- prettier-ignore-end -->

<!-- prettier-ignore -->
- content
{:toc}

---

Discord integration allows you to interact with AI assistants via Discord messages.

## Features

- **Bidirectional Communication**: Send messages from Discord to chat.nvim and receive responses
- **Private and Group Chats**: Direct messages get their own session and workspace; guild channels can be shared
- **Multiple Channels**: Serve any number of guild channels, each with its own cursor and session
- **Session Binding**: Bind a Discord channel (or a DM) to a chat.nvim session
- **Remote Control**: Use Discord commands to manage sessions remotely
- **Automatic Polling**: Bot polls for new messages every 3 seconds
- **Auto-chunking**: Messages > 2,000 characters are automatically split

---

## Setup Guide

### 1. Create Discord Application

- Go to https://discord.com/developers/applications
- Click "New Application"
- Give it a name (e.g., "Chat.nvim Bot")

### 2. Create Bot User

- Navigate to "Bot" section
- Click "Add Bot"
- Copy the **Token** (this is your `integrations.discord.token`)

{: .warning }

> Keep your bot token secure! Never share it or commit it to version control.

### 3. Enable Message Content Intent

- Under "Privileged Gateway Intents"
- Enable "Message Content Intent" ✅
- Save changes

{: .info }

> Message Content Intent is required for the bot to read message content in servers.

### 4. Get Channel ID

- Enable Developer Mode in Discord (User Settings → Advanced → Developer Mode)
- Right-click your channel → Copy ID (this is your `integrations.discord.channel_id`)

### 5. Invite Bot to Server

- Go to "OAuth2" → "URL Generator"
- Select "bot" scope
- Required permissions: "Read Messages", "Send Messages", "Read Message History"
- Copy and open the generated URL
- Authorize the bot

### 6. Configure chat.nvim

```lua
require('chat').setup({
  integrations = {
    discord = {
      token = 'YOUR_DISCORD_BOT_TOKEN',
      channel_id = 'YOUR_CHANNEL_ID',

      -- Optional: serve additional guild channels
      channel_ids = { 'ANOTHER_CHANNEL_ID' },

      -- Optional: register every text channel of this guild on connect
      guild_id = 'YOUR_GUILD_ID',

      -- Optional: private (DM) chats
      p2p = {
        enable = true,
        -- Omit `allow` to serve every DM channel the bot can see.
        allow = { 'USER_ID_ALLOWED_TO_DM' },
        -- Root for per-peer workspaces (defaults to the first `allowed_path`)
        cwd_root = '/path/to/projects',
      },
    },
  },
})
```

---

## Private Chats and Group Chats

The integration treats a guild channel and a DM channel the same way at the
polling level (`/channels/{id}/messages`), but their policies differ.

| | Guild channel | Direct message |
| --- | --- | --- |
| Must @mention the bot | Yes (or reply to a bot message, or use a `/command`) | No |
| Who may talk | Everyone allowed to see the channel | Only peers admitted by `p2p.allow` (or anyone, when unset) |
| Session | `discord-<channel_id>`, shared by the channel | `discord-<channel_id>`, one per peer |
| Working directory | Neovim cwd (shared on purpose) | `<cwd_root>/discord-<channel_id>` (isolated per peer) |

A DM channel is listed by Discord only after the conversation was opened, so the
integration re-reads the bot's DM channel list every ~36 seconds (every 12 polls
at the 3 second interval). A peer who writes for the first time is picked up on
the next refresh.

### Why peers get their own workspace

Two people talking to the bot privately must never share a working directory:
they would see each other's files and `git checkout`, and one user's edits would
land in another's tree. So every DM peer gets `<cwd_root>/discord-<channel_id>`.

`cwd_root` defaults to the first entry of `allowed_path`. That is deliberate: a
workspace outside `allowed_path` is useless because every file tool refuses it,
so keeping the root inside the allowed tree means the isolation never widens what
the bot may touch. When neither is configured, DMs keep the session default.

Guild channels keep the Neovim cwd: a guild channel is deliberately a shared
workspace, and moving it elsewhere would change existing behaviour.

---

## Commands

### Neovim Commands

| Command                | Description                              |
| ---------------------- | ---------------------------------------- |
| `:Chat bridge discord` | Bind current session to the Discord bot  |

### Discord Commands

| Command      | Description                                                        |
| ------------ | ------------------------------------------------------------------ |
| `/session`   | Bind this channel (or DM) to the current chat.nvim window session   |
| `/session N` | Bind this channel to session `N` from the last `/list` of this chat |
| `/list`      | List sessions (per chat numbering, `/list <filter> -p N` to page)   |
| `/clear`     | Clear messages in the bound session                                 |
| `/status`    | Show session, provider, model, cwd and idle/processing state        |

---

## Workflow

1. Configure the Discord bot token and channel ID
2. Open chat.nvim and create/start a session
3. Run `:Chat bridge discord` to bind the session
4. In Discord, type `/session` to confirm the binding
5. Mention the bot (in guild channels) or just write (in a DM) to interact
6. The AI response is sent back to the channel the message came from

{: .highlight }

> In guild channels the bot only responds when mentioned, when replying to its
> own message, or when the message starts with a `/command`. In DMs it answers
> every message from an admitted peer.

---

## Message Handling

### Mentions (guild channels)

```
@Chat.nvim Bot What is the weather today?
```

### Replies (guild channels)

```
[Reply to bot's message]
Can you provide more details?
```

### Direct Messages

No mention needed:

```
Hello, how can you help me?
```

---

## Technical Details

- **API**: Discord REST API v10
- **Polling**: 3-second intervals, one sequential request per container
- **Container list**: `channel_id` (main), `channel_ids`, `guild_id` text channels, and DM channels
- **Message Limit**: Auto-chunking for messages > 2,000 characters
- **State Persistence**: `<storage_dir>/integration/discord.json`
- **Timeout Protection**: 5-second connect timeout / 10-second total, plus a 15-second watchdog

The state file stores, per channel:

- `last_message_id` — the cursor, so a restart resumes where it stopped
- `chat_type` — `group` or `p2p`
- `peer` — the admitted DM user id
- `session` — the bound session id

`bot_id` is persisted too: guild messages are only accepted when they mention the
bot, so losing it across a restart would drop every mention until the lookup
answers again.

---

## Troubleshooting

### Bot Not Responding

**Symptom**: Bot does not respond to messages.

**Solution**:

1. Verify token and channel id are correct
2. Check the bot has "Message Content Intent" enabled
3. Ensure the bot is invited with proper permissions
4. In guild channels, make sure you mention the bot or reply to its message
5. For DMs, check `p2p.enable` is not `false` and that your user id is in
   `p2p.allow` when that list is configured

### DM Not Working

**Symptom**: Private messages are ignored.

**Solution**:

1. The DM channel only exists after the conversation is opened — send a message
   first, then wait up to ~36 seconds for the next DM refresh
2. Check the log for `[Discord] Skip DM channel (peer not allowed)` — it means
   `p2p.allow` is set and your id is missing
3. Check `[Discord] Skip p2p message (peer not allowed)` — same cause, on the
   message path

### Permission Errors

**Symptom**: Bot lacks permissions to read/send messages.

**Solution**:

1. Re-invite the bot with correct permissions
2. Check server role permissions
3. Verify channel permissions for the bot

---

## Best Practices

### 1. Use a Dedicated Channel

Create a dedicated channel for the bot to avoid noise:

```
#ai-assistant
```

### 2. Limit Bot Access

Only invite the bot to channels where you need AI assistance. Set `p2p.allow`
when the bot is reachable by people who should not get a private workspace.

### 3. Monitor Token Usage

Keep track of your AI provider's token usage when using Discord integration.

### 4. Regular Cleanup

Periodically clear old sessions to maintain performance:

```vim
:Chat clear
```

---

## Next Steps

- [Telegram Integration](./telegram/) - Setup Telegram bot
- [Slack Integration](./slack/) - Setup Slack bot
- [IM Integration Overview](./) - All IM integrations

