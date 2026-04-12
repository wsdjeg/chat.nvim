---
layout: default
title: Slack Integration
parent: IM Integration
nav_order: 3
---

<!-- prettier-ignore-start -->
# Slack Integration
{: .no_toc }
## Table of contents
{: .no_toc }
<!-- prettier-ignore-end -->

<!-- prettier-ignore -->
- content
{:toc}

---

Slack integration for workspace communication.

## Features

- **Bidirectional Communication**: Send and receive messages via Slack bot
- **Session Binding**: Bind Slack channels to chat.nvim sessions
- **Automatic Polling**: Polls for new messages every 3 seconds
- **Thread Support**: Reply to messages in threads
- **Long Message Support**: Handles messages up to 40,000 characters
- **Mention Detection**: Responds to @mentions and thread replies

---

## Setup Guide

### 1. Create Slack App

- Go to https://api.slack.com/apps
- Click "Create New App"
- Choose "From scratch"
- Give it a name (e.g., "Chat.nvim Bot") and select your workspace

### 2. Configure Bot Permissions

Required Bot Token Scopes:

- `channels:history` - Read messages in channels
- `chat:write` - Send messages
- `groups:history` - Read messages in private channels
- `im:history` - Read messages in direct messages
- `mpim:history` - Read messages in multiparty direct messages

{: .info }

> These scopes are required for the bot to read and send messages.

**Configuration steps**:

1. Go to "OAuth & Permissions" in your app
2. Add the scopes above to "Bot Token Scopes"
3. Scroll to "OAuth Tokens for Your Workspace"
4. Click "Install to Workspace"
5. Copy the **Bot User OAuth Token** (starts with `xoxb-`)

{: .warning }

> Keep your bot token secure! Never share it or commit it to version control.

### 3. Get Channel ID

- Open Slack in browser
- Go to the channel you want to use
- The channel ID is in the URL: `https://app.slack.com/client/WORKSPACE_ID/CHANNEL_ID`
- Or right-click channel → "Copy Link" → extract the last part

{: .info }

> Channel IDs typically start with `C` (e.g., `C1234567890`).

### 4. Invite Bot to Channel

- In Slack, go to the channel
- Type: `/invite @Chat.nvim Bot`
- Or use: `/invite @YourBotName`

{: .warning }

> The bot must be invited to the channel to read and send messages.

### 5. Configure chat.nvim

```lua
require('chat').setup({
  integrations = {
    slack = {
      bot_token = 'xoxb-YOUR-BOT-TOKEN',
      channel_id = 'CXXXXXXXXXX',
    },
  },
})
```

---

## Commands

### Neovim Commands

| Command              | Description                           |
| -------------------- | ------------------------------------- |
| `:Chat bridge slack` | Bind current session to Slack channel |

### Slack Commands

| Command    | Description                                            |
| ---------- | ------------------------------------------------------ |
| `/session` | Bind current Slack channel to active chat.nvim session |
| `/clear`   | Clear messages in the bound session                    |

---

## Workflow

1. Configure Slack bot token and channel ID
2. Open chat.nvim and create/start a session
3. Run `:Chat bridge slack` to bind the session
4. In Slack, mention the bot (e.g., `@Chat.nvim Bot hello`) to interact
5. AI response will be sent back to Slack automatically

---

## Message Handling

### Mentions

In channels, mention the bot to get a response:

```
@Chat.nvim Bot What is the weather today?
```

{: .info }

> The bot only responds when mentioned to avoid noise in busy channels.

### Thread Replies

Reply to any bot message in a thread:

```
[Reply in thread]
Can you provide more details?
```

{: .highlight }

> Thread replies are detected and processed automatically.

### Direct Messages

In direct messages, just send a message:

```
Hello, how can you help me?
```

---

## Technical Details

- **API**: Slack Web API
- **Authentication**: Bot User OAuth Token (xoxb-)
- **Polling**: 3-second intervals
- **Message Limit**: 40,000 characters
- **State Persistence**: `stdpath('data')/chat-slack-state.json`
- **Timeout Protection**: 5-second request timeout

---

## Troubleshooting

### Bot Not Responding

**Symptom**: Bot does not respond to messages.

**Solution**:

1. Verify bot_token and channel_id are correct
2. Check bot has required permissions
3. Ensure bot is invited to the channel
4. Make sure you're mentioning the bot with @bot_name
5. Check Slack API logs: `:messages` command in Neovim

### Permission Errors

**Symptom**: Bot lacks permissions to read/send messages.

**Solution**:

1. Verify all required scopes are added
2. Reinstall the app to workspace after adding scopes
3. Check if the workspace admin needs to approve the app

### Channel Access Issues

**Symptom**: Bot cannot read messages in channel.

**Solution**:

1. Ensure bot is invited to the channel (`/invite @BotName`)
2. Check if the channel is private (bot needs `groups:history` scope)
3. Verify the bot is not restricted by workspace policies

### State Issues

**Symptom**: Session binding not working.

**Solution**:

- Clear state: `:lua require('chat.integrations.slack').clear_state()`

---

## Notes

{: .info }

> - Slack API has rate limits (tier 3: ~50+ requests per minute)
> - The bot only responds when mentioned or in thread replies
> - Private channels require the bot to be invited
> - Bot user ID is cached in state for faster mention detection

---

## Best Practices

### 1. Use Dedicated Channel

Create a dedicated channel for AI assistance:

```
#ai-assistant
```

### 2. Limit Bot Access

Only invite the bot to channels where you need AI assistance.

### 3. Use Threads for Context

Use thread replies to maintain conversation context:

```
@Bot initial question
[Thread reply] follow-up question
[Thread reply] another question
```

### 4. Monitor Rate Limits

Be aware of Slack API rate limits when using the integration heavily.

---

---

## Next Steps

- [Discord Integration](./discord/) - Setup Discord bot
- [Telegram Integration](./telegram/) - Setup Telegram bot
- [IM Integration Overview](./im/) - All IM integrations
