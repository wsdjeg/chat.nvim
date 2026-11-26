---
layout: default
title: get_history
parent: Tools
nav_order: 12
---

# get_history

Get conversation history messages from the current session.

## Usage

```
@get_history [parameters]
```

## Examples

- `@get_history` - Get first 20 messages (default)
- `@get_history offset=20 limit=20` - Get messages 21-40
- `@get_history offset=0 limit=50` - Get first 50 messages (max)
- `@get_history search="error"` - Search for messages containing "error"
- `@get_history search="config" offset=0 limit=10` - First 10 messages matching "config"
- `@get_history max_bytes=8000` - Same range, smaller payload budget
- `@get_history offset=12 max_bytes=150000` - Continue from `next_offset` with a bigger budget

## Parameters

| Parameter   | Type    | Description                                                        |
| ----------- | ------- | ------------------------------------------------------------------ |
| `offset`    | integer | Starting index (0 = oldest message, default: 0)                    |
| `limit`     | integer | Number of messages to retrieve (default: 20, max: 50)              |
| `search`    | string  | Filter messages by keyword (case-insensitive), matched against `content` **and** `reasoning_content`. Offset/limit apply to filtered results |
| `max_bytes` | integer | Byte budget for the returned JSON (default: 32768, allowed: 2048-204800). Values `<= 0` fall back to the default |

## Response

Every branch - including an empty session or an out-of-range `offset` -
returns the same JSON shape, so callers never have to special-case a plain
text answer:

```json
{
  "total": 85,
  "offset": 0,
  "limit": 20,
  "max_bytes": 32768,
  "returned": 3,
  "messages": [
    {
      "index": 0,
      "kind": "message",
      "role": "user",
      "content": "...",
      "created": 1736490600
    }
  ],
  "truncated": true,
  "next_offset": 3,
  "note": "Result capped at 32768 bytes. ...",
  "bytes": 31002
}
```

| Field               | Description                                                        |
| ------------------- | ------------------------------------------------------------------ |
| `total`             | Number of informational records in the session (conversation turns plus `error`/`notice` lines), after filtering out bookkeeping markers |
| `offset`            | Requested offset                                                   |
| `limit`             | Requested (and clamped) limit                                      |
| `max_bytes`         | Effective byte budget (after defaulting/clamping)                  |
| `returned`          | Number of messages actually returned                            |
| `search`            | Echo of the search keyword (only when `search` is used)            |
| `total_matched`     | Match count when `search` is used                                  |
| `truncated`         | `true` when the byte budget cut the result                          |
| `next_offset`       | Position to continue from on the next call                          |
| `note`              | Human-readable explanation of what was cut and how to continue. Also carries the empty-session and out-of-range messages |
| `bytes`             | Actual encoded size of this response                               |

### Record kinds

The session history mixes conversation turns with UI-only records. Each
returned entry carries a `kind`:

| `kind`    | Meaning                                                                 |
| --------- | ----------------------------------------------------------------------- |
| `message` | A real conversation turn: `role` is `user`, `assistant` or `tool`       |
| `error`   | A UI-only failure line (cancelled request, API error). No `role`        |
| `notice`  | A UI-only notice line (api key rotation). No `role`                     |

Bookkeeping markers (the `on_complete`/usage entries appended after every
finished request) have neither role nor content; they are **not** returned
at all.

### Tool context

Tool calls are summarised down to the names that ran:

```json
{ "index": 4, "kind": "message", "role": "assistant", "tool_calls": ["read_file", "git_add"] }
{ "index": 5, "kind": "message", "role": "tool", "tool": "git_diff", "content": "..." }
```

Arguments are deliberately not included: the model wrote them, so they are
already in its context, and a single `read_file` call's arguments can be
hundreds of bytes. A tool result carries `tool` (the producing tool's name)
when the record has one; older caches that predate `tool_call_state` simply
omit the field.

### Truncation

A message that only partially fits is returned with its role, its original
`index`/`created`, and two extra fields:

| Field              | Description                                              |
| ------------------ | -------------------------------------------------------- |
| `content_truncated`| `true` when only the head of the content was returned      |
| `original_bytes`   | Encoded size of the original content before the cut       |

## Notes

{: .info }

> - Use this tool when you need to reference earlier messages not in current context window
> - Returns messages with their role, content, and timestamp
> - Maximum 50 messages per request
> - When `search` is provided, only messages whose `content` or `reasoning_content` contains the keyword (case-insensitive) are returned. This is the same predicate the HTTP `/sessions/{id}/search` endpoint uses
> - `offset` and `limit` apply to the filtered results when `search` is used
> - The result is capped by **bytes**, not just by message count: a single tool result (`read_file`, `fetch_web`, `git_diff`) can be hundreds of KB, and returning 50 of them would overflow the very context window the tool is trying to help with
> - When `truncated` is `true`, follow `note`/`next_offset`: pages continue forward, while a message cut mid-content (`content_truncated`, `original_bytes`) is re-read with a larger `max_bytes`
> - Content is always cut at a UTF-8 boundary, so CJK text never turns into invalid bytes
> - Useful for maintaining context across long conversations

