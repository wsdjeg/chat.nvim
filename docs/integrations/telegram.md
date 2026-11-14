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
- **Markdown Support**: Send formatted messages with Markdown, falling back to plain text when Telegram rejects the markup
- **Reply Support**: Reply to specific messages
- **Long Message Support**: Auto-chunking for messages > 4,096 characters
- **Bot Commands**: `/session`, `/list`, `/status`, `/clear`, `/acl`, `/allow`, `/deny`
- **Access Control**: `allow_all`, `whitelist` and `blacklist` modes, managed from inside the chat
- **Per-chat Sessions**: Every chat can own its own session, private chats get an isolated workspace
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

`chat_id` is the **main chat**: the one `:Chat bridge telegram` and the platform-level
session address. It is required — without it the integration does not start.

#### Optional: access control

```lua
require('chat').setup({
  integrations = {
    telegram = {
      bot_token = 'YOUR_BOT_TOKEN',
      chat_id = 'YOUR_CHAT_ID',
      acl = {
        -- 'allow_all' (default) | 'whitelist' | 'blacklist'
        mode = 'whitelist',
        -- Always allowed, and the only ones who may run /allow, /deny, /acl.
        admins = { '123456789' },
        whitelist = { '987654321' },
        blacklist = {},
      },
    },
  },
})
```

Numeric user ids are authoritative. An `@username` entry is accepted as a convenience,
but it is only a fallback: usernames are user-chosen and can be changed or squatted.

#### Optional: private chats

```lua
require('chat').setup({
  integrations = {
    telegram = {
      p2p = {
        -- false disables private chats entirely.
        enable = true,
        -- An explicit list is the whole policy (numeric ids only).
        allow = { '123456789' },
        -- Root of the per-chat workspaces. Defaults to the first
        -- `allowed_path` entry.
        cwd_root = '/path/to/project',
      },
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
| `/session N` | Bind the chat to session number `N` from `/list`     |
| `/list`    | List sessions (supports `-p N` for pages)              |
| `/status`  | Show the bound session, provider, model and cwd        |
| `/clear`   | Clear messages in the bound session                    |
| `/acl`     | Show the effective ACL (admins only)                   |
| `/allow`   | Allow a user — reply to their message (admins only)     |
| `/deny`    | Deny a user — reply to their message (admins only)     |

{: .info }

> `/allow` and `/deny` need a **reply** to the target's message, or a raw numeric
> user id. There is no reliable way to turn an `@username` in text into an id,
> and a username-based grant would let anyone who takes that name later in.

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

No mention is needed: a private chat has nobody to mention.

### Group Chat

Mention the bot to get a response:

```
@YourBotName What is the weather today?
```

Replying to one of the bot's own messages also counts as addressing it.

{: .info }

> In groups, the bot only responds when mentioned or replied to, to avoid noise.

### Media messages

Text and captions are passed through as-is. Anything else becomes a short marker
(`[photo]`, `[sticker]`, `[voice]`, `[document]`, …) so the message still shows up
and the assistant can say what it did not receive.

---

## Multiple chats at once

One bot can serve several chats. Each chat is a **container** with its own session:

- Group chats keep sharing the Neovim working directory: a group is deliberately a
  shared workspace.
- Private chats get an isolated workspace under `<p2p.cwd_root>/telegram-<chat_id>`,
  so two users never see each other's files or git checkout.

`chat_id` stays the main container: it is what `current_session()` / `set_session()`
and the HTTP API address. Chat bindings are visible through the bridge API
(`GET /session/:id/bridge`), and unbinding clears both levels.

Workspaces are created when a session is created, so changing `p2p.cwd_root` does
not migrate an existing session.

---

## Technical Details

- **API**: Telegram Bot API
- **Polling**: long polling (`getUpdates`, 10-second timeout) started every 3 seconds
- **Message Format**: Markdown, retried as plain text when the API rejects the markup
- **Message Limit**: Auto-chunking for messages > 4,096 characters
- **State Persistence**: `<storage_dir>/integration/telegram.json`
- **Bot Detection**: Auto-fetches and caches the bot id and username; group mentions
  stay undetectable until the lookup succeeds
- **Deduplication**: The last 100 update ids are kept, so a replayed update is never
  answered twice

---

## Markdown Support

Telegram supports Markdown formatting in messages:

- **Bold**: `*text*`
- **Italic**: `_text_`
- **Code**: `` `code` ``
- **Pre**: ` `code block` `
- **Links**: `[text](URL)`

{: .info }

> The AI assistant can use Markdown formatting in its responses. Telegram's
> classic Markdown parser rejects unbalanced `*` or `_`, so a message refused with
> 400 "can't parse entities" is automatically resent as plain text instead of
> being lost.

---

## Troubleshooting

### Bot Not Responding

**Symptom**: Bot does not respond to messages.

**Solution**:

1. Verify bot token is correct
2. Check if chat_id is correct (private chat or group)
3. For groups, make sure bot has read permissions
4. Try sending `/start` to the bot first

### Group Messages Ignored

**Symptom**: The bot works in a private chat but ignores group messages.

**Solution**:

1. Mention the bot (`@YourBotName`) or reply to one of its messages
2. Check the runtime log for `bot_token not configured` / bot identity warnings
3. Disable group privacy mode in BotFather (see below)

### Private Chat Rejected

**Symptom**: Messages in a private chat get no answer.

**Solution**:

1. An explicit `p2p.allow` list is authoritative — make sure the sender's numeric id is in it
2. `p2p.enable = false` disables private chats entirely
3. With `acl.mode = 'whitelist'`, the sender must be whitelisted or an admin

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
- [IM Integration Overview](./) - All IM integrations

