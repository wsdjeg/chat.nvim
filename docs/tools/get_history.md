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
- `@get_history offset=-10` - Get the last 10 messages (newest)
- `@get_history offset=0 limit=200` - Get first 200 messages (max)
- `@get_history search="error"` - Search for messages containing "error"
- `@get_history search="config" offset=0 limit=10` - First 10 messages matching "config"
- `@get_history max_bytes=8000` - Same range, smaller payload budget
- `@get_history offset=12 max_bytes=150000` - Continue from `next_offset` with a bigger budget

## Parameters

| Parameter   | Type    | Description                                                        |
| ----------- | ------- | ------------------------------------------------------------------ |
| `offset`    | integer | Starting index (0 = oldest message, default: 0). Negative counts back from the newest: `-1` is the newest message, `-20` the last 20. With `search`, it counts inside the matched set. The response echoes the resolved non-negative value |
| `limit`     | integer | Number of messages to retrieve (default: 20, max: 200)             |
| `search`    | string  | Filter messages by keyword (case-insensitive), matched against `content` **and** `reasoning_content`. Offset/limit apply to filtered results |
| `max_bytes` | integer | Byte budget for the returned JSON (default: `tools.get_history.default_max_bytes`, 32768; allowed up to `tools.get_history.max_bytes_limit`, 204800; hard floor 2048). Values `<= 0` fall back to the default |

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
  "next_message_index": 4,
  "required_bytes": 41209,
  "note": "Result capped at 32768 bytes. ...",
  "bytes": 31002
}
```

| Field                | Description                                                        |
| -------------------- | ------------------------------------------------------------------ |
| `total`              | Number of informational records in the session (conversation turns plus `error`/`notice` lines), after filtering out bookkeeping markers |
| `offset`             | Requested offset, resolved to a non-negative position (see [Pagination](#pagination)) |
| `limit`              | Requested (and clamped) limit                                      |
| `max_bytes`          | Effective byte budget (after defaulting/clamping)                  |
| `returned`           | Number of messages actually returned                               |
| `search`             | Echo of the search keyword (only when `search` is used)            |
| `total_matched`      | Match count when `search` is used                                  |
| `truncated`          | `true` when the byte budget cut the result                         |
| `next_offset`        | Pagination cursor: position in the working set to continue from    |
| `next_message_index` | Global message index of the entry at `next_offset` (see [Pagination](#pagination)) |
| `required_bytes`     | Exact budget that would have made the cut/dropped entry readable; omitted when it exceeds the ceiling (or when nothing was cut) |
| `note`               | Human-readable explanation of what was cut and how to continue. Also carries the empty-session and out-of-range messages |
| `bytes`              | Actual encoded size of this response                               |

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

### Pagination

Two numbering systems are exposed on purpose:

| Field                | Meaning                                                     |
| -------------------- | ----------------------------------------------------------- |
| `next_offset`        | Cursor inside the **working set** (all entries, or the matched ones when `search` is used). Pass it back as `offset` to continue |
| `next_message_index` | The **global** message index (`messages[].index`) of that same entry; stable across calls and unaffected by `search` |

They diverge as soon as bookkeeping markers are filtered out or `search`
narrows the set, so conflating them points at the wrong message. Each page
therefore reports both, and the global index for a given entry never
changes between calls.

A negative `offset` is resolved before pagination starts, and the echoed
`offset` is always the resolved non-negative value. That keeps the cursor
additive (`offset + limit`), which a relative value could not provide -
under `search` the relative position would also have to be re-derived
against a different set every call.

### Reading across the truncation boundary

When [context truncation](../configuration.md#context-window-configuration) is
active, the request the model sees no longer contains the older messages, but
the session history still does. This tool is how that history is read back, and
the `[Context Window Notice]` at the tail of the request already carries the
exact calls:

```text
[Context Window Notice]
Showing the latest 82 of 700 messages; the earlier 618 were truncated.
Continue backwards with `get_history`: a negative offset counts from the newest message.
- get_history(offset=-102, limit=20) — the 20 messages just before this window
- get_history(offset=-122, limit=20) — the 20 before those
```

Copying those examples verbatim reaches the truncated history with no
arithmetic on the caller's side. Two properties make the printed numbers
trustworthy:

- The counts share **one** coordinate space: `700` counts conversation messages
  only (system messages are excluded, and so are the bookkeeping markers this
  tool drops), so `82 + 618 = 700` always holds.
- The offsets count back from the **newest** message, so the first page ends
  immediately before the current window and each next page continues where the
  previous one stopped. Starting at `offset=0` instead would walk forward from
  the oldest message and answer the opposite question.

Resolving the first page by hand: a negative offset `-N` starts at entry
`total - N + 1`, so `-102` starts at message `599` of `700` and returns
`599-618` - the 20 messages directly before the window that begins at `619`.
The printed `limit` shrinks on the last page when fewer than a full page
remains, so it is never larger than what the range can supply.

{: .info }

> `error` and `notice` lines keep their slots in the working set - they are
> real information, see [Record kinds](#record-kinds) - while the notice counts
> conversation messages only. A page boundary can therefore sit an entry or two
> off when such lines exist near it; the `index` echoed on each returned
> message is the authoritative position, since it is global and unaffected by
> filtering.

### Truncation

A message that only partially fits is returned with its role, its original
`index`/`created`, and two extra fields:

| Field              | Description                                              |
| ------------------ | -------------------------------------------------------- |
| `content_truncated`| `true` when only the head of the content was returned      |
| `original_bytes`   | Encoded size of the original content before the cut       |

When an entry does not fit at all (or only partially), the response also
reports `required_bytes`: the exact budget a retry needs to read it whole.
The note names that number (`retry with max_bytes=NNNN`), so a follow-up
call can succeed on the first attempt instead of bisecting. When the
required budget exceeds `max_bytes_limit`, `required_bytes` is omitted and
the note says the entry does not fit under the ceiling - passing the value
anyway would be clamped back down and silently repeat the same result.

## Notes

{: .info }

> - Use this tool when you need to reference earlier messages not in current context window
> - Returns messages with their role, content, and timestamp
> - Maximum 200 messages per request
> - When `search` is provided, only messages whose `content` or `reasoning_content` contains the keyword (case-insensitive) are returned. This is the same predicate the HTTP `/sessions/{id}/search` endpoint uses
> - `offset` and `limit` apply to the filtered results when `search` is used
> - `offset=-20` returns the **last** 20 messages; an offset that overshoots the start clamps to 0. The response echoes the resolved position, so paging always continues forward
> - The result is capped by **bytes**, not just by message count: a single tool result (`read_file`, `fetch_web`, `git_diff`) can be hundreds of KB, and returning a screenful of them would overflow the very context window the tool is trying to help with. The count ceiling of 200 exists only to keep `offset` pagination finite; the byte budget normally binds first
> - When `truncated` is `true`, follow `note`/`next_offset`: pages continue forward, while a message cut mid-content (`content_truncated`, `original_bytes`) is re-read with the `required_bytes` budget
> - Both budget bounds are configurable via `tools.get_history` (`default_max_bytes`, `max_bytes_limit`). The built-in floor of 2048 bytes is not configurable: below it the response envelope itself stops fitting, and the effective ceiling is never lower than the default
> - Content is always cut at a UTF-8 boundary, so CJK text never turns into invalid bytes
> - Useful for maintaining context across long conversations

