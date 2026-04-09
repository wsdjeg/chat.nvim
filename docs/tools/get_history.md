---
layout: default
title: get_history
parent: Tools
nav_order: 12
---

# get_history

{: .no_toc }

Get conversation history messages from the current session.

## Usage

```
@get_history [parameters]
```

## Examples

- `@get_history` - Get first 20 messages (default)
- `@get_history offset=20 limit=20` - Get messages 21-40
- `@get_history offset=0 limit=50` - Get first 50 messages (max)

## Parameters

| Parameter | Type    | Description                                           |
| --------- | ------- | ----------------------------------------------------- |
| `offset`  | integer | Starting index (0 = oldest message, default: 0)       |
| `limit`   | integer | Number of messages to retrieve (default: 20, max: 50) |

## Notes

{: .info }

> - Use this tool when you need to reference earlier messages not in current context window
> - Returns messages with their role, content, and timestamp
> - Maximum 50 messages per request
> - Useful for maintaining context across long conversations

