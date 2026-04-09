---
layout: default
title: DingTalk
nav_order: 5
parent: Integrations
---
# DingTalk Integration

{: .no_toc }

## Table of contents
{: .no_toc .text-delta }
1. TOC
{:toc}

---

DingTalk integration with webhook or API mode.

## Features

- **Two Modes**: Webhook (simple, one-way) or API (bidirectional)
- **Message Queue**: Sequential message processing
- **Long Message Support**: Auto-chunking for messages > 20,000 characters

---

## Modes

### Webhook Mode (Simple, One-Way)

Simplest setup, but only supports sending messages to DingTalk.

### API Mode (Advanced, Bidirectional)

Full bidirectional communication, requires enterprise app registration.

---

## Setup Guide

### Webhook Mode

1. Create a custom robot in DingTalk group
2. Copy the webhook URL
3. Configure:

```lua
require('chat').setup({
  integrations = {
    dingtalk = {
      webhook = 'https://oapi.dingtalk.com/robot/send?access_token=XXX',
    },
  },
})
```

{: .info }
> Webhook mode is the simplest setup but only supports one-way communication.

### API Mode

1. Create an enterprise internal app
2. Get AppKey and AppSecret
3. Configure:

```lua
require('chat').setup({
  integrations = {
    dingtalk = {
      app_key = 'YOUR_APP_KEY',
      app_secret = 'YOUR_APP_SECRET',
      conversation_id = 'YOUR_CONVERSATION_ID',
      user_id = 'YOUR_USER_ID',
    },
  },
})
```

{: .warning }
> API mode requires enterprise app registration and approval.

---

## Commands

| Command               | Description                          |
| --------------------- | ------------------------------------ |
| `:Chat bridge dingtalk` | Bind current session to DingTalk   |

---

## Technical Details

- **API**: DingTalk Open Platform API
- **Authentication**: Access Token (auto-refresh)
- **Message Limit**: 20,000 characters
- **State Persistence**: `stdpath('data')/chat-dingtalk-state.json`

---

## Troubleshooting

### Webhook Not Working

**Symptom**: Webhook messages not being sent.

**Solution**:
1. Verify webhook URL is correct
2. Check if the webhook is enabled
3. Test the webhook with a manual request

### API Authentication Errors

**Symptom**: Cannot authenticate with DingTalk API.

**Solution**:
1. Verify app_key and app_secret are correct
2. Check if the app is approved
3. Verify access token is being refreshed

---

## Next Steps

- [Discord Integration](/docs/integrations/discord/) - Setup Discord bot
- [Telegram Integration](/docs/integrations/telegram/) - Setup Telegram bot
- [IM Integration Overview](/docs/integrations/im/) - All IM integrations
