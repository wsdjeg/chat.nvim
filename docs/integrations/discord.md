---
layout: default
title: Discord Integration
parent: IM Integration
nav_order: 1
---

# Discord Integration

{: .no_toc }

<!-- prettier-ignore -->
- content
{:toc}

---

Discord integration allows you to interact with AI assistants via Discord messages.

## Features

- **Bidirectional Communication**: Send messages from Discord to chat.nvim and receive responses
- **Session Binding**: Bind specific Discord channels to chat.nvim sessions
- **Remote Control**: Use Discord commands to manage sessions remotely
- **Automatic Polling**: Bot polls for new messages every 3 seconds
- **Message Mentions**: Bot responds to mentions and replies
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
    },
  },
})
```

---

## Commands

### Neovim Commands

| Command                | Description                             |
| ---------------------- | --------------------------------------- |
| `:Chat bridge discord` | Bind current session to Discord channel |

### Discord Commands

| Command    | Description                                              |
| ---------- | -------------------------------------------------------- |
| `/session` | Bind current Discord channel to active chat.nvim session |
| `/clear`   | Clear messages in the bound session                      |

---

## Workflow

1. Configure Discord bot token and channel ID
2. Open chat.nvim and create/start a session
3. Run `:Chat bridge discord` to bind the session
4. In Discord, type `/session` to confirm binding
5. Mention the bot or reply to its messages to interact
6. AI response will be sent back to Discord automatically

{: .highlight }

> The bot only responds when mentioned or when replying to its messages in group channels.

---

## Message Handling

### Mentions

In group channels, mention the bot to get a response:

```
@Chat.nvim Bot What is the weather today?
```

### Replies

Reply to any bot message to continue the conversation:

```
[Reply to bot's message]
Can you provide more details?
```

### Direct Messages

In direct messages, just send a message:

```
Hello, how can you help me?
```

---

## Technical Details

- **API**: Discord REST API v10
- **Polling**: 3-second intervals
- **Message Limit**: Auto-chunking for messages > 2,000 characters
- **State Persistence**: `stdpath('data')/chat-discord-state.json`
- **Timeout Protection**: 5-second request timeout

---

## Troubleshooting

### Bot Not Responding

**Symptom**: Bot does not respond to messages.

**Solution**:

1. Verify token and channel_id are correct
2. Check bot has "Message Content Intent" enabled
3. Ensure bot is invited with proper permissions
4. Make sure you're mentioning the bot or replying to its messages

### Permission Errors

**Symptom**: Bot lacks permissions to read/send messages.

**Solution**:

1. Re-invite the bot with correct permissions
2. Check server role permissions
3. Verify channel permissions for the bot

### State Issues

**Symptom**: Session binding not working.

**Solution**:

- Clear state: `:lua require('chat.integrations.discord').clear_state()`

---

## Best Practices

### 1. Use Dedicated Channel

Create a dedicated channel for the bot to avoid noise:

```
#ai-assistant
```

### 2. Limit Bot Access

Only invite the bot to channels where you need AI assistance.

### 3. Monitor Token Usage

Keep track of your AI provider's token usage when using Discord integration.

### 4. Regular Cleanup

Periodically clear old sessions to maintain performance:

```vim
:Chat clear
```

---

## Next Steps

- [Telegram Integration](/docs/integrations/telegram/) - Setup Telegram bot
- [Slack Integration](/docs/integrations/slack/) - Setup Slack bot
- [IM Integration Overview](/docs/integrations/im/) - All IM integrations
