---
layout: default
title: Telegram Integration
parent: IM Integration
nav_order: 2
---

<!-- prettier-ignore-start -->
# Telegram Integration
{: .no_toc }
## Table of contents
{: .no_toc }
<!-- prettier-ignore-end -->

<!-- prettier-ignore -->
- content
{:toc}

---

Telegram bot integration with full feature support.

## Features

- **Full Bot API Support**: Works in groups and private chats
- **Markdown Support**: Send formatted messages with Markdown
- **Reply Support**: Reply to specific messages
- **Long Message Support**: Auto-chunking for messages > 4,096 characters
- **Bot Commands**: Support for `/session` and `/clear` commands
- **Group Support**: Works in both private and group chats

---

## Setup Guide

### 1. Create Telegram Bot

- Open Telegram and search for `@BotFather`
- Send `/newbot` command
- Follow instructions to create your bot
- Copy the **Bot Token** (format: `123456789:ABCdefGHIjklMNOpqrsTUVwxyz`)

{: .warning }

> Keep your bot token secure! Never share it or commit it to version control.

### 2. Get Chat ID

#### For Private Chat

- Start a conversation with your bot
- Send a message to the bot
- Visit: `https://api.telegram.org/bot<YOUR_BOT_TOKEN>/getUpdates`
- Find the `"chat":{"id":` value in the response

#### For Group Chat

- Add bot to group
- Send a message mentioning the bot
- Visit the same URL to get the group chat ID

{: .info }

> Group chat IDs are typically negative numbers (e.g., `-123456789`).

### 3. Configure chat.nvim

```lua
require('chat').setup({
  integrations = {
    telegram = {
      bot_token = 'YOUR_BOT_TOKEN',
      chat_id = 'YOUR_CHAT_ID',
    },
  },
})
```

---

## Commands

### Neovim Commands

| Command                 | Description                           |
| ----------------------- | ------------------------------------- |
| `:Chat bridge telegram` | Bind current session to Telegram chat |

### Telegram Commands

| Command    | Description                                            |
| ---------- | ------------------------------------------------------ |
| `/session` | Bind current Telegram chat to active chat.nvim session |
| `/clear`   | Clear messages in the bound session                    |

---

## Workflow

1. Configure Telegram bot token and chat ID
2. Open chat.nvim and create/start a session
3. Run `:Chat bridge telegram` to bind the session
4. In Telegram, send a message to the bot or mention it in a group
5. AI response will be sent back to Telegram automatically

---

## Message Handling

### Private Chat

Just send a message to the bot:

```
Hello, how can you help me?
```

### Group Chat

Mention the bot to get a response:

```
@YourBotName What is the weather today?
```

{: .info }

> In groups, the bot only responds when mentioned to avoid noise.

---

## Technical Details

- **API**: Telegram Bot API
- **Polling**: 3-second intervals via getUpdates
- **Message Format**: Markdown support
- **Message Limit**: Auto-chunking for messages > 4,096 characters
- **State Persistence**: `stdpath('data')/chat-telegram-state.json`
- **Bot Detection**: Auto-fetches and caches bot username

---

## Markdown Support

Telegram supports Markdown formatting in messages:

- **Bold**: `*text*`
- **Italic**: `_text_`
- **Code**: `` `code` ``
- **Pre**: ` `code block` `
- **Links**: `[text](URL)`

{: .info }

> The AI assistant can use Markdown formatting in its responses.

---

## Troubleshooting

### Bot Not Responding

**Symptom**: Bot does not respond to messages.

**Solution**:

1. Verify bot token is correct
2. Check if chat_id is correct (private chat or group)
3. For groups, make sure bot has read permissions
4. Try sending `/start` to the bot first

### Permission Errors

**Symptom**: Bot cannot read messages in group.

**Solution**:

1. Ensure bot is added to the group
2. Check if bot has necessary permissions
3. Disable group privacy mode in BotFather:
   - Send `/setprivacy` to @BotFather
   - Select your bot
   - Choose "Disable"

### State Issues

**Symptom**: Session binding not working.

**Solution**:

- Clear state: `:lua require('chat.integrations.telegram').clear_state()`

---

## Best Practices

### 1. Use Private Chat for Testing

Start with private chat to verify bot functionality:

```
Start a private conversation with your bot
```

### 2. Disable Privacy Mode for Groups

Disable privacy mode to receive all messages in groups:

```
Send /setprivacy to @BotFather
Select your bot
Choose "Disable"
```

### 3. Create Dedicated Group

Create a dedicated group for AI assistance:

```
Create group: "AI Assistant"
Add your bot
```

### 4. Monitor Token Usage

Keep track of your AI provider's token usage.

---

---

## Next Steps

- [Discord Integration](./discord/) - Setup Discord bot
- [Slack Integration](./slack/) - Setup Slack bot
- [IM Integration Overview](./im/) - All IM integrations
