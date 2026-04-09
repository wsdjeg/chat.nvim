---
layout: default
title: recall_memory
parent: Tools
nav_order: 4
---

# recall_memory

{: .no_toc }

Retrieve relevant information from the three-tier memory system with priority-based ranking. Automatically extracts keywords if no query is provided.

## Usage

```
@recall_memory <parameters>
```

## Memory Priority Order

1. ⚡ **Working Memory** - Current session tasks/decisions (highest priority)
2. 📅 **Daily Memory** - Recent temporary information (medium priority)
3. 💾 **Long-term Memory** - Permanent knowledge base (normal priority)

## Examples

- `@recall_memory query="vim configuration"` - Search all memory types
- `@recall_memory` - Auto-extract keywords from current conversation
- `@recall_memory query="current task" memory_type="working"` - Search only working memory
- `@recall_memory query="today" memory_type="daily"` - Search only daily memory
- `@recall_memory query="python" memory_type="long_term"` - Search only long-term memory

## Parameters

| Parameter      | Type    | Description                                                                |
| -------------- | ------- | -------------------------------------------------------------------------- |
| `query`        | string  | Search query (optional, auto-extracted from last message if not provided)  |
| `memory_type`  | string  | Filter by memory type: `"working"`, `"daily"`, or `"long_term"` (optional) |
| `limit`        | integer | Number of results (default: 5, maximum: 10)                                |
| `all_sessions` | boolean | Search all sessions instead of just current (default: false)               |

## Notes

{: .info }

> - Returns formatted memory list that AI can reference for responses
> - Searches across all memory types with priority ranking
> - Working memory has highest priority and session isolation
> - Daily memory shows expiration countdown
> - Long-term memory shows access frequency
> - Useful for maintaining context across conversations

