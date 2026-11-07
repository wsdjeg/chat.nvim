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

Lark/Feishu (飞书) integration for enterprise communication.

## Features

- **Bidirectional Communication**: Send and receive messages via Lark bot
- **Session Binding**: Bind Lark chats to chat.nvim sessions
- **Automatic Polling**: Polls for new messages every 3 seconds
- **Long Message Support**: Handles messages up to 30,720 characters per chunk
- **Rich Message Support**: Replies are sent as interactive cards with markdown
- **Access Control**: Whitelist / blacklist by `open_id`, manageable from the chat
- **Shared Credentials**: The same app powers the `bitable`, `lark_sheets` and
  `lark_docx` tools

---

## Setup Guide

The whole setup takes four steps in the Lark open platform plus one local config:

1. Create a custom app → get `App ID` / `App Secret`
2. Enable the **bot** capability
3. Add permissions and publish a version (with admin approval)
4. Add the bot to a group and read the `chat_id`
5. Configure chat.nvim

{: .info }

> chat.nvim **polls** the Lark Open API. You do **not** need to configure
> "Event Subscriptions" (事件订阅) or a request URL in the developer console —
> leave those empty.

### 1. Create the app

- Open https://open.feishu.cn/app
- Click **Create custom app** (创建企业自建应用)
- Fill in a name and description, then submit
- Open the app → **Credentials & Basic Info** (凭证与基础信息)
- Copy **App ID** (`cli_xxxxxxxx`) and **App Secret**

{: .warning }

> Keep `app_secret` secure. Never commit it to version control — prefer an
> `env` var or a local file that is git-ignored.

### 2. Enable the bot capability

The integration talks to the chat through a bot, so the capability must be on:

1. App → **Add app capability** (添加应用能力)
2. Enable **Bot** (机器人)
3. Optionally set a bot name and avatar — this is what users see in the group

Without this step the bot info call returns no bot and messages sent to the
chat fail with a "bot not available" style error.

### 3. Add permissions

App → **Permissions & Scopes** (权限管理) → search and enable:

#### Required for the IM integration

| Permission                     | What it is used for                               |
| ------------------------------ | ------------------------------------------------- |
| `im:message`                   | Send messages and read messages the bot receives  |
| `im:message.group_msg`         | Read messages in groups (the polling endpoint)     |

`im:message.group_msg` is a **sensitive** scope: the tenant admin has to
approve it. This is the single most common reason a fresh app replies nothing
— the scope exists but is still pending approval.

#### Optional — only when a feature is used

| Permission                            | Feature                                                    |
| ------------------------------------- | ---------------------------------------------------------- |
| `im:chat` (readonly is enough)        | Listing chats to find a `chat_id` from the console         |
| `contact:user.id:readonly`            | Resolving ACL entries written as email / mobile to `open_id` |
| `bitable:app`                          | `bitable` tool (Bitable / 多维表格)                        |
| `sheets:spreadsheet`                   | `lark_sheets` tool (Sheets / 电子表格)                     |
| `docx:document`                        | `lark_docx` tool (Docs / 云文档)                           |

Notes:

- **`open_id`-only ACL configs need no contact permission.** Resolution only
  happens when you write email addresses or mobile numbers in
  `acl.admins` / `acl.whitelist` / `acl.blacklist`.
- The exact scope names can differ slightly between tenants. If a name above
  is not listed in your console, search for the keyword part (`im:message`,
  `bitable`, `sheet`, `docx`, `contact`) and check the API in the
  [API Explorer](https://open.feishu.cn/api-explorer) for its requirement.

### 4. Publish a version

Scopes only take effect after a version is released and approved:

1. App → **Version Management & Release** (版本管理与发布)
2. **Create version** → fill in the version number and changelog
3. Set **Availability** (可用范围) — who in the tenant may use the app
4. Submit for release; an admin approves it in the admin console
   (管理员后台 → 应用管理 → 待审批)

After approval, reopening the permission page shows the scopes as **enabled**.
Editing scopes later requires a new version — this is why "I added the
permission but it still fails" usually means *version not re-published*.

### 5. Add the bot to a group and get the `chat_id`

1. In Lark, open the target group → **Settings** (群设置) →
   **Bots** (群机器人) → **Add bot** → pick your app
2. Send a message in the group that `@mentions` the bot
3. Read the `chat_id` (`oc_xxxxxxxx`) with one of:

**a. API Explorer (simplest)**

In https://open.feishu.cn/api-explorer call
`GET /open-apis/im/v1/chats` — every group the bot joined is listed with its
`chat_id`.

**b. Message content in logs**

Enable debug logging and `@mention` the bot once; the raw message payload
carries `chat_id` (`oc_...`).

**c. chat.nvim's runtime log**

```vim
:lua vim.print(require('chat.log').view_all())
```

{: .info }

> `chat_id` starts with `oc_`. Do **not** use the `open_id` (`ou_...`) of a
> user or the chat's display name — only the `oc_` value identifies a chat.
> For a one-to-one conversation, the `chat_id` is the p2p chat id, obtained the
> same way (`im/v1/chats` with `user_id_type` filtering, or from the first
> message payload).

### 6. Configure chat.nvim

```lua
require('chat').setup({
  integrations = {
    lark = {
      app_id = 'cli_xxxxxxxxxxxx',
      app_secret = 'YOUR_APP_SECRET',
      chat_id = 'oc_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx',
    },
  },
})
```

Then bind the current session:

```vim
:Chat bridge lark
```

---

## Configuration Reference

| Option                        | Type       | Default       | Description                                                 |
| ----------------------------- | ---------- | ------------- | ----------------------------------------------------------- |
| `integrations.lark.app_id`     | `string`   | —             | App ID, required                                            |
| `integrations.lark.app_secret` | `string`   | —             | App Secret, required                                        |
| `integrations.lark.chat_id`    | `string`   | —             | Target chat (`oc_...`), required                            |
| `integrations.lark.acl.mode`   | `string`   | `'allow_all'` | `allow_all` \| `whitelist` \| `blacklist`                    |
| `integrations.lark.acl.whitelist` | `string[]` | `{}`      | Users allowed to talk (whitelist mode)                      |
| `integrations.lark.acl.blacklist` | `string[]` | `{}`      | Users blocked (blacklist mode)                              |
| `integrations.lark.acl.admins`    | `string[]` | `{}`      | Users allowed to run `/allow`, `/deny`, `/acl`              |

All three ACL lists accept an `open_id` (`ou_...`), an email address, or a
mobile number. `open_id` entries cost zero API calls; email / mobile entries
are resolved through the contact API on connect and then cached.

Full example:

```lua
require('chat').setup({
  integrations = {
    lark = {
      app_id = 'cli_xxxxxxxxxxxx',
      app_secret = 'YOUR_APP_SECRET',
      chat_id = 'oc_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx',
      acl = {
        -- allow_all (default) | whitelist | blacklist
        mode = 'whitelist',
        -- users allowed to talk to the bot (whitelist mode)
        whitelist = { 'ou_xxx', 'nova@example.com' },
        -- users blocked from the bot (blacklist mode)
        blacklist = {},
        -- users allowed to run /allow, /deny and /acl
        admins = { 'ou_admin' },
      },
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

- **open_id is the safest form.** It cannot be forged the way a display name
  can. Email / mobile entries are resolved once and then compared as
  `open_id`.
- **Admins always pass.** An admin bypasses the ACL, so a whitelist that
  locked them out can still be repaired from inside the group.
- **Runtime entries win.** IDs granted or revoked via `/allow` and `/deny`
  override the configured `mode`; config lists and runtime lists are merged
  by `:Chat`-side helpers such as `lark.get_acl()`.
- **Recent speakers are cached.** Every non-bot speaker is recorded in the
  state file (up to 30, newest first) and exposed through
  `require('chat.integrations.lark').get_recent_senders()`, so open_ids can
  be picked instead of copied out of the open platform console.
- **Unresolved entries fail safely.** If an email / mobile cannot be resolved
  (missing permission or offline), it never matches: fail-closed for
  `admins` / `whitelist`, fail-open for `blacklist`. The failure is logged at
  connect time together with the affected entries.
- **App scope still applies.** The Lark admin console "app availability"
  setting is the outer, coarse-grained control; the ACL here is the fine
  one.

---

## Tools Sharing the Same App

The credentials under `integrations.lark` are reused by the Lark tools, so a
single app serves both chat and document automation. Add the matching scope
only for the tools you actually enable:

| Tool         | Scope                | Documents                      |
| ------------ | -------------------- | ------------------------------ |
| `bitable`    | `bitable:app`        | [bitable](../tools/bitable.md) |
| `lark_sheets`| `sheets:spreadsheet` | [lark_sheets](../tools/lark_sheets.md) |
| `lark_docx`  | `docx:document`      | [lark_docx](../tools/lark_docx.md) |

The `tenant_access_token` is cached once and shared between the IM integration
and all three tools.

---

## Technical Details

- **API**: Lark Open API (`https://open.feishu.cn/open-apis`)
- **Authentication**: Tenant Access Token (auto-refresh, refreshed 5 minutes
  before expiry)
- **Polling**: every 3 seconds, `page_size=50`, newest first, using
  `start_time` from the last seen message
- **Reply Trigger**: in groups the bot only answers when `@mentioned`
  (`mentions[].id` equals the bot `open_id`)
- **Message Limit**: 30,720 characters per chunk; longer replies are split
- **Message Format**: Replies are sent as an interactive card (schema 2.0) with a
  `markdown` element, so markdown in AI replies renders in Lark clients instead of
  showing raw markup
- **State Persistence**: `stdpath('data')/chat.nvim/integration/lark.json`
  (respects `storage_dir` when set) — holds the last message cursor, runtime
  ACL entries, recent senders and the resolved identity cache

---

## Troubleshooting

### Nothing happens, no reply at all

Checklist, in the order the failures actually happen:

1. **Bot capability enabled?** (Step 2) — without it no message is delivered.
2. **`im:message.group_msg` approved?** A sensitive scope needs admin sign-off;
   "added but not approved" looks identical to "not added".
3. **Version released after the scope change?** Scopes are frozen per version.
4. **Bot added to the group?** It must be a member of the chat.
5. **Did the message `@mention` the bot?** Mentions are required in groups.
6. **`chat_id` correct (`oc_...`)?** A user `open_id` or a group name will be
   accepted by the config but silently fetches nothing.

Verify the plumbing:

```vim
:lua vim.print(require('chat.log').view_all())
```

Look for `[Lark] Skip fetch`, `[Lark] Skip send` or `skip message` lines — they
carry the real reason.

### Invalid access token / 99991663-style errors

**Symptom**: Cannot authenticate with Lark API.

**Solution**:

1. Verify `app_id` and `app_secret` are correct (secret is shown only once;
   regenerate it if lost)
2. Confirm the app is released and approved
3. Check the log for the token request body — transport errors (DNS, TLS,
   proxy) are reported separately from API errors

### Missing scope (1254005-style errors)

**Symptom**: `no permission` / `1254005` in the response body.

**Solution**: enable the scope, then **create and release a new version**.
Permissions never apply retroactively to an existing version.

### Message delivery issues

**Symptom**: Messages not being delivered.

**Solution**:

1. Verify `chat_id` is correct
2. Check if the bot has proper permissions
3. Ensure the bot is added to the chat/group
4. Check that the sender passes the ACL (`allow_all` by default)

### ACL user never matches

**Symptom**: A whitelisted colleague is still ignored.

**Solution**:

1. Prefer `open_id` (`ou_...`) — it needs no lookup
2. If you used an email / mobile, enable `contact:user.id:readonly` and
   reconnect; the cache resolves on connect
3. Compare the logged `unresolved ACL entries` list against the config
4. Check whether the person is in fact the sender (bots skip app messages)

---

## Next Steps

- [Discord Integration](./discord/) - Setup Discord bot
- [Telegram Integration](./telegram/) - Setup Telegram bot
- [IM Integration Overview](./) - All IM integrations
</FileContent>

