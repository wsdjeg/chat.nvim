
---
layout: default
title: Memory System
parent: Usage Guide
nav_order: 3
---

# Memory System

{: .no_toc }

Three-tier memory system for context-aware conversations.

## Table of contents
{: .no_toc .text-delta }
1. TOC
{:toc}

---

chat.nvim implements a sophisticated three-tier memory system inspired by cognitive psychology. This system allows the AI to remember important information across conversations and sessions.

## Overview

The memory system consists of three types of memory, each with different lifetimes and priorities:

| Type      | Icon | Lifetime     | Priority | Use Case                                   |
| --------- | ---- | ------------ | -------- | ------------------------------------------ |
| Working   | ⚡   | Session only | Highest  | Current tasks, decisions, active context   |
| Daily     | 📅   | 7-30 days    | Medium   | Short-term goals, today's tasks, reminders |
| Long-term | 💾   | Permanent    | Normal   | Facts, preferences, skills, knowledge      |

---

## Memory Types

### 1. Working Memory ⚡

Working memory is session-scoped and has the highest priority. It's designed for:

- Current tasks and goals
- Active decisions
- Immediate context
- Temporary information needed during the session

**Characteristics:**
- Automatically cleared when the session ends
- Highest priority in retrieval
- Limited capacity (default: 20 memories per session)
- Priority weight multiplier: 2.0

### 2. Daily Memory 📅

Daily memory is temporary and auto-expires after a configured period. It's designed for:

- Today's tasks and reminders
- Short-term goals
- Temporary information
- Daily planning

**Characteristics:**
- Auto-deletes after retention period (default: 7 days)
- Medium priority in retrieval
- Medium capacity (default: 100 memories)
- Similarity-based search

### 3. Long-term Memory 💾

Long-term memory is permanent storage for knowledge and facts. It's designed for:

- Permanent knowledge
- Personal preferences
- Skills and expertise
- Important facts

**Characteristics:**
- Never expires (permanent storage)
- Normal priority in retrieval
- Large capacity (default: 500 memories)
- Similarity-based search
- Access frequency tracking

---

## Configuration

### Basic Configuration

```lua
require('chat').setup({
  memory = {
    enable = true,  -- Global memory system switch
  },
})
```

### Advanced Configuration

```lua
require('chat').setup({
  memory = {
    enable = true,
    
    -- Long-term memory: Permanent knowledge (never expires)
    long_term = {
      enable = true,
      max_memories = 500,           -- Maximum memories to store
      retrieval_limit = 3,          -- Maximum memories to retrieve per query
      similarity_threshold = 0.3,   -- Text similarity threshold (0-1)
    },
    
    -- Daily memory: Temporary tasks and goals (auto-expires)
    daily = {
      enable = true,
      retention_days = 7,           -- Days before auto-deletion
      max_memories = 100,           -- Maximum daily memories
      similarity_threshold = 0.3,
    },
    
    -- Working memory: Current session focus (highest priority)
    working = {
      enable = true,
      max_memories = 20,            -- Maximum working memories per session
      priority_weight = 2.0,        -- Priority multiplier (higher = more important)
    },
    
    -- Storage location
    storage_dir = vim.fn.stdpath('cache') .. '/chat.nvim/memory/',
  },
})
```

---

## Memory Categories

Each memory can be categorized into one of four types:

### fact
Verifiable objective facts, data, definitions, and rules.

**Examples:**
- "Python's GIL is the Global Interpreter Lock"
- "Lua uses 1-based indexing"
- "Vim's normal mode is for navigation"

### preference
Personal habits, routine behaviors, and regular practices.

**Examples:**
- "I prefer dark themes in my editor"
- "I use 2 spaces for indentation"
- "I like to write documentation first"

### skill
Technical abilities and knowledge.

**Examples:**
- "Proficient in Lua and Vimscript"
- "Experienced with Neovim plugin development"
- "Familiar with async programming patterns"

### event
Specific events and occurrences.

**Examples:**
- "Meeting scheduled for 3 PM today"
- "Deployed version 1.0 yesterday"
- "Completed code review last week"

---

## Using Memory Tools

### extract_memory

Extract memories from conversation text into the memory system.

**Basic Usage:**

```
@extract_memory text="Python 的 GIL 是全局解释器锁，我习惯用 Vim 写代码"
```

The system will automatically detect:
- Memory type (working, daily, long_term)
- Category (fact, preference, skill, event)

**Force Memory Type:**

```
@extract_memory text="今天要完成用户登录功能" memory_type="daily"
```

**Force Category:**

```
@extract_memory text="Python 的 GIL 是全局解释器锁" memory_type="long_term" category="fact"
```

### recall_memory

Retrieve relevant information from the memory system.

**Basic Search:**

```
@recall_memory query="vim configuration"
```

**Filter by Memory Type:**

```
@recall_memory query="current task" memory_type="working"
@recall_memory query="today" memory_type="daily"
@recall_memory query="python" memory_type="long_term"
```

**Auto-extract from Conversation:**

```
@recall_memory
```

---

## Auto-Detection Rules

The `@extract_memory` tool automatically detects memory type based on keywords:

### Working Memory Keywords

- "当前/正在/current"
- "任务/task"
- "决策/decision"
- "问题/issue"

### Daily Memory Keywords

- "今天/明天/today/tomorrow"
- "待办/todo"
- "临时/temporary"

### Long-term Memory

Any information that doesn't match working or daily memory keywords is stored as long-term memory.

---

## Memory Retrieval Priority

When retrieving memories, the system uses priority-based ranking:

1. **Working Memory** (Priority: 2.0x) - Highest priority
2. **Daily Memory** (Priority: 1.5x) - Medium priority
3. **Long-term Memory** (Priority: 1.0x) - Normal priority

---

## Storage Location

Memory data is stored in:

```
stdpath('cache')/chat.nvim/memory/
├── working/
│   └── session-id.json
├── daily/
│   └── date-based-files.json
└── long_term/
    └── memories.json
```

---

## Best Practices

### 1. Let the System Auto-Detect

The memory system is designed to automatically detect the appropriate memory type and category. Trust the auto-detection for most cases.

### 2. Use Working Memory for Tasks

Explicitly use working memory for current tasks and decisions:

```
@extract_memory text="当前任务：实现用户认证" memory_type="working" importance="high"
```

### 3. Use Daily Memory for Planning

Explicitly use daily memory for today's tasks and short-term goals:

```
@extract_memory text="今天下午 3 点有团队会议" memory_type="daily" category="event"
```

### 4. Use Long-term Memory for Knowledge

Explicitly use long-term memory for permanent knowledge:

```
@extract_memory text="Lua 使用 1-based 索引" memory_type="long_term" category="fact"
```

### 5. Recall Before Asking

Use `@recall_memory` before asking questions to provide context:

```
@recall_memory query="vim configuration"
```

---

## Use Cases

### Task Tracking

```
User: 我正在实现用户认证功能
AI: @extract_memory text="当前任务：实现用户认证功能" memory_type="working" importance="high"

User: 接下来要做什么？
AI: @recall_memory query="当前任务" memory_type="working"
```

### Daily Planning

```
User: 今天下午 3 点有团队会议
AI: @extract_memory text="今天下午 3 点有团队会议" memory_type="daily" category="event"

User: 今天有什么安排？
AI: @recall_memory query="今天" memory_type="daily"
```

### Knowledge Building

```
User: Lua 使用 1-based 索引，这点和 Python 不同
AI: @extract_memory text="Lua 使用 1-based 索引" memory_type="long_term" category="fact"

User: Lua 和 Python 有什么区别？
AI: @recall_memory query="Lua Python 区别" memory_type="long_term"
```

---

## Troubleshooting

### Memory Not Being Stored

**Solution:**
1. Check if memory system is enabled: `memory.enable = true`
2. Verify storage directory permissions
3. Check Neovim logs for errors

### Working Memory Disappeared

**Solution:** This is expected behavior. Working memory is session-scoped and automatically cleared when the session ends.

### Daily Memory Not Expiring

**Solution:** The cleanup runs periodically. Wait for the next cleanup cycle or manually clean up old memories.

---

## Next Steps

- [Tools](tools.md) - Learn about memory tools in detail
- [Configuration](../configuration.md) - Configure memory settings
- [Providers](providers.md) - Configure AI providers

