---
layout: default
title: Configuration
nav_order: 3
has_children: false
---

<!-- prettier-ignore-start -->
# Configuration
{: .no_toc }
## Table of contents
{: .no_toc }
<!-- prettier-ignore-end -->

<!-- prettier-ignore -->
- content
{:toc}

---

chat.nvim provides flexible configuration options through the `require('chat').setup()` function. All configurations have sensible defaults.

## Basic Options

| Option          | Type               | Default                                                         | Description                                                                |
| --------------- | ------------------ | --------------------------------------------------------------- | -------------------------------------------------------------------------- |
| `width`         | number             | `0.8`                                                           | Chat window width (percentage of screen width, 0.0-1.0)                    |
| `height`        | number             | `0.8`                                                           | Chat window height (percentage of screen height, 0.0-1.0)                  |
| `auto_scroll`   | boolean            | `true`                                                          | Controls automatic scrolling behavior of the result window                 |
| `border`        | string             | `'rounded'`                                                     | Window border style, supports all Neovim border options                    |
| `provider`      | string             | `'deepseek'`                                                    | Default AI provider                                                        |
| `model`         | string             | `'deepseek-chat'`                                               | Default AI model                                                           |
| `strftime`      | string             | `'%m-%d %H:%M:%S'`                                              | Time display format                                                        |
| `system_prompt` | string or function | `''`                                                            | Default system prompt, can be a string or a function that returns a string |
| `highlights`    | table              | `{title = 'ChatNvimTitle', title_badge = 'ChatNvimTitleBadge'}` | Highlight groups for title text and decorative badges                      |

### Example

```lua
require('chat').setup({
  width = 0.8,
  height = 0.8,
  auto_scroll = true,
  border = 'rounded',
  provider = 'deepseek',
  model = 'deepseek-chat',
  strftime = '%Y-%m-%d %H:%M',
})
```

---

## HTTP Server Configuration

Configure the built-in HTTP server for receiving external messages:

| Option         | Type   | Default            | Description                                                                 |
| -------------- | ------ | ------------------ | --------------------------------------------------------------------------- |
| `http.host`    | string | `'127.0.0.1'`      | Host address for the HTTP server                                            |
| `http.port`    | number | `7777`             | Port number for the HTTP server                                             |
| `http.api_key` | string | `'test_chat_nvim'` | API key for authenticating incoming requests (must be set to enable server) |

### Example

```lua
http = {
  host = '127.0.0.1',
  port = 7777,
  api_key = 'your-secret-api-key-here', -- Set to empty string to disable HTTP server
}
```

### Notes

{: .warning }

> - The HTTP server is automatically started when `http.api_key` is not empty
> - Incoming requests must include the API key in the `X-API-Key` header
> - Messages are queued and processed when the chat window is not busy

---

## API Key Configuration

Configure API keys for the AI providers you plan to use:

```lua
api_key = {
  deepseek = 'sk-xxxxxxxxxxxx',        -- DeepSeek AI
  github = 'github_pat_xxxxxxxx',      -- GitHub AI
  moonshot = 'sk-xxxxxxxxxxxx',        -- Moonshot AI
  openrouter = 'sk-or-xxxxxxxx',       -- OpenRouter
  qwen = 'qwen-xxxxxxxx',              -- Alibaba Qwen
  siliconflow = 'xxxxxxxx-xxxx-xxxx',  -- SiliconFlow
  tencent = 'xxxxxxxx-xxxx-xxxx',      -- Tencent Hunyuan
  bigmodel = 'xxxxxxxx-xxxx-xxxx',     -- BigModel AI
  volcengine = 'xxxxxxxx-xxxx-xxxx',   -- Volcengine AI
  openai = 'sk-xxxxxxxxxxxx',          -- OpenAI
  longcat = 'lc-xxxxxxxxxxxx',         -- LongCat AI
  cherryin = 'sk-xxxxxxxxxxxx',        -- CherryIN AI
}
```

{: .highlight }

> Only configure keys for providers you plan to use; others can be omitted.

---

## File Access Control

Control which file paths tools can access for security:

```lua
-- Option 1: Disable all file access (default)
allowed_path = ''

-- Option 2: Allow a single directory
allowed_path = '/home/user/projects'

-- Option 3: Allow multiple directories
allowed_path = {
  vim.fn.getcwd(),               -- Current working directory
  vim.fn.expand('~/.config/nvim'), -- Neovim config directory
  '/etc',                        -- System configuration files
}
```

### Security Recommendations

{: .warning }

> - Empty string disables all file access
> - Recommended to set to your current project directory for security
> - Only allow directories you trust tools to read/write

---

## Context Window Configuration

Configure automatic context truncation to manage token usage:

```lua
context = {
  enable = true,           -- Enable/disable context truncation
  trigger_threshold = 50,  -- Number of messages to trigger truncation
  keep_recent = 10,        -- Keep recent N messages (not included in truncation search)
}
```

### Notes

- When conversation exceeds `trigger_threshold` messages, older messages may be summarized or removed
- The `keep_recent` parameter ensures recent context is preserved
- Helps prevent token limit errors during long conversations

---

## Memory System Configuration

chat.nvim implements a sophisticated three-tier memory system inspired by cognitive psychology.

### Memory Architecture

1. **Working Memory** ⚡ - High-priority, session-scoped memory for current tasks and decisions
2. **Daily Memory** 📅 - Temporary memory for daily tasks and short-term goals (auto-expires)
3. **Long-term Memory** 💾 - Permanent knowledge storage for facts, preferences, and skills

### Configuration Example

```lua
memory = {
  enable = true,  -- Global memory system switch

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
}
```

### Memory Type Characteristics

| Type      | Lifetime     | Priority | Use Case                                   |
| --------- | ------------ | -------- | ------------------------------------------ |
| Working   | Session only | Highest  | Current tasks, decisions, active context   |
| Daily     | 7-30 days    | Medium   | Short-term goals, today's tasks, reminders |
| Long-term | Permanent    | Normal   | Facts, preferences, skills, knowledge      |

### Auto-Detection

The `@extract_memory` tool automatically detects memory type based on keywords:

- **Working Memory**: "当前/正在/current", "任务/task", "决策/decision", "问题/issue"
- **Daily Memory**: "今天/明天/today/tomorrow", "待办/todo", "临时/temporary"
- **Long-term Memory**: Other persistent information

---

## system_prompt Usage Examples

Here are different ways to use the `system_prompt` option:

### String (simple)

```lua
system_prompt = 'You are a helpful programming assistant.',
```

### Function loading from file

```lua
system_prompt = function()
  local path = vim.fn.expand('~/.config/nvim/AGENTS.md')
  if vim.fn.filereadable(path) == 1 then
    return table.concat(vim.fn.readfile(path), '\n')
  end
  return 'Default system prompt'
end
```

### Function with project-specific prompts

```lua
system_prompt = function()
  local cwd = vim.fn.getcwd()
  if string.find(cwd, 'chat%.nvim') then
    return 'You are a specialized assistant for chat.nvim plugin development.'
  elseif string.find(cwd, 'picker%.nvim') then
    return 'You are a specialized assistant for picker.nvim plugin development.'
  end
  return 'You are a general programming assistant.'
end
```

### Function with time-based prompts

```lua
system_prompt = function()
  local hour = tonumber(os.date("%H"))
  local day = os.date("%A")
  return string.format('Good %s! Today is %s. I am your AI assistant.',
    hour < 12 and 'morning' or hour < 18 and 'afternoon' or 'evening',
    day)
end
```

---

## Complete Configuration Example

```lua
require('chat').setup({
  -- Window settings
  width = 0.8,
  height = 0.8,
  auto_scroll = true,
  border = 'rounded',

  -- AI provider settings
  provider = 'deepseek',
  model = 'deepseek-chat',
  api_key = {
    deepseek = 'sk-xxxxxxxxxxxx',
    github = 'github_pat_xxxxxxxx',
  },

  -- HTTP server configuration
  http = {
    host = '127.0.0.1',
    port = 7777,
    api_key = 'your-secret-key-here',
  },

  -- File access control
  allowed_path = {
    vim.fn.getcwd(),
    vim.fn.expand('~/.config/nvim'),
  },

  -- Time format
  strftime = '%Y-%m-%d %H:%M',

  -- System prompt
  system_prompt = function()
    local path = vim.fn.expand('./AGENTS.md')
    if vim.fn.filereadable(path) == 1 then
      return table.concat(vim.fn.readfile(path), '\n')
    end
    return 'You are a helpful programming assistant.'
  end,

  -- Memory system
  memory = {
    enable = true,
    long_term = {
      max_memories = 500,
      retrieval_limit = 3,
    },
    daily = {
      retention_days = 7,
      max_memories = 100,
    },
    working = {
      max_memories = 20,
      priority_weight = 2.0,
    },
  },

  -- MCP servers (optional)
  mcp = {
    open_webSearch = {
      command = 'npx',
      args = { '-y', 'open-websearch@latest' },
    },
  },

  -- IM integrations (optional)
  integrations = {
    discord = {
      token = 'YOUR_DISCORD_BOT_TOKEN',
      channel_id = 'YOUR_CHANNEL_ID',
    },
  },
})
```

---

## Configuration Notes

{: .info }

> 1. **Path Security**: `allowed_path` restricts which file paths tools can access. Empty string disables all file access. Recommended to set to your current project directory for security.
> 2. **API Keys**: Only configure keys for providers you plan to use. Providers can be switched at runtime via the picker.
> 3. **Memory System**: Enabled by default, automatically extracts facts and preferences from conversations. Can be disabled with `memory.enable = false`.
> 4. **HTTP Server**: Configure `http.api_key` to enable the HTTP server. The server binds to localhost by default for security.
> 5. **Dynamic Updates**: Some configurations (like provider and model) can be changed dynamically at runtime via the picker.
> 6. **Automatic Scrolling**: The `auto_scroll` option controls whether the result window automatically scrolls to show new content. When enabled (default), it only scrolls if the cursor was already at the bottom, preventing interruptions when reviewing history.
> 7. **system_prompt Function Support**: The `system_prompt` option can be either a string or a function that returns a string. When a function is provided, it is called each time a new session is created, allowing for dynamic prompts based on time, project context, or external files. The function should handle errors gracefully and return a string value.

---

## Next Steps

- [Usage Guide](/docs/usage/) - Learn how to use chat.nvim
- [Providers](/docs/providers/) - Configure AI providers
- [Tools](/docs/tools/) - Explore available tools
