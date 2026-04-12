---
layout: default
title: Lark Integration
parent: IM Integration
nav_order: 4
---

<!-- prettier-ignore-start -->
# Lark (Feishu) Integration
{: .no_toc }
## Table of contents
{: .no_toc }
<!-- prettier-ignore-end -->

<!-- prettier-ignore -->
- content
{:toc}

---

Lark/Feishu integration for enterprise communication.

## Features

- **Bidirectional Communication**: Send and receive messages via Lark bot
- **Session Binding**: Bind Lark chats to chat.nvim sessions
- **Automatic Polling**: Polls for new messages every 3 seconds
- **Long Message Support**: Handles messages up to 30,720 characters
- **Rich Message Support**: Supports text, cards, and other message types

---

## Setup Guide

### 1. Create Lark App

- Go to https://open.feishu.cn/app
- Create a new custom app
- Copy **App ID** and **App Secret**

{: .warning }

> Keep your app credentials secure! Never share them or commit to version control.

### 2. Configure Bot Permissions

Required permissions:

- `im:message.group_msg` - Get all messages in groups (sensitive permission)
- `im:message` - Get and send messages in private chats and groups

{: .info }

> Sensitive permissions may require approval from your organization.

**Configuration steps**:

1. Go to your app → "Permissions & Scopes"
2. Search for and enable the required permissions above
3. For sensitive permissions, you may need to apply for approval

### 3. Get Chat ID

- Use Lark API or app to get your chat_id
- For group chats, use the group ID

{: .info }

> Chat IDs can be obtained from the Lark developer tools or API responses.

### 4. Configure chat.nvim

```lua
require('chat').setup({
  integrations = {
    lark = {
      app_id = 'YOUR_APP_ID',
      app_secret = 'YOUR_APP_SECRET',
      chat_id = 'YOUR_CHAT_ID',
    },
  },
})
```

---

## Commands

| Command             | Description                       |
| ------------------- | --------------------------------- |
| `:Chat bridge lark` | Bind current session to Lark chat |

---

## Technical Details

- **API**: Lark Open API
- **Authentication**: Tenant Access Token (auto-refresh)
- **Polling**: 3-second intervals
- **Message Limit**: 30,720 characters
- **State Persistence**: `stdpath('data')/chat-lark-state.json`

---

## Troubleshooting

### App Not Approved

**Symptom**: App lacks required permissions.

**Solution**:

1. Check if app needs approval for production use
2. Apply for required permissions in the app dashboard
3. Wait for organization approval

### Authentication Errors

**Symptom**: Cannot authenticate with Lark API.

**Solution**:

1. Verify app_id and app_secret are correct
2. Check if the app is properly configured
3. Verify tenant access token is being refreshed

### Message Delivery Issues

**Symptom**: Messages not being delivered.

**Solution**:

1. Verify chat_id is correct
2. Check if the bot has proper permissions
3. Ensure the bot is added to the chat/group

---

## Next Steps

- [Discord Integration](./discord/) - Setup Discord bot
- [Telegram Integration](./telegram/) - Setup Telegram bot
- [IM Integration Overview](./im/) - All IM integrations
