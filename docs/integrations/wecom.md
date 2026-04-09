---
layout: default
title: WeCom
nav_order: 6
parent: Integrations
---
# WeCom (Enterprise WeChat) Integration

{: .no_toc }

## Table of contents
{: .no_toc .text-delta }
1. TOC
{:toc}

---

WeCom integration with webhook or API mode.

## Features

- **Two Modes**: Webhook (simple, one-way) or API (bidirectional)
- **Corporate Integration**: Full enterprise WeChat support
- **Message Queue**: Sequential processing

---

## Modes

### Webhook Mode (Simple, One-Way)

Simplest setup, but only supports sending messages to WeCom.

### API Mode (Advanced, Bidirectional)

Full bidirectional communication, requires corporate approval.

---

## Setup Guide

### Webhook Mode

1. Add a webhook robot in WeCom group
2. Copy the webhook key
3. Configure:

```lua
require('chat').setup({
  integrations = {
    wecom = {
      webhook_key = 'YOUR_WEBHOOK_KEY',
    },
  },
})
```

{: .info }
> Webhook mode is the simplest setup but only supports one-way communication.

### API Mode

1. Create an enterprise application
2. Get CorpID, CorpSecret, and AgentID
3. Configure:

```lua
require('chat').setup({
  integrations = {
    wecom = {
      corp_id = 'YOUR_CORP_ID',
      corp_secret = 'YOUR_CORP_SECRET',
      agent_id = 'YOUR_AGENT_ID',
      user_id = 'YOUR_USER_ID',
    },
  },
})
```

{: .warning }
> API mode requires corporate approval and proper application setup.

---

## Commands

| Command               | Description                          |
| --------------------- | ------------------------------------ |
| `:Chat bridge wecom`  | Bind current session to WeCom        |

---

## Technical Details

- **API**: WeCom API
- **Authentication**: Access Token (auto-refresh)
- **Message Limit**: 2,048 characters
- **State Persistence**: `stdpath('data')/chat-wecom-state.json`

---

## Troubleshooting

### Webhook Not Working

**Symptom**: Webhook messages not being sent.

**Solution**:
1. Verify webhook key is correct
2. Check if the webhook robot is enabled
3. Test with a manual webhook request

### API Authentication Errors

**Symptom**: Cannot authenticate with WeCom API.

**Solution**:
1. Verify corp_id and corp_secret are correct
2. Check if the application is approved
3. Verify agent_id is correct

---

## Next Steps

- [Discord Integration](/docs/integrations/discord/) - Setup Discord bot
- [Telegram Integration](/docs/integrations/telegram/) - Setup Telegram bot
- [IM Integration Overview](/docs/integrations/im/) - All IM integrations
