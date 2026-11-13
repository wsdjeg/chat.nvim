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
- **Markdown Rendering**: Replies arrive as interactive cards, not raw markup
- **Access Control**: Whitelist / blacklist by `open_id`, manageable from the chat
- **Private Chat (P2P)**: Talk to the bot in a 1:1 chat, no `@mention` needed
- **Multi-chat**: Several groups and private chats polled side by side, each
  with its own message cursor and optional session binding
- **Isolated Workspaces**: Every private chat gets its own working directory, so
  two peers never share a file tree
- **Shared App**: The same credentials power the `bitable`, `lark_sheets` and
  `lark_docx` tools

---

## Setup Guide

Five steps in the Lark open platform, then one local config:

1. Create a custom app → get `App ID` / `App Secret`
2. Enable the **bot** capability
3. Add permissions
4. Publish and release a version (needs admin approval)
5. Add the bot to a chat and read the `chat_id`
6. Configure chat.nvim

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

| Permission             | What it is used for                              |
| ---------------------- | ------------------------------------------------ |
| `im:message`           | Send messages and read messages the bot receives |
| `im:message.group_msg` | Read messages in groups (the polling endpoint)   |

`im:message.group_msg` is a **sensitive** scope: the tenant admin has to
approve it. This is the single most common reason a fresh app replies nothing
— the scope exists but is still pending approval.

Two optional scopes, needed only for specific features:

| Permission                 | When it is needed                                         |
| -------------------------- | --------------------------------------------------------- |
| `im:chat` (readonly)       | Listing the chats the bot joined, to find a `chat_id`     |
| `contact:user.id:readonly` | Resolving ACL entries written as email / mobile to `open_id` |

Scopes for the document tools live in [Lark Tools](#lark-tools-sharing-one-app)
below. The exact scope names can differ slightly between tenants: if a name is
not listed in your console, search the keyword part (`im:message`, `contact`,
`bitable`, `sheet`, `docx`) and check the requirement in the
[API Explorer](https://open.feishu.cn/api-explorer).

### 4. Publish and release a version

Scopes only take effect after a version is released and approved:

1. App → **Version Management & Release** (版本管理与发布)
2. **Create version** → fill in the version number and changelog
3. Set **Availability** (可用范围) — who in the tenant may use the app
4. Submit for release; an admin approves it in the admin console
   (管理员后台 → 应用管理 → 待审批)

After approval, reopening the permission page shows the scopes as **enabled**.
Editing scopes later requires a new version — this is why "I added the
permission but it still fails" usually means *version not re-published*.

### 5. Add the bot to a chat and get the `chat_id`

1. In Lark, open the target group → **Settings** (群设置) →
   **Bots** (群机器人) → **Add bot** → pick your app
2. Send a message in the group that `@mentions` the bot
3. Read the `chat_id` (`oc_xxxxxxxx`):

- **API Explorer (simplest)**: call `GET /open-apis/im/v1/chats` in
  https://open.feishu.cn/api-explorer — every chat the bot joined is listed
  with its `chat_id`
- **Runtime log**: after one `@mention`, print the raw payloads with
  `:lua vim.print(require('chat.log').view_all())`

{: .info }

> `chat_id` starts with `oc_`. A user `open_id` (`ou_...`) or the chat's
> display name is **not** a substitute. For a one-to-one chat, the `oc_` id is
> created on first contact — read it from the first message payload.

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

Then bind the current session with `:Chat bridge lark`. ACL and the full option
list are in [Configuration Reference](#configuration-reference).

---

## Configuration Reference

| Option                            | Type       | Default       | Description                                      |
| --------------------------------- | ---------- | ------------- | ------------------------------------------------ |
| `integrations.lark.app_id`         | `string`   | —             | App ID, required                                 |
| `integrations.lark.app_secret`     | `string`   | —             | App Secret, required                             |
| `integrations.lark.chat_id`        | `string`   | —             | Target chat (`oc_...`), required                 |
| `integrations.lark.acl.mode`       | `string`   | `'allow_all'` | `allow_all` \| `whitelist` \| `blacklist`         |
| `integrations.lark.acl.whitelist`  | `string[]` | `{}`          | Users allowed to talk (whitelist mode)           |
| `integrations.lark.acl.blacklist`  | `string[]` | `{}`          | Users blocked (blacklist mode)                   |
| `integrations.lark.acl.admins`     | `string[]` | `{}`          | Users allowed to run `/allow`, `/deny` and `/acl` |
| `integrations.lark.p2p.allow`      | `string[]` | `{}`          | Users allowed to use private chat (default: deny) |
| `integrations.lark.p2p.greeting`   | `string`   | see below     | Text sent when a private chat is opened           |
| `integrations.lark.p2p.auto_create`| `boolean`  | `true`        | Open a private chat for allowed users on connect  |
| `integrations.lark.p2p.cwd_root`   | `string`   | first `allowed_path` | Root for per-chat p2p workspaces         |

Every ACL list accepts an `open_id` (`ou_...`), an email address, or a mobile
number. `open_id` entries cost zero API calls; email / mobile entries are
resolved once on connect and then cached. The same is true for `p2p.allow`.

`p2p.cwd_root` is where private-chat workspaces are created; leave it unset to
derive the root from `allowed_path`. See
[Isolated workspaces](#isolated-workspaces) for the details.

Complete example:

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
      p2p = {
        -- users allowed to open a private chat, deny by default.
        -- Omit this to fall back to acl.admins + acl.whitelist.
        allow = { 'ou_xxx' },
        -- text sent when a private chat is opened
        greeting = 'Hi, this is the chat.nvim bot. Reply here to talk to Neovim.',
        -- open a private chat for the allowed users on connect (default: true)
        auto_create = true,
        -- root for the per-chat workspaces (default: first allowed_path entry)
        -- each private chat works in <cwd_root>/lark-<chat_id>
        cwd_root = '/home/me/projects',
      },
    },
  },
})
```

---

## Commands

| Command             | Description                                        |
| ------------------- | -------------------------------------------------- |
| `:Chat bridge lark` | Bind the current session to the Lark chat           |
| `/allow @user`      | In-chat: grant the mentioned user access (admins)  |
| `/deny @user`       | In-chat: revoke access from the user (admins)      |
| `/acl`              | In-chat: reply with the current mode and id lists  |

The in-chat commands are recognised only when sent by a configured admin, and
only when the message `@mentions` the bot. Requests from non-admins are dropped
silently — no reply — so the group is not spammed.

`/allow` and `/deny` are written to the state file, so they survive restarts
without editing the config, and they take precedence over the configured
`acl.mode`: an admin can blacklist someone even while running in `allow_all`.

---

## Access Control (ACL)

By default everyone in the bound chat may talk to the bot. Set
`integrations.lark.acl` (see [the example above](#configuration-reference)) to
restrict who can trigger replies.

| Mode        | Behaviour                                              |
| ----------- | ------------------------------------------------------ |
| `allow_all` | Default. Everyone in the chat may talk to the bot.     |
| `whitelist` | Only the listed open_ids (plus admins) may talk to it. |
| `blacklist` | Everyone except the listed open_ids may talk to it.    |

Notes:

- **Admins always pass.** An admin bypasses the ACL, so a whitelist that
  locked them out can still be repaired from inside the group.
- **Recent speakers are cached.** Every non-bot speaker is recorded in the
  state file (up to 30, newest first) and exposed through
  `require('chat.integrations.lark').get_recent_senders()`, so open_ids can
  be picked instead of copied out of the open platform console.
- **Unresolved entries fail safely.** If an email / mobile cannot be resolved
  (missing permission or offline), it never matches: fail-closed for
  `admins` / `whitelist`, fail-open for `blacklist`. The failure is logged at
  connect time together with the affected entries.
- **App scope still applies.** The Lark admin console "app availability"
  setting is the outer, coarse-grained control; the ACL here is the fine one.

---

## Private Chat (P2P)

A private chat is a normal `oc_...` conversation, so it is polled exactly like
a group. Two things differ:

- **No `@mention` is required.** The message is addressed to the bot by
  definition, so `Skip message (not mention)` never applies.
- **Access is deny-by-default.** `acl.mode = 'allow_all'` is a statement about
  the bound group and does **not** let anyone in the tenant open a DM. Set
  `integrations.lark.p2p.allow`; when that list is absent,
  `acl.admins ∪ acl.whitelist ∪ runtime whitelist` is used instead.

### Opening a private chat

A polling bot cannot learn the `oc_` id of a p2p conversation from an incoming
message — there is no cursor for a conversation it does not know yet. So the
conversation is created from this side, through the API:

```lua
-- returns the p2p chat_id once the conversation exists
require('chat.integrations.lark').create_p2p('ou_xxxxxxxx', function(ok, result)
  if ok then
    print('p2p chat_id: ' .. result)
  end
end)
```

The call does three things:

1. sends `p2p.greeting` with `receive_id_type=open_id` (this is the message the
   user sees, nothing is sent twice)
2. reads that message back (`GET /im/v1/messages/{message_id}`) to obtain the
   `chat_id`
3. registers the container as `chat_type = 'p2p'`, so the poller starts reading
   it

`create_p2p` refuses an `open_id` that `p2p.allow` does not list, and returns
the existing `chat_id` when the conversation is already known (no greeting is
re-sent).

### Automatic provisioning

You normally do not have to call `create_p2p` yourself. On connect the
integration walks the curated allow-list and opens a p2p chat for everyone in
it that does not have one yet:

| Source                                  | Provisioned |
| --------------------------------------- | ----------- |
| `p2p.allow` when set                    | yes         |
| otherwise `acl.admins`                  | yes         |
| `acl.whitelist` (the wider fallback)    | no          |

`acl.whitelist` is excluded on purpose: provisioning *sends a greeting*, so a
long whitelist would be spammed on every connect. Those users can still open
the chat themselves.

`/allow @user` also provisions immediately, so a freshly granted admin can DM
the bot without waiting for a restart.

Every provisioned container gets its own session (`lark-<chat_id>`) right
away, so the private chat has its own context from the first message.

`integrations.lark.p2p.auto_create = false` turns automatic provisioning off —
`create_p2p` still works on demand.

```vim
" manually provision without restarting
:lua require('chat.integrations.lark').provision_p2p()
```

{: .info }

> Replies to a p2p chat are sent with `receive_id_type=open_id` to the
> registered peer, so the container id is only needed for *polling*. A message
> arriving in that container from anybody other than the registered peer is
> dropped.

### Isolated workspaces

A private chat is one person talking to the bot alone, so two peers must never
share a working directory: they would see each other's files, and one user's
edits — or a `git checkout` — would land in another user's tree.

Each p2p chat therefore works in `<cwd_root>/lark-<chat_id>`:

| Chat type | Working directory                          |
| --------- | ------------------------------------------ |
| group     | the Neovim cwd (deliberately shared)       |
| p2p       | `<cwd_root>/lark-<chat_id>`                 |

`cwd_root` comes from `integrations.lark.p2p.cwd_root`; when that is unset the
first `allowed_path` entry is used. The fallback is deliberate — a workspace
outside `allowed_path` would be refused by every file tool, and keeping the root
inside the allowed tree means the isolation never widens what the bot may touch.
With neither configured the workspace is skipped and the session keeps the
Neovim cwd, which is what older versions always did.

The directory is created while the session is provisioned, because `read_file`,
`find_files` and the git tools all reject a missing directory.

{: .info }

> The directory only applies **once**, when the session is created. Re-binding a
> chat to an existing session keeps it in the directory it already has, so a live
> workspace is never moved under the running request. To relocate a chat, delete
> its session first.

The name is sanitized to a single path segment, so an unexpected `chat_id` can
not escape the root.

### Multiple chats at once

Every chat keeps its own message cursor, so an active group can no longer
starve a quiet private chat (a single shared `start_time` used to skip it).
Chats are polled **sequentially**, one request at a time.

The cached cursor is **reset to "now" on every start**, before the first poll
and immediately written back to the state file. The cursor records where the
previous run stopped, not a backlog to replay: resuming from an hours-old
`start_time` would make the first tick fetch everything sent while the plugin
was down and answer it in one burst. Only messages arriving after the plugin
started are considered; ids left over from the previous session stay in
`processed_ids`, so the boundary between runs is still guarded.

Bindings are per chat as well: `/session` inside a chat binds that chat only,
while `:Chat bridge lark` keeps its platform-level meaning and addresses the
configured `chat_id`.

Unbinding a session clears both levels — the platform-level binding and every
per-chat binding pointing at that session — so a p2p chat cannot keep answering
after `:Chat unbridge lark` reported success.

A binding whose session was deleted is dropped and recreated on next use rather
than returned: the conversation keeps its stable derived id (`lark-<chat_id>`),
so it resumes with a working session instead of silently writing replies into a
session that no longer exists. Bindings set by hand to a session this module did
not derive are left untouched.

---

## Lark Tools Sharing One App

The credentials under `integrations.lark` are reused by the Lark tools, so a
single app serves both chat and document automation. Enable the scope only for
the tools you actually use, then release a new version:

| Tool          | Scope                | Documents                              |
| ------------- | -------------------- | -------------------------------------- |
| `bitable`     | `bitable:app`        | [bitable](../tools/bitable.md)         |
| `lark_sheets` | `sheets:spreadsheet` | [lark_sheets](../tools/lark_sheets.md) |
| `lark_docx`   | `docx:document`      | [lark_docx](../tools/lark_docx.md)     |

---

## Technical Details

- **API**: Lark Open API (`https://open.feishu.cn/open-apis`), `tenant_access_token`
  authentication refreshed 5 minutes before expiry and shared with the tools
- **Polling**: every 3 seconds, `page_size=50`, newest first, using `start_time`
  from the last seen message. Each chat (group or p2p) keeps its **own**
  cursor, and chats are polled one request at a time
- **Reply Trigger**: in groups the bot only answers when `@mentioned`
  (`mentions[].id` equals the bot `open_id`); in a p2p chat no mention is
  required
- **Working Directory**: a p2p session starts in `<cwd_root>/lark-<chat_id>`
  (see [Isolated workspaces](#isolated-workspaces)); groups keep the Neovim cwd
- **Message Limit**: 30,720 characters per chunk; longer replies are split
- **Message Format**: interactive card (schema 2.0) with a `markdown` element
- **State Persistence**: `stdpath('data')/chat.nvim/integration/lark.json`
  (respects `storage_dir` when set) — holds the per-chat cursors and session
  bindings, runtime ACL entries, recent senders and the resolved identity cache.
  A state file written by an older version (no `containers` key) still loads:
  the configured `chat_id` becomes the single container, resuming at the old
  `last_message_time`

---

## Troubleshooting

### The bot never replies

Check in the order failures actually happen:

1. **Bot capability enabled?** (Step 2) — without it no message is delivered.
2. **`im:message.group_msg` approved?** A sensitive scope needs admin sign-off;
   "added but not approved" looks identical to "not added".
3. **Version released after the scope change?** Scopes are frozen per version.
4. **Bot added to the chat?** It must be a member of the conversation.
5. **Did the message `@mention` the bot?** Mentions are required in groups.
6. **`chat_id` correct (`oc_...`)?** A user `open_id` or a chat name will be
   accepted by the config but silently fetches nothing.
7. **Sender passes the ACL?** `allow_all` by default, so this is rare.

Then read the log — it names the actual cause:

```vim
:lua vim.print(require('chat.log').view_all())
```

Look for `[Lark] Skip fetch`, `[Lark] Skip send` or `skip message` lines.

### A private chat gets no reply

p2p is deny-by-default, so a silent chat is usually the expected behaviour:

1. **Is the sender in `p2p.allow`?** A missing list falls back to
   `acl.admins ∪ acl.whitelist`; an explicit list is the whole policy
2. **Was the conversation ever opened?** The `oc_` id is only known after
   `create_p2p()` — or after automatic provisioning on connect — and an
   unknown chat is never polled. `p2p.auto_create = false` disables the
   automatic path, so only a manual `create_p2p()` registers the chat
3. **Did the greeting go out?** Look for a `[Lark] Skip send` /
   `[Lark] Skip fetch` line with the `receive_id_type=open_id` request, or a
   `[Lark] p2p provisioning skipped (<open_id>)` debug line
4. **Is the polled container id the same one?** `get_containers()` lists every
   chat the bot reads; a p2p entry must carry `chat_type = 'p2p'`

`[Lark] Skip p2p message (peer not allowed)` and
`[Lark] p2p sender mismatch` name a rejected message directly.

### File tools refuse the p2p workspace

The workspace must live inside `allowed_path`, otherwise the file tools reject
every path in it:

1. **Is `p2p.cwd_root` (or the first `allowed_path`) pointing at the right
   place?** The session works in `<cwd_root>/lark-<chat_id>`
2. **Look for `[Lark] Could not create workspace`** — an unwritable root falls
   back to the Neovim cwd instead
3. **Was the session created before `cwd_root` was set?** The directory is only
   applied at creation; delete the session so the next message provisions it
   again

### Authentication errors

**Symptom**: Cannot authenticate with Lark API (`Invalid access token`).

**Solution**:

1. Verify `app_id` and `app_secret` are correct (the secret is shown only once;
   regenerate it if lost)
2. Confirm the app is released and approved
3. Read the log for the token response — transport failures (DNS, TLS, proxy)
   are reported separately from API errors, and a silent curl failure leaves an
   empty response body

### Missing scope

**Symptom**: `no permission` or code `1254005` in the response body.

**Solution**: enable the scope, then **create and release a new version**.
Permissions never apply retroactively to an existing version.

### An ACL user never matches

**Solution**:

1. Prefer `open_id` (`ou_...`) — it needs no lookup
2. If you used an email / mobile, enable `contact:user.id:readonly` and
   reconnect; the cache only resolves on connect
3. Compare the logged `unresolved ACL entries` list against the config
4. Make sure the message really comes from that user — app (bot) messages are
   skipped before the ACL is checked

---

## Next Steps

- [Discord Integration](./discord/) - Setup Discord bot
- [Telegram Integration](./telegram/) - Setup Telegram bot
- [IM Integration Overview](./) - All IM integrations
</Content>

