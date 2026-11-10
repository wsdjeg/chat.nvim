---
layout: default
title: IM Integration
nav_order: 8
has_children: true
---

<!-- prettier-ignore-start -->
# IM Integration
{: .no_toc }
## Table of contents
{: .no_toc }
<!-- prettier-ignore-end -->

<!-- prettier-ignore -->
- content
{:toc}

---

chat.nvim supports integration with multiple instant messaging platforms for remote AI interaction. This allows you to interact with AI assistants from your favorite messaging apps.

## Supported Platforms

| Platform | Icon | Bidirectional | Features                                |
| -------- | ---- | ------------- | --------------------------------------- |
| Discord  | 💬   | ✅ Yes        | Full-featured bot with session binding  |
| Lark     | 🐦   | ✅ Yes        | Feishu/Lark bot with message polling    |
| DingTalk | 📱   | ✅ Yes\*      | Webhook (one-way) or API (two-way)      |
| WeCom    | 💼   | ✅ Yes\*      | Enterprise WeChat webhook or API        |
| Weixin   | 💬   | ✅ Yes\*      | Personal WeChat via external API        |
| Telegram | ✈️   | ✅ Yes        | Bot API with group/private chat support |
| Slack    | 💼   | ✅ Yes        | Workspace bot with message polling      |

\*Webhook mode is one-way only; API mode supports bidirectional communication.

---

## Common Features

All IM integrations share these common features:

### Commands

- `:Chat bridge <platform>` - Bind current session to platform
- `:Chat unbridge [platform]` - Unbind integration (all or specific platform)
- `/session [number|id]` - Check/update session binding
- `/list [pattern] [-p N]` - List available sessions (optional pattern filter,
  `-p N` selects page N)
- `/clear` - Clear current session messages

### `/list` pagination

Sessions are listed 10 per page and rendered as a markdown ordered list
(`1.`, `2.`, …) so chat clients display them as a real numbered list. The
numbering is **global**: page 2 starts at `11.`, it does not restart at `1.`,
so a number always identifies the same session no matter which page it was
read on. That means `/session 12` binds session 12 even while page 1 is still
on screen — the number comes from the last `/list` of the current chat, not
from the rendered page.

`-p` is a flag rather than a bare number because session ids are date-shaped
strings full of digits: `/list 2` would be ambiguous between "page 2" and
"search for 2".

```text
/list                  # page 1 of everything
/list -p 2             # page 2
/list refactor         # page 1 of the matches
/list refactor -p 2    # page 2 of the matches
```

The footer names the page and the neighbouring pages, and the command shown is
copy-pasteable:

```text
Total: 137 session(s)
Page 1/14 · next: /list -p 2
```

Patterns are matched as plain text, so a title containing `+`, `%` or `(` is
searched literally instead of being interpreted as a Lua pattern.

The published numbering is per chat: two people running `/list` in two
different chats do not overwrite each other's `/session <n>` numbering.

### Bridge Semantics

One rule covers every entry point (`:Chat bridge`, `:Chat unbridge`,
`/session`, `GET|PUT|DELETE /session/:id/bridge`):

- **Binding replaces.** Bridging a session drops whatever that platform pointed
  at before, so a per-chat binding can never outlive the session it was created
  under.
- **Unbinding clears both levels.** Platform-level and per-chat bindings for the
  session are dropped together. After unbridging, the integration really stops
  replying — it is not merely hidden from the title bar.
- **Display matches routing.** The window title badge, `GET /session/:id/bridge`
  and the actual reply routing all read the same binding table, so a session
  that receives replies always shows as bridged.
- **Failures are reported.** `:Chat bridge` says whether the platform is unknown,
  whether there is no session, or that the bridge succeeded — the same
  distinction the HTTP route returns (`false` vs `nil`). `:Chat unbridge` with
  nothing bound reports "Nothing bound to current session" instead of claiming
  success.

### Technical Details

- **Message Queue**: Sequential processing to prevent race conditions
- **State Persistence**: JSON files in `stdpath('data')`
- **Auto-reconnect**: Automatic recovery from network issues
- **Timeout Protection**: 5-second request timeout

---

## Configuration

Configure IM integrations in your chat.nvim setup:

```lua
require('chat').setup({
  integrations = {
    -- Discord
    discord = {
      token = 'YOUR_DISCORD_BOT_TOKEN',
      channel_id = 'YOUR_CHANNEL_ID',
    },

    -- Telegram
    telegram = {
      bot_token = 'YOUR_BOT_TOKEN',
      chat_id = 'YOUR_CHAT_ID',
    },

    -- Slack
    slack = {
      bot_token = 'xoxb-YOUR-BOT-TOKEN',
      channel_id = 'CXXXXXXXXXX',
    },

    -- Lark (Feishu)
    lark = {
      app_id = 'YOUR_APP_ID',
      app_secret = 'YOUR_APP_SECRET',
      chat_id = 'YOUR_CHAT_ID',
    },

    -- DingTalk
    dingtalk = {
      webhook = 'https://oapi.dingtalk.com/robot/send?access_token=XXX',
    },

    -- WeCom (Enterprise WeChat)
    wecom = {
      webhook_key = 'YOUR_WEBHOOK_KEY',
    },
  },
})
```

{: .info }

> Only configure the platforms you plan to use. Others can be omitted.

---

## Platform Comparison

| Platform | Mode    | Bidirectional | Setup Complexity | Message Limit |
| -------- | ------- | ------------- | ---------------- | ------------- |
| Discord  | Bot API | ✅ Yes        | Medium           | 2,000 chars   |
| Lark     | Bot API | ✅ Yes        | Medium           | 30,720 chars  |
| DingTalk | Webhook | ❌ No         | Low              | 20,000 chars  |
| DingTalk | API     | ✅ Yes        | High             | 20,000 chars  |
| WeCom    | Webhook | ❌ No         | Low              | 2,048 chars   |
| WeCom    | API     | ✅ Yes        | High             | 2,048 chars   |
| Telegram | Bot API | ✅ Yes        | Low              | 4,096 chars   |
| Slack    | Bot API | ✅ Yes        | Medium           | 40,000 chars  |

---

## Platform-Specific Notes

### Discord

- Requires "Message Content Intent" enabled
- Bot must be mentioned or replied to in group chats
- Private channels require direct messages

### Lark

- Requires app approval for production use
- Tenant access token is auto-refreshed
- Supports rich message types (text, cards, etc.)

### DingTalk

- Webhook mode is simplest but one-way only
- API mode requires enterprise app registration
- Stream mode recommended for bidirectional communication

### WeCom

- Webhook mode is simplest but one-way only
- API mode requires corporate approval
- Internal apps have more permissions

### Telegram

- Works in both private and group chats
- Groups require bot to be admin for some features
- Supports inline queries and callbacks

### Slack

- Bot must be invited to channels
- Requires specific OAuth scopes
- Responds to @mentions and thread replies

---

## Workflow

The general workflow for IM integration:

1. Configure the platform in your chat.nvim setup
2. Open chat.nvim and create/start a session
3. Run `:Chat bridge <platform>` to bind the session
4. In the messaging app, interact with the bot
5. AI response will be sent back automatically

{: .highlight }

> **Session Binding**: The `:Chat bridge` command connects your current chat.nvim session to the messaging platform, allowing messages from the platform to be processed by that specific session. Platforms that can address a single chat (currently Lark) may bind each conversation separately; for every other platform the whole integration is bound at once.

---

## Message Flow

### Sending Messages

1. User sends message in IM platform
2. Integration polls for new messages (every 3 seconds)
3. Message is queued in chat.nvim
4. Message is processed by the bound session
5. AI response is generated
6. Response is sent back to IM platform

### Auto-chunking

Messages that exceed platform limits are automatically split:

- Discord: 2,000 character chunks
- Telegram: 4,096 character chunks
- Slack: 40,000 character chunks
- Lark: 30,720 character chunks
- DingTalk: 20,000 character chunks
- WeCom/Weixin: 2,048 character chunks

---

## Contributing New Integrations

To add a new IM platform integration:

### 1. Create Integration Module

Create `lua/chat/integrations/<platform>.lua`

### 2. Implement Required Functions

```lua
local M = {}

-- Start listening for messages
function M.connect(callback)
  -- Implementation
end

-- Stop listening
function M.disconnect()
  -- Implementation
end

-- Send message
function M.send_message(content)
  -- Implementation
end

-- Get current session ID
function M.current_session()
  -- Implementation
end

-- Set current session
function M.set_session(session)
  -- Implementation
end

-- Cleanup resources
function M.cleanup()
  -- Implementation
end

return M
```

### 3. Register Integration

Update `lua/chat/integrations/init.lua`:

```lua
local integrations = {
  discord = require('chat.integrations.discord'),
  telegram = require('chat.integrations.telegram'),
  -- Add your new integration
  my_platform = require('chat.integrations.my_platform'),
}
```

### 4. Add Documentation

Add documentation to:

- README.md IM Integration section
- docs/integrations/<platform>.md

### Reference Implementation

See `lua/chat/integrations/discord.lua` for a complete reference implementation.

---

## Next Steps

- [Discord Integration](./discord/) - Setup Discord bot
- [Telegram Integration](./telegram/) - Setup Telegram bot
- [Slack Integration](./slack/) - Setup Slack bot
- [Lark Integration](./lark/) - Setup Lark/Feishu bot
- [DingTalk Integration](./dingtalk/) - Setup DingTalk webhook/API
- [WeCom Integration](./wecom/) - Setup WeCom webhook/API
- [Weixin Integration](./weixin/) - Setup personal WeChat via QR login
- [HTTP API](../api/http/) - HTTP API integration
