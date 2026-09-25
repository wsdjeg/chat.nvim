---
layout: default
title: mastodon
parent: Tools
nav_order: 48
---

# mastodon

Read-only Mastodon access: fetch toots and whole threads, search statuses/accounts/hashtags, and read public or hashtag timelines. Uses the public Mastodon REST API with GET requests only — it never posts, boosts, or favourites anything.

## Usage

```
@mastodon action="fetch" url="<toot URL>" [context=true]
@mastodon action="search" query="<query>" [type="statuses|accounts|hashtags"] [limit=20]
@mastodon action="timeline" timeline="public|tag:<hashtag>" [local=true] [limit=20]
```

## Examples

- `@mastodon action="fetch" url="https://mastodon.social/@gargron/109307870061423362"` - Fetch one toot
- `@mastodon action="fetch" url="https://mastodon.social/@gargron/109307870061423362" context=true` - Fetch the whole thread (ancestors + replies)
- `@mastodon action="fetch" id="123456" instance="https://fosstodon.org"` - Fetch by status ID on a specific instance
- `@mastodon action="search" query="neovim" type="statuses"` - Search statuses
- `@mastodon action="search" query="gargron" type="accounts"` - Search accounts
- `@mastodon action="timeline" timeline="public" instance="https://fosstodon.org"` - Read another instance's public timeline
- `@mastodon action="timeline" timeline="public" local=true` - Local-only public timeline
- `@mastodon action="timeline" timeline="tag:neovim" limit=40` - Hashtag timeline

## Actions

| Action | Description | Key parameters |
| ------ | ----------- | -------------- |
| `fetch` | Get a single toot by URL or ID, optionally with the whole thread | `url`, `id`, `context` |
| `search` | Search statuses, accounts, or hashtags | `query`, `type`, `limit` |
| `timeline` | Read the public timeline or a hashtag timeline | `timeline`, `local`, `limit` |

## Parameters

| Parameter | Type | Description |
| --------- | ---- | ----------- |
| `action` | string | Required. One of: `fetch`, `search`, `timeline` |
| `url` | string | Toot URL (fetch). The instance from the URL is used automatically. Format: `https://<instance>/@<user>/<status_id>` |
| `id` | string | Numeric status ID (fetch alternative to `url`). Requires `instance` |
| `context` | boolean | Fetch the whole thread: ancestors and replies (fetch) |
| `query` | string | Search query (search) |
| `type` | string | What to search for (search): `statuses`, `accounts` or `hashtags`. Omit to search all |
| `timeline` | string | Timeline to read (timeline): `public` or `tag:<hashtag>` e.g. `tag:neovim` |
| `local` | boolean | Restrict timeline to local (same-instance) toots only (timeline) |
| `instance` | string | Instance override, e.g. `https://fosstodon.org` or `fosstodon.org` |
| `limit` | integer | Max results for search/timeline (default: 20, max: 40) |
| `access_token` | string | Access token override for authenticated endpoints |
| `timeout` | integer | Timeout in seconds (default: 30, min: 1, max: 300) |

## Configuration

The default instance can be configured globally:

```lua
require('chat').setup({
  mastodon = {
    instance = 'https://mastodon.social',  -- default instance
    access_token = '',                     -- optional, see below
  },
})
```

{: .info }
> - `fetch` and `timeline` work without authentication on most instances (some instances restrict unauthenticated timeline access)
> - `search` requires an access token on most instances. Create one in your instance's Preferences → Development → New application (scope: `read`), then set `mastodon.access_token`
> - On authentication errors the tool returns a hint to configure the token
> - Requires `curl` to be installed and available in PATH

