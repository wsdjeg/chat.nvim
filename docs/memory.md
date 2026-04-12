---
layout: default
title: Memory System
nav_order: 6
has_children: false
---

<!-- prettier-ignore-start -->
# Memory System
{: .no_toc }
## Table of contents
{: .no_toc }
<!-- prettier-ignore-end -->

<!-- prettier-ignore -->
- content
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

**Use Cases:**

- Tracking current task progress
- Remembering temporary decisions
- Maintaining active context
- Storing session-specific information

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

**Use Cases:**

- Daily to-do lists
- Temporary reminders
- Short-term goals
- Scheduled tasks

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

**Use Cases:**

- Programming knowledge
- Personal preferences
- Technical skills
- Important facts and rules

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

### Configuration Options

| Option                           | Type    | Default                              | Description                            |
| -------------------------------- | ------- | ------------------------------------ | -------------------------------------- |
| `enable`                         | boolean | `true`                               | Global memory system switch            |
| `long_term.enable`               | boolean | `true`                               | Enable long-term memory                |
| `long_term.max_memories`         | number  | `500`                                | Maximum long-term memories             |
| `long_term.retrieval_limit`      | number  | `3`                                  | Maximum memories to retrieve per query |
| `long_term.similarity_threshold` | number  | `0.3`                                | Similarity threshold (0-1)             |
| `daily.enable`                   | boolean | `true`                               | Enable daily memory                    |
| `daily.retention_days`           | number  | `7`                                  | Days before auto-deletion              |
| `daily.max_memories`             | number  | `100`                                | Maximum daily memories                 |
| `daily.similarity_threshold`     | number  | `0.3`                                | Similarity threshold (0-1)             |
| `working.enable`                 | boolean | `true`                               | Enable working memory                  |
| `working.max_memories`           | number  | `20`                                 | Maximum working memories per session   |
| `working.priority_weight`        | number  | `2.0`                                | Priority multiplier                    |
| `storage_dir`                    | string  | `stdpath('cache')/chat.nvim/memory/` | Storage directory                      |

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
@extract_memory text="Python的GIL是全局解释器锁，我习惯用Vim写代码"
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
@extract_memory text="Python的GIL是全局解释器锁" memory_type="long_term" category="fact"
```

**Working Memory with Importance:**

```
@extract_memory text="当前任务：实现用户认证" memory_type="working" importance="high"
```

**Batch Extract:**

```
@extract_memory memories='[{"content":"事实1","category":"fact","memory_type":"long_term"},{"content":"偏好1","category":"preference"}]'
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
```

```
@recall_memory query="today" memory_type="daily"
```

```
@recall_memory query="python" memory_type="long_term"
```

**Auto-extract from Conversation:**

```
@recall_memory
```

**Search Across All Sessions:**

```
@recall_memory query="vim" all_sessions=true
```

**Limit Results:**

```
@recall_memory query="programming tips" limit=8
```

---

## Auto-Detection Rules

The `@extract_memory` tool automatically detects memory type based on keywords:

### Working Memory Keywords

- "当前/正在/current"
- "任务/task"
- "决策/decision"
- "问题/issue"

**Examples:**

- "当前任务：实现用户认证" → working memory
- "正在修复登录bug" → working memory
- "Current task: implement feature" → working memory

### Daily Memory Keywords

- "今天/明天/today/tomorrow"
- "待办/todo"
- "临时/temporary"

**Examples:**

- "今天下午3点有会议" → daily memory
- "明天需要提交报告" → daily memory
- "Today's task: code review" → daily memory

### Long-term Memory

Any information that doesn't match working or daily memory keywords is stored as long-term memory.

**Examples:**

- "Python支持函数式编程" → long-term memory
- "Vim的哲学是模态编辑" → long-term memory
- "Neovim使用Lua作为配置语言" → long-term memory

---

## Memory Retrieval Priority

When retrieving memories, the system uses priority-based ranking:

1. **Working Memory** (Priority: 2.0x)

   - Highest priority
   - Session-specific
   - Most relevant to current context

2. **Daily Memory** (Priority: 1.5x)

   - Medium priority
   - Recent and temporary
   - Relevant to current timeframe

3. **Long-term Memory** (Priority: 1.0x)
   - Normal priority
   - Permanent knowledge
   - Based on similarity

**Example Output:**

```
📚 Retrieved 3 memories (⚡ working: 1, 📅 daily: 1, 💾 long_term: 1)

1. ⚡ working 📋 [task]
   > 当前任务：实现用户认证功能
   🕒 2025-01-15 14:30 | 🎯 High Priority | 🏷️ task

2. 📅 daily 📅 [event]
   > 今天下午3点有团队会议
   🕒 2025-01-15 09:15 | Expires in 6 days

3. 💾 long_term 📚 [skill]
   > Python GIL是全局解释器锁，影响多线程性能
   🕒 2025-01-10 16:42 | Accessed 5 times

🔧 Actions:
• Working memory will be cleaned after session ends
• Daily memory expires in 7-30 days
• Use `@recall_memory memory_type="long_term"` to filter by type
```

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

### Working Memory Storage

```
~/.cache/nvim/chat.nvim/memory/working/
```

Each session has its own working memory file that is automatically cleaned up when the session ends.

### Daily Memory Storage

```
~/.cache/nvim/chat.nvim/memory/daily/
```

Daily memories are stored with timestamps and automatically cleaned up after the retention period.

### Long-term Memory Storage

```
~/.cache/nvim/chat.nvim/memory/long_term/memories.json
```

Long-term memories are stored permanently and persist across sessions.

---

## Best Practices

### 1. Let the System Auto-Detect

The memory system is designed to automatically detect the appropriate memory type and category. Trust the auto-detection for most cases:

```
@extract_memory text="Python支持多种编程范式"
```

### 2. Use Working Memory for Tasks

Explicitly use working memory for current tasks and decisions:

```
@extract_memory text="当前任务：实现用户认证" memory_type="working" importance="high"
```

### 3. Use Daily Memory for Planning

Explicitly use daily memory for today's tasks and short-term goals:

```
@extract_memory text="今天下午3点有团队会议" memory_type="daily" category="event"
```

### 4. Use Long-term Memory for Knowledge

Explicitly use long-term memory for permanent knowledge:

```
@extract_memory text="Lua使用1-based索引" memory_type="long_term" category="fact"
```

### 5. Recall Before Asking

Use `@recall_memory` before asking questions to provide context:

```
@recall_memory query="vim configuration"
```

Then continue your conversation with the retrieved context.

### 6. Clean Up Periodically

The system automatically cleans up daily memories, but you can manually manage long-term memories if they become too numerous.

---

## Use Cases

### Task Tracking

Use working memory to track current tasks:

```
User: 我正在实现用户认证功能
AI: @extract_memory text="当前任务：实现用户认证功能" memory_type="working" importance="high"

User: 接下来要做什么？
AI: @recall_memory query="当前任务" memory_type="working"
```

### Daily Planning

Use daily memory for daily planning:

```
User: 今天下午3点有团队会议
AI: @extract_memory text="今天下午3点有团队会议" memory_type="daily" category="event"

User: 今天有什么安排？
AI: @recall_memory query="今天" memory_type="daily"
```

### Knowledge Building

Use long-term memory to build a knowledge base:

```
User: Lua使用1-based索引，这点和Python不同
AI: @extract_memory text="Lua使用1-based索引" memory_type="long_term" category="fact"

User: Lua和Python有什么区别？
AI: @recall_memory query="Lua Python 区别" memory_type="long_term"
```

### Preference Learning

Use long-term memory to remember preferences:

```
User: 我喜欢用Vim写代码
AI: @extract_memory text="喜欢用Vim写代码" memory_type="long_term" category="preference"

User: 推荐一个编辑器
AI: @recall_memory query="编辑器偏好" memory_type="long_term"
```

---

## Troubleshooting

### Memory Not Being Stored

**Symptom:** Memories are not being stored or recalled.

**Solution:**

1. Check if memory system is enabled: `memory.enable = true`
2. Verify storage directory permissions
3. Check Neovim logs for errors

### Working Memory Disappeared

**Symptom:** Working memories from previous session are not available.

**Solution:** This is expected behavior. Working memory is session-scoped and automatically cleared when the session ends.

### Daily Memory Not Expiring

**Symptom:** Daily memories persist beyond the retention period.

**Solution:** The cleanup runs periodically. Wait for the next cleanup cycle or manually clean up old memories.

### Long-term Memory Too Large

**Symptom:** Long-term memory storage becomes too large.

**Solution:**

1. Reduce `max_memories` in configuration
2. Increase `similarity_threshold` to be more selective
3. Manually clean up the storage directory

---

## Next Steps

- [Tools Documentation](/docs/tools/) - Learn about memory tools in detail
- [Configuration](/docs/configuration/) - Configure memory settings
- [Usage Guide](/docs/usage/) - Use memory tools in conversations
