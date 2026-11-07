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

### In-chat commands

Admins listed in `integrations.lark.acl.admins` can manage access control
directly from the group by mentioning the bot. Requests from non-admins are
dropped silently - no reply - so the group is not spammed.

| Message          | Effect                                          |
| ---------------- | ----------------------------------------------- |
| `/allow @user`   | Grant the mentioned user access to the bot      |
| `/deny @user`    | Revoke access from the mentioned user           |
| `/acl`           | Reply with the current ACL mode and id lists    |

The `/allow` and `/deny` entries are written to the Lark state file, so they
survive restarts without editing the config. They take precedence over the
configured `acl.mode`, which means an admin can blacklist someone even while
running in `allow_all` mode.

---

## Access Control (ACL)

By default everyone in the bound chat may talk to the bot. Set
`integrations.lark.acl` to restrict who can trigger replies.

```lua
require('chat').setup({
  integrations = {
    lark = {
      app_id = 'YOUR_APP_ID',
      app_secret = 'YOUR_APP_SECRET',
      chat_id = 'YOUR_CHAT_ID',
      acl = {
        -- allow_all (default) | whitelist | blacklist
        mode = 'whitelist',
        -- open_id of users allowed to talk to the bot (whitelist mode)
        whitelist = { 'ou_xxx' },
        -- open_id of users blocked from the bot (blacklist mode)
        blacklist = {},
        -- open_id of users allowed to run /allow, /deny and /acl
        admins = { 'ou_admin' },
      },
    },
  },
})
```

| Mode        | Behaviour                                              |
| ----------- | ------------------------------------------------------ |
| `allow_all` | Default. Everyone in the chat may talk to the bot.     |
| `whitelist` | Only the listed open_ids (plus admins) may talk to it. |
| `blacklist` | Everyone except the listed open_ids may talk to it.    |

Notes:

- **open_id only.** Identifiers are matched against the Lark `open_id`
  (`ou_xxx`), which cannot be forged the way a display name can.
- **Admins always pass.** An admin bypasses the ACL, so a whitelist that
  locked them out can still be repaired from inside the group.
- **Runtime entries win.** IDs granted or revoked via `/allow` and `/deny`
  override the configured `mode`; config lists and runtime lists are merged
  by `:Chat`-side helpers such as `lark.get_acl()`.
- **Recent speakers are cached.** Every non-bot speaker is recorded in the
  state file (up to 30, newest first) and exposed through
  `require('chat.integrations.lark').get_recent_senders()`, so open_ids can
  be picked instead of copied out of the open platform console.
- **App scope still applies.** The Lark admin console "app availability"
  setting is the outer, coarse-grained control; the ACL here is the fine
  one.

---

## Technical Details

- **API**: Lark Open API
- **Authentication**: Tenant Access Token (auto-refresh)
- **Polling**: 3-second intervals
- **Message Limit**: 30,720 characters
- **Message Format**: Replies are sent as an interactive card (schema 2.0) with a
  `markdown` element, so markdown in AI replies renders in Lark clients instead of
  showing raw markup
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
- [IM Integration Overview](./) - All IM integrations
