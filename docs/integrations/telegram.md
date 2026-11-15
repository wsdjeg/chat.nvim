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

#### Optional: pending messages on start

While Neovim is closed the bot keeps receiving messages: Telegram holds them until
the bot fetches them. Answering that queue on start would reply to hours of stale
requests in one burst, so by default the backlog is **skipped**:

```lua
require('chat').setup({
  integrations = {
    telegram = {
      -- true (default): ignore messages sent while the plugin was down.
      -- false: replay them, like the integration behaved before this option.
      discard_backlog = true,
    },
  },
})
```

The skip costs one extra request at start-up (`getUpdates` with `offset = -1`,
which returns only the newest queued update). The cursor is parked on that update
and polling begins just after it, so messages sent once the plugin is up are
answered normally.

{: .info }

> Set `discard_backlog = false` when the bot must never lose a request — for
> example when it is the only way to reach the assistant and you restart
> Neovim often.

---

## Commands

### Neovim Commands

| Command                 | Description                           |
| ----------------------- | ------------------------------------- |
| `:Chat bridge telegram` | Bind current session to Telegram chat |

### Telegram Commands

| Command      | Description                                            |
| ------------ | ------------------------------------------------------ |
| `/session`   | Bind current Telegram chat to active chat.nvim session |
| `/session N` | Bind the chat to session number `N` from `/list`     |
| `/list`      | List sessions (supports `-p N` for pages)              |
| `/status`    | Show the bound session, provider, model and cwd        |
| `/clear`     | Clear messages in the bound session                    |
| `/acl`       | Show the effective ACL (admins only)                   |
| `/allow`     | Allow a user — reply to their message (admins only)     |
| `/deny`      | Deny a user — reply to their message (admins only)      |

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

A `p2p.cwd_root` that points outside `allowed_path` is registered into it at
runtime, so the file tools accept `<p2p.cwd_root>/telegram-<chat_id>` without the
user repeating the path in config. Registration is runtime-only: the config file
is untouched and the allowed tree is not widened on the next start.

Because that entry is lost on restart, creating and registering the directory runs
on every binding lookup rather than once at provisioning. A restart — or a
workspace deleted while the plugin was down — therefore heals on the next message
instead of leaving the chat unable to call any file tool.

The session's working directory is still assigned when the session is created,
so changing `p2p.cwd_root` does not migrate an existing session.

---

## Access Control (ACL)

By default anyone who can reach a served chat may talk to the bot. Set
`integrations.telegram.acl` (see [the example above](#optional-access-control)) to
restrict who can trigger replies.

| Mode        | Behaviour                                              |
| ----------- | ------------------------------------------------------ |
| `allow_all` | Default. Everyone in the served chats may talk to it.   |
| `whitelist` | Only the listed ids (plus admins) may talk to it.       |
| `blacklist` | Everyone except the listed ids may talk to it.          |

Notes:

- **Admins always pass.** `acl.admins` bypasses the ACL entirely and is the only
  set allowed to run `/allow`, `/deny` and `/acl`, so a whitelist that locked them
  out can still be repaired from inside the chat.
- **Runtime entries win over the mode.** `/allow` and `/deny` are persisted in the
  state file and checked *before* `acl.mode`, which is what keeps them useful
  without editing the config first. The full order is:

  | Order | Check |
  | ----- | ----- |
  | 1 | `acl.admins` — always allowed |
  | 2 | runtime blacklist — refused |
  | 3 | runtime whitelist — allowed |
  | 4 | `acl.mode` = `whitelist` / `blacklist` — applied to the config lists |
  | 5 | Otherwise allowed |

- **Ids first, usernames as fallback.** A numeric id in `admins` / `whitelist` /
  `blacklist` is authoritative; an `@username` entry is only matched against the
  sender's current username, and `/allow` / `/deny` refuse a username outright —
  see the [Telegram commands](#telegram-commands) note above.
- **Recent speakers are cached.** Every non-bot speaker is recorded in the state
  file (up to 30, newest first) and exposed through
  `require('chat.integrations.telegram').get_recent_senders()`, so user ids can be
  picked instead of copied out of the Telegram client.
- **ACL commands answer where they came from.** A `/allow` typed in a private chat
  is answered in that private chat, never announced in the group. Commands from
  non-admins are dropped silently (logged as a warning) so a group is not spammed,
  and the bot refuses to change the ACL entry for itself.

### Private chat admission

A private chat is one person talking to the bot privately, so it has its own policy
rather than reusing `acl.mode`:

| Order | Rule |
| ----- | ---- |
| 1 | The main `chat_id` is exempt — it is trusted by definition |
| 2 | `p2p.enable = false` — refuses every private chat |
| 3 | `p2p.allow` when set — authoritative, numeric ids only, no fallback |
| 4 | `acl.mode` = `whitelist` / `blacklist` — applied like any other chat |
| 5 | Otherwise allowed (a private chat only exists after somebody opened one) |

The default is "allowed" on purpose: this integration always answered private
chats, and a chat only exists once a person started the conversation with the bot.
An explicit `p2p.allow` list, on the other hand, is the whole policy — a typo in
one entry must not silently widen access.

- **Only the registered peer is trusted.** Inside a private container the message
  is attributed to `containers[chat_id].peer`; a message from any other user id is
  dropped *before* the container is registered, so a second person can never
  inherit that session or workspace.

---

## Technical Details

- **API**: Telegram Bot API
- **Polling**: long polling (`getUpdates`, 10-second timeout) started every 3 seconds
- **Pending updates**: skipped on start via one `getUpdates` with `offset = -1`
  (`discard_backlog = false` replays them instead)
- **Message Format**: Markdown, retried as plain text when the API rejects the markup
- **Message Limit**: Auto-chunking for messages > 4,096 characters
- **State Persistence**: `<storage_dir>/integration/telegram.json` — holds the cursor,
  the runtime ACL grants/denies, the recent-speaker cache and per-chat containers
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
5. Check the ACL: `/acl` works for admins only, so also look at the runtime log
   for `Skip message (sender not allowed)`

### Group Messages Ignored

**Symptom**: The bot works in a private chat but ignores group messages.

**Solution**:

1. Mention the bot (`@YourBotName`) or reply to one of its messages
2. Check the runtime log for `bot_token not configured` / bot identity warnings
3. Disable group privacy mode in BotFather (see below)

### Private Chat Rejected

**Symptom**: Messages in a private chat get no answer.

**Solution**:

1. The main `chat_id` is exempt from `p2p` checks — a second private chat is not
2. An explicit `p2p.allow` list is authoritative — make sure the sender's numeric id is in it
3. With `p2p.enable = false`, private chats are disabled entirely
4. With `acl.mode = 'whitelist'`, the sender must be whitelisted or an admin

### ACL Commands Do Nothing

**Symptom**: `/allow` or `/deny` gets no reply.

**Solution**:

1. Only `acl.admins` may run them — everyone else is ignored silently (check the
   log for `Ignore ACL command from non-admin`)
2. The command must be a **reply** to the target's message, or carry the raw
   numeric id: `/allow 987654321`
3. `/allowed` is not `/allow` — the command needs a space or the end of the message

### State Issues

**Symptom**: Session binding not working.

**Solution**:

- Clear state: `:lua require('chat.integrations.telegram').clear_state()`

{: .info }

> Clearing state also drops the runtime ACL grants/denies and the private-chat
> peers recorded in the state file. The configured `acl` lists stay untouched.

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

### 4. Lock Down Private Chats

In a group you control who is in the room, but a private chat is open to anyone who
finds the bot. Put the numeric ids in `p2p.allow` once the chat works:

```lua
p2p = { allow = { '123456789', '987654321' } }
```

An empty or missing list serves every private chat the bot receives.

### 5. Monitor Token Usage

Keep track of your AI provider's token usage.

---

---

## Next Steps

- [Discord Integration](./discord/) - Setup Discord bot
- [Slack Integration](./slack/) - Setup Slack bot
- [IM Integration Overview](./) - All IM integrations

