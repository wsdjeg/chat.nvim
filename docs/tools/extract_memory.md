---
layout: default
title: extract_memory
parent: Tools
nav_order: 3
---

# extract_memory

{: .no_toc }

Extract memories from conversation text into a three-tier memory system (working, daily, long-term). Automatically detects memory type and category based on content analysis.

## Usage

```
@extract_memory <parameters>
```

## Memory Types

| Type        | Icon | Lifetime     | Priority | Use Case                                   |
| ----------- | ---- | ------------ | -------- | ------------------------------------------ |
| `working`   | ⚡   | Session only | Highest  | Current tasks, decisions, active context   |
| `daily`     | 📅   | 7-30 days    | Medium   | Short-term goals, today's tasks, reminders |
| `long_term` | 💾   | Permanent    | Normal   | Facts, preferences, skills, knowledge      |

## Examples

- `@extract_memory text="Python 的 GIL 是全局解释器锁，我习惯用 Vim 写代码"` (auto-detect type and category)
- `@extract_memory text="今天要完成用户登录功能" memory_type="daily"` (force daily memory)
- `@extract_memory text="当前正在修复登录 bug" memory_type="working"` (force working memory)

## Parameters

| Parameter     | Type   | Description                                                                            |
| ------------- | ------ | -------------------------------------------------------------------------------------- |
| `text`        | string | Text to analyze for memory extraction                                                  |
| `memories`    | array  | Pre-extracted memories array (alternative to `text` parameter)                         |
| `memory_type` | string | Memory type: `"long_term"`, `"daily"`, or `"working"` (auto-detected if not set)       |
| `category`    | string | Category: `"fact"`, `"preference"`, `"skill"`, or `"event"` (auto-detected if not set) |

## Category Definitions

- **fact**: Verifiable objective facts, data, definitions, rules
- **preference**: Personal habits, routine behaviors, regular practices
- **skill**: Technical abilities and knowledge
- **event**: Specific events and occurrences

## Auto-Detection Rules

The system automatically detects memory type based on keywords:

- **Working Memory**: "当前/正在/current", "任务/task", "决策/decision", "问题/issue"
- **Daily Memory**: "今天/明天/today/tomorrow", "待办/todo", "临时/temporary"
- **Long-term Memory**: Other persistent information

## Notes

{: .info }

> - Extracts only persistent and reusable information
> - Automatically detects categories and memory types based on keywords
> - Working memory has highest priority and is cleared when session ends
> - Daily memory expires after configured retention days (default: 7)
> - Long-term memory persists permanently
> - Memory system must be enabled in chat.nvim configuration

