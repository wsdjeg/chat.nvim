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
| `model`         | string             | `'deepseek-v4-flash'`                                          | Default AI model                                                           |
| `strftime`      | string             | `'%m-%d %H:%M:%S'`                                              | Time display format                                                        |
| `render_markdown` | boolean            | `true`                                                          | Enable RenderMarkdown plugin for result buffer (requires render-markdown.nvim) |
| `system_prompt` | string or function | `''`                                                            | Default system prompt, can be a string or a function that returns a string |
| `highlights`    | table              | `{title = 'ChatNvimTitle', title_badge = 'ChatNvimTitleBadge'}` | Highlight groups for title text and decorative badges                      |
| `winhighlight`  | string             | `'NormalFloat:Normal,FloatBorder:WinSeparator'`                | Window highlight configuration for floating windows                         |

### Example

```lua
require('chat').setup({
  width = 0.8,
  height = 0.8,
  auto_scroll = true,
  border = 'rounded',
  provider = 'deepseek',
  model = 'deepseek-v4-flash',
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
| `http.api_key` | string | `''`               | API key for authenticating incoming requests (must be non-empty to enable server) |

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
  qwen = 'qwen-xxxxxxxx',              -- Alibaba Qwen (DashScope)
  aliyuncs = 'sk-xxxxxxxxxxxx',        -- Alibaba Cloud (Bailian)
  siliconflow = 'xxxxxxxx-xxxx-xxxx',  -- SiliconFlow
  tencent = 'xxxxxxxx-xxxx-xxxx',      -- Tencent Hunyuan
  baidu = 'xxxxxxxx-xxxx-xxxx',        -- Baidu Qianfan
  bigmodel = 'xxxxxxxx-xxxx-xxxx',     -- BigModel AI (Zhipu)
  volcengine = 'xxxxxxxx-xxxx-xxxx',   -- Volcengine AI (Doubao)
  xiaomi = 'xxxxxxxx-xxxx-xxxx',       -- Xiaomi MiMo
  openai = 'sk-xxxxxxxxxxxx',          -- OpenAI
  anthropic = 'sk-ant-xxxxxxxxxxxx',   -- Anthropic Claude
  gemini = 'AIxxxxxxxxxxxxxxxxxxxx',   -- Google Gemini
  longcat = 'lc-xxxxxxxxxxxx',         -- LongCat AI
  cherryin = 'sk-xxxxxxxxxxxx',        -- CherryIN AI
  yuanjing = 'xxxxxxxx-xxxx-xxxx',     -- Yuanjing AI
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
    similarity_threshold = 0.4,
  },

  -- Working memory: Current session focus (highest priority)
  working = {
    enable = true,
    max_memories = 20,            -- Maximum working memories per session
    priority_weight = 2.0,        -- Priority multiplier (higher = more important)
  },

  -- Storage location
  storage_dir = vim.fn.stdpath('data') .. '/chat.nvim/memory/',
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

## User Profile Configuration

chat.nvim supports user profiles (人物画像) for personalized AI assistance. Profiles store user preferences, skills, and background information as markdown files.

```lua
require('chat').setup({
  user = {
    enable = true,        -- Enable user profile system
    id = '',              -- User ID (auto-detected from system username if empty)
    storage_dir = vim.fn.stdpath('data') .. '/chat.nvim/users/',  -- Storage directory
  },
})
```

| Option             | Type    | Default                                  | Description                                         |
| ------------------ | ------- | ---------------------------------------- | --------------------------------------------------- |
| `user.enable`      | boolean | `true`                                   | Enable/disable user profile system                  |
| `user.id`          | string  | `''`                                     | User ID (auto-detected from system username if empty) |
| `user.storage_dir` | string  | `stdpath('data')/chat.nvim/users/`      | Storage directory for user profile markdown files   |

When enabled, the AI assistant can use the `@user_profile` tool to read, update, and manage user profiles, providing personalized and context-aware responses.

---

## Skills Configuration

chat.nvim includes a skill (slash command) system that lets you type `/name [args]` in the prompt window to invoke commands without sending to the LLM. You can register custom skills via configuration:

```lua
require('chat').setup({
  skills = {
    {
      name = 'greet',
      description = 'Say hello',
      handler = function(args, ctx)
        return 'Hello, ' .. (args or 'world') .. '!'
      end,
    },
  },
})
```

Each skill spec contains:

| Field          | Type     | Description                                              |
| -------------- | -------- | -------------------------------------------------------- |
| `name`         | string   | Unique identifier (used as `/name`)                      |
| `description`  | string   | Short description shown in `/help`                       |
| `handler`      | function | `function(args: string, ctx: table): string|nil`        |
| `complete`     | function | Optional completion function `(args) -> string[]`        |

You can also register skills at runtime via `require('chat').register_skill(spec)` and unregister with `require('chat').unregister_skill(name)`.

See [Usage > Skills](./usage/#skills-slash-commands) for the list of built-in skills.

---

## Auto-Retry Configuration

chat.nvim automatically retries LLM requests that fail due to connection errors or timeouts. This helps maintain stable conversations even with intermittent network issues.

```lua
retry = {
  max_retries = 3,       -- Maximum retry attempts per request (default: 3)
  retry_delay = 2000,    -- Delay between retries in milliseconds (default: 2000 = 2 seconds)
}
```

### How It Works

- When an LLM request fails with a retryable error (connection failure or timeout), an error message is appended to the session with a retry hint (e.g., `Auto-retry 1/3 (2 remaining).`)
- The system then automatically schedules a retry after the configured delay
- Retry count is per-session and reset on each new user message
- During the retry delay period, `is_in_progress()` returns `true`, preventing new messages from being sent
- The user can cancel a pending retry with `Ctrl-C`
- On successful response, the retry count is immediately reset
- When all auto-retries are exhausted, the error message includes `Press r to retry manually.`

### Retryable Error Codes

The following curl exit codes are considered retryable:

| Code | Description                  |
| ---- | ---------------------------- |
| 6    | Couldn't resolve host        |
| 7    | Failed to connect to host    |
| 28   | Operation timeout            |
| 35   | SSL/TLS handshake failure    |
| 52   | Empty reply from server      |
| 56   | Failure with receiving data  |

{: .warning }

> HTTP errors (e.g., 400, 429, 500) are **not** retried, as they indicate API-level issues rather than network problems.

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
  model = 'deepseek-v4-flash',
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

  -- Auto-retry on connection errors and timeouts
  retry = {
    max_retries = 3,
    retry_delay = 2000,
  },

  -- User profile system (人物画像)
  user = {
    enable = true,
    id = '',
    storage_dir = vim.fn.stdpath('data') .. '/chat.nvim/users/',
  },

  -- Custom skills (slash commands)
  skills = {
    {
      name = 'greet',
      description = 'Say hello',
      handler = function(args, ctx)
        return 'Hello, ' .. (args or 'world') .. '!'
      end,
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
> 8. **RenderMarkdown**: The `render_markdown` option enables/disables the [RenderMarkdown](https://github.com/MeanderingProgrammer/render-markdown.nvim) plugin for the result buffer. Defaults to `true`. Set to `false` if you prefer plain markdown syntax highlighting without rich rendering.
> 9. **Auto-Retry**: The `retry` option configures automatic retry of LLM requests on connection errors and timeouts. When a retryable error occurs, an error message with retry status is appended to the session (e.g., `Auto-retry 1/3 (2 remaining).`). When all retries are exhausted, the message includes `Press r to retry manually.` Retries are per-session and reset on each new user message. Only network-level errors are retried; HTTP errors (400, 429, 500, etc.) are not.
> 10. **Storage Migration**: Memory and session data are stored under `stdpath('data')/chat.nvim/`. Previously stored under `stdpath('cache')`, data has been migrated to the data directory for persistence across Neovim cache clears.
> 11. **User Profiles**: The `user` option configures the user profile system (人物画像). When enabled, the AI can use `@user_profile` to read and update user profiles for personalized assistance. Profiles are stored as markdown files under `user.storage_dir`.
> 12. **Skills**: The `skills` option allows registering custom slash commands. Type `/name [args]` in the prompt window to invoke a skill without sending to the LLM. Built-in skills include `/clear`, `/new`, `/model`, `/provider`, `/cwd`, `/pin`, `/title`, `/retry`, and `/help`. See [Usage > Skills](./usage/#skills-slash-commands) for details.

---

---

## Next Steps

- [Usage Guide](./usage/) - Learn how to use chat.nvim
- [Providers](./providers/) - Configure AI providers
- [Tools](./tools/) - Explore available tools
