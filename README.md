# chat.nvim

A lightweight, extensible chat plugin for Neovim with AI integration.
Chat with AI assistants directly in your editor using a clean, floating window interface.

[![Run Tests](https://github.com/wsdjeg/chat.nvim/actions/workflows/test.yml/badge.svg)](https://github.com/wsdjeg/chat.nvim/actions/workflows/test.yml)
[![GitHub License](https://img.shields.io/github/license/wsdjeg/chat.nvim)](LICENSE)
[![GitHub Issues or Pull Requests](https://img.shields.io/github/issues/wsdjeg/chat.nvim)](https://github.com/wsdjeg/chat.nvim/issues)
[![GitHub commit activity](https://img.shields.io/github/commit-activity/m/wsdjeg/chat.nvim)](https://github.com/wsdjeg/chat.nvim/commits/master/)
[![GitHub Release](https://img.shields.io/github/v/release/wsdjeg/chat.nvim)](https://github.com/wsdjeg/chat.nvim/releases)
[![luarocks](https://img.shields.io/luarocks/v/wsdjeg/chat.nvim)](https://luarocks.org/modules/wsdjeg/chat.nvim)

![chat.nvim](https://wsdjeg.net/images/chat-nvim-intro.png)

<!-- vim-markdown-toc GFM -->

- [✨ Features](#-features)
- [📦 Installation](#-installation)
    - [Prerequisites](#prerequisites)
    - [Package Manager Installation](#package-manager-installation)
        - [Using nvim-plug](#using-nvim-plug)
        - [Using lazy.nvim](#using-lazynvim)
        - [Using packer.nvim](#using-packernvim)
    - [Manual Installation](#manual-installation)
    - [Post-Installation Setup](#post-installation-setup)
    - [Quick Start](#quick-start)
- [🔧 Configuration](#-configuration)
    - [Basic Options](#basic-options)
    - [HTTP Server Configuration](#http-server-configuration)
    - [API Key Configuration](#api-key-configuration)
    - [File Access Control](#file-access-control)
    - [Context Window Configuration](#context-window-configuration)
    - [Memory System Configuration](#memory-system-configuration)
    - [system_prompt Usage Examples](#system_prompt-usage-examples)
    - [MCP Server Configuration](#mcp-server-configuration)
    - [IM Integration Configuration](#im-integration-configuration)
    - [Complete Configuration Example](#complete-configuration-example)
    - [Configuration Notes](#configuration-notes)
- [⚙️ Usage](#-usage)
    - [Basic Commands](#basic-commands)
    - [MCP Commands](#mcp-commands)
    - [Parallel Sessions](#parallel-sessions)
    - [Examples](#examples)
    - [Key Bindings](#key-bindings)
- [🤖 Providers](#-providers)
    - [Built-in Providers](#built-in-providers)
    - [Custom Providers](#custom-providers)
    - [Protocols](#protocols)
- [🛠️ Tools](#-tools)
    - [MCP Tools](#mcp-tools)
    - [Available Tools](#available-tools)
        - [`read_file`](#read_file)
        - [`find_files`](#find_files)
        - [`search_text`](#search_text)
        - [`extract_memory`](#extract_memory)
        - [`recall_memory`](#recall_memory)
        - [`set_prompt`](#set_prompt)
        - [`fetch_web`](#fetch_web)
        - [`web_search`](#web_search)
        - [`git_diff`](#git_diff)
        - [`git_log`](#git_log)
        - [`get_history`](#get_history)
        - [`plan`](#plan)
    - [Third-party Tools](#third-party-tools)
        - [`zettelkasten_create`](#zettelkasten_create)
        - [`zettelkasten_get`](#zettelkasten_get)
    - [How to Use Tools](#how-to-use-tools)
    - [Custom Tools](#custom-tools)
        - [Synchronous Tool Example](#synchronous-tool-example)
        - [Asynchronous Tool Example](#asynchronous-tool-example)
- [🌐 HTTP API](#-http-api)
    - [Enabling the HTTP Server](#enabling-the-http-server)
    - [API Endpoints](#api-endpoints)
    - [Request Format](#request-format)
    - [Response Format](#response-format)
        - [POST `/`](#post-)
        - [GET `/sessions`](#get-sessions)
        - [GET `/session`](#get-session)
    - [Message Queue System](#message-queue-system)
    - [Usage Examples](#usage-examples)
        - [Using curl:](#using-curl)
        - [Using Python:](#using-python)
    - [Security Considerations](#security-considerations)
    - [Integration Ideas](#integration-ideas)
- [🔍 Picker Integration](#-picker-integration)
- [💬 IM Integration](#-im-integration)
    - [Supported Platforms](#supported-platforms)
    - [Discord](#discord)
        - [Features](#features)
        - [Setup Guide](#setup-guide)
        - [Commands](#commands)
        - [Workflow](#workflow)
        - [Technical Details](#technical-details)
        - [Troubleshooting](#troubleshooting)
    - [Lark (Feishu)](#lark-feishu)
        - [Features](#features-1)
        - [Setup Guide](#setup-guide-1)
        - [Commands](#commands-1)
        - [Technical Details](#technical-details-1)
    - [DingTalk](#dingtalk)
        - [Features](#features-2)
        - [Setup Guide](#setup-guide-2)
        - [Technical Details](#technical-details-2)
    - [WeCom (Enterprise WeChat)](#wecom-enterprise-wechat)
        - [Features](#features-3)
        - [Setup Guide](#setup-guide-3)
        - [Technical Details](#technical-details-3)
    - [Telegram](#telegram)
        - [Features](#features-4)
        - [Setup Guide](#setup-guide-4)
        - [Commands](#commands-2)
        - [Workflow](#workflow-1)
        - [Technical Details](#technical-details-4)
        - [Troubleshooting](#troubleshooting-1)
    - [Common Features](#common-features)
    - [Platform-Specific Notes](#platform-specific-notes)
    - [Contributing New Integrations](#contributing-new-integrations)
- [📣 Self-Promotion](#-self-promotion)
- [💬 Feedback](#-feedback)
- [📄 License](#-license)

<!-- vim-markdown-toc -->

## ✨ Features

- **Three-Tier Memory System**: Working memory (session tasks), daily memory (short-term goals), and long-term memory (permanent knowledge) with automatic extraction and priority-based retrieval
- **Parallel Sessions**: Run multiple independent conversations with different AI models, each maintaining separate context and settings
- **Multiple AI Providers**: Built-in support for DeepSeek, GitHub AI, Moonshot, OpenRouter, Qwen, SiliconFlow, Tencent, BigModel, Volcengine, OpenAI, LongCat, Anthropic Claude, Google Gemini, Ollama, and custom providers
- **Tool Call Integration**: Built-in tools for file operations (`@read_file`, `@find_files`, `@search_text`), version control (`@git_diff`, `@git_log`), conversation history (`@get_history`), memory management...
- **Zettelkasten Integration**: Note-taking support via `@zettelkasten_create` and `@zettelkasten_get` tools for knowledge management (requires zettelkasten.nvim)
- **IM Integration**: Connect Discord, Lark (Feishu), DingTalk, WeCom (Enterprise WeChat), and Telegram channels to chat.nvim sessions for remote AI interaction
- **HTTP API Server**: Built-in HTTP server for receiving external messages with API key authentication and message queue support
- **Session Management**: Commands for creating (`:Chat new`), navigating (`:Chat prev/next`), clearing (`:Chat clear`), deleting (`:Chat delete`), saving (`:Chat save`), loading (`:Chat load`), sharing (`:Chat share`), bridging (`:Chat bridge`), previewing (`:Chat preview`), and changing working directory (`:Chat cd`)
- **Picker Integration**: Seamless integration with picker.nvim for browsing chat history (`picker-chat`), switching providers (`chat_provider`), and selecting models (`chat_model`)
- **Floating Window Interface**: Clean, non-intrusive dual-window layout with configurable dimensions and borders
- **Streaming Responses**: Real-time AI responses with cancellation support (`Ctrl-C`) and retry mechanism (`r`)
- **Token Usage Tracking**: Display real-time token consumption for each response
- **Lightweight Implementation**: Pure Lua with minimal dependencies and comprehensive error handling
- **Customizable Configuration**: Flexible setup for API keys, allowed paths, memory settings, and system prompts
- **Session HTML Preview**: Generate and open HTML previews of chat sessions in your browser via `:Chat preview` command or `<C-o>` in picker
- **Custom Tools**: Support for creating custom tools via `lua/chat/tools/<tool_name>.lua` with automatic discovery
- **Custom Providers**: Support for creating custom AI providers with custom protocols
- **Custom Protocols**: Support for custom API response parsing (OpenAI, Anthropic, Gemini, and extensible)
- **Context Window Truncation**: Automatic context management with configurable trigger threshold and recent message preservation to prevent token limit issues
- **Token Usage Tracking**: Display real-time token consumption including cached tokens for each response
- **Customizable Highlights**: Configure title text and badge highlight groups to match your colorscheme
- **Title Icons**: Visual session indicators with customizable icons for different session states
- **MCP (Model Context Protocol) Support**: Native integration with MCP servers for extended tool capabilities. Automatically discover and call MCP tools alongside built-in tools with seamless protocol handling and async execution

## 📦 Installation

### Prerequisites

1. **System Dependencies** (optional but recommended for full functionality):

   - [`ripgrep` (rg)](https://github.com/BurntSushi/ripgrep): Required for the `@search_text` tool
   - [`curl`](https://curl.se/): Required for the `@fetch_web` tool
   - [`git`](https://git-scm.com/): Required for the `@git_diff` tool
   - Install with your package manager:

     ```bash
     # Ubuntu/Debian
     sudo apt install ripgrep curl git

     # macOS
     brew install ripgrep curl git

     # Arch Linux
     sudo pacman -S ripgrep curl git
     ```

2. **Neovim Plugin Dependencies**:
   - [`job.nvim`](https://github.com/wsdjeg/job.nvim): **Required** dependency for asynchronous operations
   - [`picker.nvim`](https://github.com/wsdjeg/picker.nvim): **Recommended** for enhanced session and provider management

### Package Manager Installation

#### Using [nvim-plug](https://github.com/junegunn/vim-plug)

```lua
require('plug').add({
  {
    'wsdjeg/chat.nvim',
    depends = {
      {
        'wsdjeg/job.nvim', -- Required
        'wsdjeg/picker.nvim', -- Optional but recommended
      },
    },
  },
})
```

#### Using [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
{
  'wsdjeg/chat.nvim',
  dependencies = {
    'wsdjeg/job.nvim', -- Required
    'wsdjeg/picker.nvim', -- Optional but recommended
  },
}
```

#### Using [packer.nvim](https://github.com/wbthomason/packer.nvim)

```lua
use({
  'wsdjeg/chat.nvim',
  requires = {
    'wsdjeg/job.nvim', -- Required
    'wsdjeg/picker.nvim', -- Optional but recommended
  },
})
```

### Manual Installation

If you're not using a package manager:

1. Clone the repositories:

   ```bash
   git clone https://github.com/wsdjeg/chat.nvim ~/.local/share/nvim/site/pack/chat/start/chat.nvim
   git clone https://github.com/wsdjeg/job.nvim ~/.local/share/nvim/site/pack/chat/start/job.nvim
   ```

2. Add to your Neovim configuration (`~/.config/nvim/init.lua` or `~/.config/nvim/init.vim`):
   ```lua
   vim.cmd[[packadd job.nvim]]
   vim.cmd[[packadd chat.nvim]]
   require('chat').setup({
     -- Your configuration here
   })
   ```

### Post-Installation Setup

1. **API Keys**: Configure at least one AI provider API key in the `api_key` table
2. **File Access**: Set `allowed_path` to control which directories tools can access
3. **Memory System**: Configure memory settings based on your needs
4. **HTTP Server** (optional): Configure HTTP server settings if you want to enable external message integration

### Quick Start

After installation, you can immediately start using chat.nvim:

```vim
:Chat          " Open chat window
:Chat new      " Start a new session
:Chat prev     " Switch to previous session
:Chat next     " Switch to next session
```

For detailed usage instructions, see the [Usage](#-usage) section.

## 🔧 Configuration

chat.nvim provides flexible configuration options through the `require('chat').setup()` function. All configurations have sensible defaults.

### Basic Options

| Option          | Type               | Default            | Description                                                                |
| --------------- | ------------------ | ------------------ | -------------------------------------------------------------------------- |
| `width`         | number             | `0.8`              | Chat window width (percentage of screen width, 0.0-1.0)                    |
| `height`        | number             | `0.8`              | Chat window height (percentage of screen height, 0.0-1.0)                  |
| `auto_scroll`   | boolean            | `true`             | Controls automatic scrolling behavior of the result window                 |
| `border`        | string             | `'rounded'`        | Window border style, supports all Neovim border options                    |
| `provider`      | string             | `'deepseek'`       | Default AI provider                                                        |
| `model`         | string             | `'deepseek-chat'`  | Default AI model                                                           |
| `strftime`      | string             | `'%m-%d %H:%M:%S'` | Time display format                                                        |
| `system_prompt` | string or function | `''`               | Default system prompt, can be a string or a function that returns a string |
| `highlights`    | table  | `{title = 'ChatNvimTitle', title_badge = 'ChatNvimTitleBadge'}` | Highlight groups for title text and decorative badges |

### HTTP Server Configuration

Configure the built-in HTTP server for receiving external messages:

| Option         | Type   | Default            | Description                                                                 |
| -------------- | ------ | ------------------ | --------------------------------------------------------------------------- |
| `http.host`    | string | `'127.0.0.1'`      | Host address for the HTTP server                                            |
| `http.port`    | number | `7777`             | Port number for the HTTP server                                             |
| `http.api_key` | string | `'test_chat_nvim'` | API key for authenticating incoming requests (must be set to enable server) |

Example configuration:

```lua
http = {
  host = '127.0.0.1',
  port = 7777,
  api_key = 'your-secret-api-key-here', -- Set to empty string to disable HTTP server
}
```

**Notes:**

- The HTTP server is automatically started when `http.api_key` is not empty
- Incoming requests must include the API key in the `X-API-Key` header
- Messages are queued and processed when the chat window is not busy

### API Key Configuration

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

Only configure keys for providers you plan to use; others can be omitted.

### File Access Control

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

### Context Window Configuration

Configure automatic context truncation to manage token usage:

```lua
context = {
  enable = true,           -- Enable/disable context truncation
  trigger_threshold = 50,  -- Number of messages to trigger truncation
  keep_recent = 10,        -- Keep recent N messages (not included in truncation search)
}
```

**Notes:**

- When conversation exceeds `trigger_threshold` messages, older messages may be summarized or removed
- The `keep_recent` parameter ensures recent context is preserved
- Helps prevent token limit errors during long conversations

### Memory System Configuration

chat.nvim implements a sophisticated three-tier memory system inspired by cognitive psychology:

**Memory Architecture:**

1. **Working Memory** ⚡ - High-priority, session-scoped memory for current tasks and decisions
2. **Daily Memory** 📅 - Temporary memory for daily tasks and short-term goals (auto-expires)
3. **Long-term Memory** 💾 - Permanent knowledge storage for facts, preferences, and skills

**Configuration:**

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

**Memory Type Characteristics:**

| Type      | Lifetime     | Priority | Use Case                                   |
| --------- | ------------ | -------- | ------------------------------------------ |
| Working   | Session only | Highest  | Current tasks, decisions, active context   |
| Daily     | 7-30 days    | Medium   | Short-term goals, today's tasks, reminders |
| Long-term | Permanent    | Normal   | Facts, preferences, skills, knowledge      |

**Auto-Detection:**

The `@extract_memory` tool automatically detects memory type based on keywords:

- **Working Memory**: "当前/正在/current", "任务/task", "决策/decision"
- **Daily Memory**: "今天/明天/today/tomorrow", "待办/todo", "临时/temporary"
- **Long-term Memory**: Other persistent information

**Example Usage:**

```lua
-- Minimal configuration (use defaults)
memory = {
  enable = true,
}

-- Disable specific memory types
memory = {
  enable = true,
  working = { enable = false },
  daily = { enable = false },
}

-- Adjust retention and capacity
memory = {
  enable = true,
  long_term = {
    max_memories = 1000,
    retrieval_limit = 5,
  },
  daily = {
    retention_days = 14,
    max_memories = 200,
  },
  working = {
    max_memories = 30,
    priority_weight = 3.0,
  },
}
```

**Notes:**

- Working memory is cleared when the session ends
- Daily memories are automatically cleaned up after `retention_days`
- Long-term memories persist until manually deleted or limit is reached
- Priority affects retrieval order: working > daily > long-term
- All memory types support categories: fact, preference, skill, event

### system_prompt Usage Examples

Here are different ways to use the `system_prompt` option:

**String (simple):**

```lua
system_prompt = 'You are a helpful programming assistant.',
```

**Function loading from file:**

```lua
system_prompt = function()
  local path = vim.fn.expand('~/.config/nvim/AGENTS.md')
  if vim.fn.filereadable(path) == 1 then
    return table.concat(vim.fn.readfile(path), '\n')
  end
  return 'Default system prompt'
end
```

**Function with project-specific prompts:**

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

**Function with time-based prompts:**

```lua
system_prompt = function()
  local hour = tonumber(os.date("%H"))
  local day = os.date("%A")
  return string.format('Good %s! Today is %s. I am your AI assistant.',
    hour < 12 and 'morning' or hour < 18 and 'afternoon' or 'evening',
    day)
end
```

### MCP Server Configuration

chat.nvim supports Model Context Protocol (MCP) servers for extended tool capabilities. MCP allows you to connect external tool servers that provide additional functionality.

**Supported Transports:**

- **stdio**: Standard input/output transport (default for command-based servers)
- **streamable_http**: HTTP transport with SSE support (for HTTP-based servers)

**Basic Configuration (stdio transport):**

```lua
mcp = {
  -- Example: Web search MCP server using stdio transport
  open_webSearch = {
    command = 'npx',
    args = { '-y', 'open-websearch@latest' },
    disabled = false,  -- Set to true to disable this server
  },

  -- Example: Another stdio MCP server
  my_custom_server = {
    command = '/path/to/mcp-server',
    args = { '--config', '/path/to/config.json' },
  },
}
```

**HTTP Transport Configuration:**

For HTTP-based MCP servers, use the `streamable_http` transport:

```lua
mcp = {
  -- HTTP-based MCP server
  my_http_server = {
    url = 'https://mcp-server.example.com',
    headers = {
      ['Authorization'] = 'Bearer YOUR_TOKEN',
    },
  },

  -- HTTP server with command to start
  my_managed_http_server = {
    command = 'my-mcp-http-server',
    args = { '--port', '8080' },
    url = 'http://localhost:8080',
    transport = {
      type = 'streamable_http',
      url = 'http://localhost:8080',
    },
  },
}
```

**Transport Configuration Parameters:**

| Parameter           | Type    | Required | Description                                           |
| ------------------- | ------- | -------- | ----------------------------------------------------- |
| `command`           | string  | ❌ No\*  | Path to MCP server executable (required for stdio)    |
| `args`              | array   | ❌ No    | Command-line arguments for the server                 |
| `url`               | string  | ❌ No\*  | HTTP URL for streamable_http transport                |
| `headers`           | table   | ❌ No    | HTTP headers (key-value pairs)                        |
| `transport`         | table   | ❌ No    | Explicit transport configuration                      |
| `transport.type`    | string  | ❌ No    | Transport type: `"stdio"` or `"streamable_http"`      |
| `transport.url`     | string  | ❌ No    | Override URL for transport                            |
| `transport.headers` | table   | ❌ No    | Override headers for transport                        |
| `disabled`          | boolean | ❌ No    | Set to `true` to disable this server (default: false) |

\*Either `command` (for stdio) or `url` (for HTTP) is required.

**MCP Tool Naming:**

MCP tools are automatically prefixed with `mcp_<server>_<tool>` format:

- Original MCP tool: `search`
- MCP server name: `open_webSearch`
- Final tool name: `mcp_open_webSearch_search`

**Usage in Chat:**

```
@mcp_open_webSearch_search query="neovim plugins" limit=10
```

**Key Features:**

- **Multiple Transports**: Support for stdio and HTTP transports
- **Automatic Discovery**: MCP tools are automatically discovered and integrated
- **Seamless Integration**: MCP tools work alongside built-in tools
- **Async Execution**: All MCP tool calls are non-blocking
- **Protocol Compliance**: Full JSON-RPC 2.0 protocol support
- **Error Handling**: Graceful error handling and timeout protection
- **Auto Management**: Servers are automatically started when opening chat and stopped on exit

**Complete Example:**

```lua
require('chat').setup({
  -- ... other configuration

  -- MCP servers configuration
  mcp = {
    -- Stdio-based MCP server
    open_webSearch = {
      command = 'npx',
      args = { '-y', 'open-websearch@latest' },
    },

    -- HTTP-based MCP server
    remote_tools = {
      url = 'https://mcp-api.example.com',
      headers = {
        ['Authorization'] = 'Bearer YOUR_API_KEY',
      },
    },

    -- Managed HTTP server (starts local process)
    local_http_server = {
      command = 'my-mcp-server',
      args = { '--port', '3000' },
      transport = {
        type = 'streamable_http',
        url = 'http://localhost:3000',
      },
    },

    -- Disabled server (won't start)
    experimental = {
      command = 'mcp-experimental',
      disabled = true,
    },
  },
})
```

**Transport Detection:**

chat.nvim automatically detects the transport type:

1. If `transport.type` is specified, use that transport
2. If `command` exists without `transport`, use **stdio** transport
3. If `url` exists without `command`, use **streamable_http** transport

**Notes:**

- MCP servers are started automatically when opening the chat window
- Server connections are managed automatically (cleanup on exit)
- Tools are discovered during initialization with a small delay for protocol handshake
- All MCP tool calls follow the same pattern as built-in tools
- Check server logs with `:messages` for connection issues
- Use `:Chat mcp` commands for manual server management

**Troubleshooting:**

1. **Server not starting**: Verify the `command` path is correct and executable
2. **Tools not appearing**: Wait a few seconds for the initialization handshake
3. **Tool call failures**: Check server logs for error messages
4. **Connection issues**: Ensure the MCP server is properly configured
5. **HTTP transport issues**: Check that the URL is accessible and headers are correct

For more information about MCP, see the [Model Context Protocol specification](https://modelcontextprotocol.io/).

### IM Integration Configuration

Configure instant messaging platform integrations for remote AI interaction:

```lua
integrations = {
  -- Discord
  discord = {
    token = 'YOUR_DISCORD_BOT_TOKEN',     -- Discord bot token
    channel_id = 'YOUR_CHANNEL_ID',        -- Discord channel ID
  },

  -- Lark (Feishu)
  lark = {
    app_id = 'YOUR_APP_ID',                -- Lark app ID
    app_secret = 'YOUR_APP_SECRET',        -- Lark app secret
    chat_id = 'YOUR_CHAT_ID',              -- Lark chat ID
  },

  -- DingTalk
  dingtalk = {
    -- Webhook mode (one-way, simpler)
    webhook = 'https://oapi.dingtalk.com/robot/send?access_token=XXX',
    -- OR API mode (two-way, requires app credentials)
    app_key = 'YOUR_APP_KEY',
    app_secret = 'YOUR_APP_SECRET',
    conversation_id = 'YOUR_CONVERSATION_ID',
    user_id = 'YOUR_USER_ID',
  },

  -- WeCom (Enterprise WeChat)
  wecom = {
    -- Webhook mode (one-way, simpler)
    webhook_key = 'YOUR_WEBHOOK_KEY',
    -- OR API mode (two-way, requires corporate credentials)
    corp_id = 'YOUR_CORP_ID',
    corp_secret = 'YOUR_CORP_SECRET',
    agent_id = 'YOUR_AGENT_ID',
    user_id = 'YOUR_USER_ID',
  },

  -- Telegram
  telegram = {
    bot_token = 'YOUR_BOT_TOKEN',          -- Telegram bot token
    chat_id = 'YOUR_CHAT_ID',              -- Telegram chat ID
  },
},
```

**Platform Comparison:**

| Platform | Mode    | Bidirectional | Setup Complexity | Message Limit |
| -------- | ------- | ------------- | ---------------- | ------------- |
| Discord  | Bot API | ✅ Yes        | Medium           | 2,000 chars   |
| Lark     | Bot API | ✅ Yes        | Medium           | 30,720 chars  |
| DingTalk | Webhook | ❌ No         | Low              | 20,000 chars  |
| DingTalk | API     | ✅ Yes        | High             | 20,000 chars  |
| WeCom    | Webhook | ❌ No         | Low              | 2,048 chars   |
| WeCom    | API     | ✅ Yes        | High             | 2,048 chars   |
| Telegram | Bot API | ✅ Yes        | Low              | 4,096 chars   |

### Complete Configuration Example

```lua
require('chat').setup({
  -- Window settings
  width = 0.8,
  height = 0.8,
  auto_scroll = true, -- Enable smart auto-scrolling (default)
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
    api_key = 'your-secret-key-here', -- Set to empty string to disable
  },

  -- File access control
  allowed_path = {
    vim.fn.getcwd(), -- Current working directory
    vim.fn.expand('~/.config/nvim'), -- Neovim config directory
  },

  -- Other settings
  strftime = '%Y-%m-%d %H:%M',
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
    max_memories = 1000,
    retrieval_limit = 5,
    similarity_threshold = 0.25,
  },

  -- IM Integrations (configure platforms you need)
  integrations = {
    -- Discord
    discord = {
      token = 'YOUR_DISCORD_BOT_TOKEN',
      channel_id = 'YOUR_CHANNEL_ID',
    },
    -- Add other platforms as needed...
  },
  -- MCP servers configuration
  mcp = {
    --https://github.com/Aas-ee/open-webSearch
    open_webSearch = {
      command = 'npx',
      args = {
        '-y',
        'open-websearch@latest',
      },
    },
  },
})
```

### Configuration Notes

1. **Path Security**: `allowed_path` restricts which file paths tools can access. Empty string disables all file access. Recommended to set to your current project directory for security.
2. **API Keys**: Only configure keys for providers you plan to use. Providers can be switched at runtime via the picker.
3. **Memory System**: Enabled by default, automatically extracts facts and preferences from conversations. Can be disabled with `memory.enable = false`.
4. **HTTP Server**: Configure `http.api_key` to enable the HTTP server. The server binds to localhost by default for security.
5. **Dynamic Updates**: Some configurations (like provider and model) can be changed dynamically at runtime via the picker.
6. **Automatic Scrolling**: The `auto_scroll` option controls whether the result window automatically scrolls to show new content. When enabled (default), it only scrolls if the cursor was already at the bottom, preventing interruptions when reviewing history.
7. **system_prompt Function Support**: The `system_prompt` option can be either a string or a function that returns a string. When a function is provided, it is called each time a new session is created, allowing for dynamic prompts based on time, project context, or external files. The function should handle errors gracefully and return a string value.

## ⚙️ Usage

chat.nvim provides several commands to manage your AI conversations.
The main command is `:Chat`, which opens the chat window.
You can also navigate between sessions using the following commands.

### Basic Commands

| Command             | Description                                         |
| ------------------- | --------------------------------------------------- |
| `:Chat`             | Open the chat window with the current session       |
| `:Chat new`         | Start a new chat session                            |
| `:Chat prev`        | Switch to the previous chat session                 |
| `:Chat next`        | Switch to the next chat session                     |
| `:Chat delete`      | Delete current session and create new empty session |
| `:Chat clear`       | Clear all messages in current session               |
| `:Chat cd <dir>`    | Change current session cwd, open chat window        |
| `:Chat save <path>` | Save current session to specified file path         |
| `:Chat load <path>` | Load session from file path or URL                  |
| `:Chat share`       | Share current session via pastebin                  |
| `:Chat preview`     | Open HTML preview of current session in browser     |
| `:Chat bridge`      | Bind current session to external platform (Discord) |
| `:Chat mcp stop`    | Stop all MCP servers                                |
| `:Chat mcp start`   | Start all MCP servers                               |
| `:Chat mcp restart` | Restart all MCP servers                             |

### MCP Commands

Manage MCP (Model Context Protocol) servers with the following commands:

1. **Stop MCP servers**:

   ```vim
   :Chat mcp stop
   ```

   Stops all running MCP servers and cleans up resources.

2. **Start MCP servers**:

   ```vim
   :Chat mcp start
   ```

   Starts all configured MCP servers. Note: Servers are automatically started when opening the chat window.

3. **Restart MCP servers**:

   ```vim
   :Chat mcp restart
   ```

   Restarts all MCP servers (stops and starts with a delay for cleanup).

**Notes:**

- MCP servers are automatically started when you open the chat window (`:Chat`)
- MCP servers are automatically stopped when you exit Neovim
- Use these commands for manual control if needed (e.g., after changing configuration)

### Parallel Sessions

chat.nvim supports running multiple chat sessions simultaneously, with each session operating independently:

- **Independent Model Selection**: Each session can use a different AI model (e.g., Session A with DeepSeek, Session B with GitHub AI)
- **Separate Contexts**: Sessions maintain their own conversation history, working directory, and settings
- **Quick Switching**: Use `:Chat prev` and `:Chat next` to navigate between active sessions
- **Isolated Workflows**: Perfect for comparing model responses or working on multiple projects simultaneously

**Workflow Example:**

1. Start a session with DeepSeek: `:Chat new` (then select DeepSeek model)
2. Switch to GitHub AI for a different task: `:Chat new` (select GitHub model)
3. Toggle between sessions: `:Chat prev` / `:Chat next`
4. Each session preserves its unique context and conversation flow

### Examples

1. **Start a new conversation**:

   ```vim
   :Chat new
   ```

   This creates a fresh session and opens the chat window.

2. **Resume a previous conversation**:

   ```vim
   :Chat prev
   ```

   Cycles backward through your saved sessions.

3. **Switch to the next conversation**:

   ```vim
   :Chat next
   ```

   Cycles forward through your saved sessions.

4. **Open or forced to the chat window**:

   ```vim
   :Chat
   ```

   This command will not change current sessions.

5. **Delete current session**:

   ```vim
   :Chat delete
   ```

   Cycles to next session or create a new session if current session is latest one.

6. **Change the working directory of current session**:

   ```vim
   :Chat cd ../picker.nvim/
   ```

   If the current session is in progress, the working directory will not be changed,
   and a warning message will be printed.

7. **Clear messages in current session**:

   ```vim
   :Chat clear
   ```

   If the current session is in progress, a warning message will be printed,
   and current session will not be cleared. This command also will forced to chat window.

8. **Work with multiple parallel sessions**:

   ```vim
   " Start first session with DeepSeek
   :Chat new
   " Select DeepSeek as provider and choose a model

   " Start second session with GitHub AI
   :Chat new
   " Select GitHub as provider and choose a model

   " Switch between sessions
   :Chat prev  " Go to first session
   :Chat next  " Go to second session
   ```

   This enables simultaneous conversations with different AI assistants for different tasks.

9. **Save current session to a file**:

   ```vim
   :Chat save ~/sessions/my-session.json
   ```

   Saves the current session to a JSON file for backup or sharing.

10. **Load session from file**:

    ```vim
    :Chat load ~/sessions/my-session.json
    ```

    Loads a previously saved session from a JSON file.

11. **Load session from URL**:

    ```vim
    :Chat load https://paste.rs/xxxxx
    ```

    Loads a session from a URL (e.g., from paste.rs).

12. **Share current session**:

    ```vim
    :Chat share
    ```

    Uploads the current session to paste.rs and copies the URL to clipboard.
    This allows easy sharing of conversations with others.

13. **Preview current session in browser**:

    ```vim
    :Chat preview
    ```

    Opens an HTML preview of the current session in your default browser.
    The preview includes session metadata, messages, tool calls, and token usage statistics.
    You can also use `<C-o>` in the picker's chat source to open previews.

All sessions are automatically saved and can be resumed later. For more advanced session management,
see the [Picker Integration](#-picker-integration) section below.

### Key Bindings

**Note**: The plugin is currently in active development phase.
Key bindings may change and may reflect the author's personal preferences.
Configuration options for customizing key bindings are planned for future releases.

The following key bindings are available in the **Input** window:

| Mode     | Key Binding  | Description                             |
| -------- | ------------ | --------------------------------------- |
| `Normal` | `<Enter>`    | Send message                            |
| `Normal` | `q`          | Close chat window                       |
| `Normal` | `<Tab>`      | Switch between input and result windows |
| `Normal` | `Ctrl-C`     | Cancel current request                  |
| `Normal` | `Ctrl-N`     | Open new session                        |
| `Normal` | `r`          | Retry last cancelled request            |
| `Normal` | `alt-h`      | previous chat session                   |
| `Normal` | `alt-l`      | next chat session                       |
| `Normal` | `<Leader>fr` | run `:Picker chat`                      |
| `Normal` | `<Leader>fp` | run `:Picker chat_provider`             |
| `Normal` | `<Leader>fm` | run `:Picker chat_model`                |

The following key bindings are available in the **Result** window:

| Mode     | Key Binding | Description                             |
| -------- | ----------- | --------------------------------------- |
| `Normal` | `q`         | Close chat window                       |
| `Normal` | `<Tab>`     | Switch between input and result windows |

## 🤖 Providers

chat.nvim uses a two-layer architecture for AI service integration:

- **Providers**: Handle HTTP requests to specific AI services (DeepSeek, OpenAI, GitHub, etc.)
- **Protocols**: Parse API responses from different AI services (OpenAI, Anthropic, etc.)

Most AI services use OpenAI-compatible APIs, so the default protocol is `openai`. Providers can specify a custom protocol via the `protocol` field if needed.

### Built-in Providers

1. `deepseek` - [DeepSeek AI](https://platform.deepseek.com/)
2. `github` - [GitHub AI](https://github.com/features/ai)
3. `moonshot` - [Moonshot AI](https://platform.moonshot.cn/)
4. `openrouter` - [OpenRouter](https://openrouter.ai/)
5. `qwen` - [Alibaba Cloud Qwen](https://www.aliyun.com/product/bailian)
6. `siliconflow` - [SiliconFlow](https://www.siliconflow.cn/)
7. `tencent` - [Tencent Hunyuan](https://cloud.tencent.com/document/product/1729)
8. `bigmodel` - [BigModel AI](https://bigmodel.cn/)
9. `volcengine` - [Volcengine AI](https://console.volcengine.com)
10. `openai` - [OpenAI](https://developers.openai.com/api/docs/)
11. `anthropic` - [Anthropic Claude](https://www.anthropic.com/)
12. `gemini` - [Google Gemini](https://ai.google.dev/)
13. `ollama` - [Ollama](https://ollama.ai/)
14. `longcat` - [LongCat AI](https://longcat.chat/platform/docs/)
15. `cherryin` - [CherryIN AI](https://open.cherryin.ai/)
16. `yuanjing` - [yuanjing AI](https://maas.ai-yuanjing.com/)

**Note**: Most built-in providers use the OpenAI protocol by default. Exceptions:

- `anthropic` uses the Anthropic protocol
- `gemini` uses the Gemini protocol

### Custom Providers

You can create custom providers for AI services not in the built-in list. Create a file at `~/.config/nvim/lua/chat/providers/<provider_name>.lua`.

A provider module must implement:

1. **`available_models()`** - Return a list of available model names
2. **`request(opt)`** - Send HTTP request and return job ID

**Optional fields:**

- **`protocol`** - Specify which protocol to use (default: `openai`)

**Example custom provider:**

```lua
-- ~/.config/nvim/lua/chat/providers/my_provider.lua
local M = {}
local job = require('job')
local sessions = require('chat.sessions')
local config = require('chat.config')

function M.available_models()
  return {
    'model-1',
    'model-2',
  }
end

function M.request(opt)
  local cmd = {
    'curl',
    '-s',
    'https://api.example.com/v1/chat/completions',
    '-H',
    'Content-Type: application/json',
    '-H',
    'Authorization: Bearer ' .. config.config.api_key.my_provider,
    '-X',
    'POST',
    '-d',
    '@-',
  }

  local body = vim.json.encode({
    model = sessions.get_session_model(opt.session),
    messages = opt.messages,
    stream = true,
    stream_options = { include_usage = true },
    tools = require('chat.tools').available_tools(),
  })

  local jobid = job.start(cmd, {
    on_stdout = opt.on_stdout,
    on_stderr = opt.on_stderr,
    on_exit = opt.on_exit,
  })
  job.send(jobid, body)
  job.send(jobid, nil)
  sessions.set_session_jobid(opt.session, jobid)

  return jobid
end

-- Optional: specify custom protocol (defaults to 'openai')
-- M.protocol = 'anthropic'

return M
```

### Protocols

Protocols handle parsing of API responses. Currently, chat.nvim supports:

- **`openai`**: OpenAI-compatible API format (default for all built-in providers)
- **`anthropic`**: Anthropic Claude API format
- **`gemini`**: Google Gemini API format

If you need a custom protocol, create a file at `~/.config/nvim/lua/chat/protocols/<protocol_name>.lua` and implement:

- `on_stdout(id, data)` - Handle stdout data from curl
- `on_stderr(id, data)` - Handle stderr data
- `on_exit(id, code, signal)` - Handle request completion

See `lua/chat/protocol/openai.lua` for reference implementation.

## 🛠️ Tools

chat.nvim supports tool call functionality, allowing the AI assistant to interact with your filesystem, manage memories, and perform other operations during conversations. Tools are invoked using the `@tool_name` syntax directly in your messages.

### MCP Tools

MCP (Model Context Protocol) tools are automatically discovered and integrated when MCP servers are configured. These tools follow the naming pattern `mcp_<server>_<tool>` and work seamlessly with built-in tools.

**Example MCP Tools:**

- `mcp_open_webSearch_search` - Web search via MCP server
- `mcp_open_webSearch_fetchGithubReadme` - Fetch GitHub README via MCP
- `mcp_open_webSearch_fetchCsdnArticle` - Fetch CSDN article via MCP

MCP tools are automatically available when their servers are configured in the `mcp` section of your setup configuration. See [MCP Server Configuration](#mcp-server-configuration) for details.

**Using MCP Tools:**

```
@mcp_open_webSearch_search query="neovim plugins" engines=["bing"] limit=10
@mcp_open_webSearch_fetchGithubReadme url="https://github.com/wsdjeg/chat.nvim"
```

MCP tools support all parameter types defined by their servers and execute asynchronously without blocking Neovim's UI.

### Available Tools

#### `read_file`

Reads the content of a file and makes it available to the AI assistant.

**Usage:**

```
@read_file <filepath>
```

**Examples:**

- `@read_file ./src/main.lua` - Read a Lua file in the current directory
- `@read_file /etc/hosts` - Read a system file using absolute path
- `@read_file ../config.json` - Read a file from a parent directory

**Advanced Usage with Line Ranges:**

```
@read_file ./src/main.lua line_start=10 line_to=20
```

**Notes:**

- File paths can be relative to the current working directory or absolute
- Supports line range selection with `line_start` and `line_to` parameters
- Line numbers are 1-indexed (first line is line 1)
- If `line_start` is not specified, defaults to line 1
- If `line_to` is not specified, defaults to last line
- The AI will receive the file content for context
- This is particularly useful for code review, debugging, or analyzing configuration files

#### `find_files`

Finds files in the current working directory that match a given pattern.

**Usage:**

```
@find_files <pattern>
```

**Examples:**

- `@find_files *.lua` - Find all Lua files in the current directory
- `@find_files **/*.md` - Recursively find all Markdown files
- `@find_files src/**/*.js` - Find JavaScript files in the `src` directory and its subdirectories
- `@find_files README*` - Find files starting with "README"

**Notes:**

- Uses ripgrep (rg) for fast file finding with glob pattern support
- Smart case: lowercase patterns are case-insensitive, uppercase are case-sensitive
- Supports additional parameters: `directory`, `hidden`, `no_ignore`, `exclude`
- Searches are limited to the current working directory
- Returns a list of found files, with one file path per line
- File searching is restricted by the `allowed_path` configuration setting

#### `search_text`

Advanced text search tool using ripgrep (rg) to search text content in directories with regex support, file type filtering, exclusion patterns, and other advanced features.

**Usage:**

```
@search_text <pattern> [options]
```

**Basic Examples:**

- `@search_text "function.*test"` - Search for regex pattern in current directory
- `@search_text "TODO:" --file-types "*.lua"` - Search TODO comments in Lua files
- `@search_text "error" --context-lines 2` - Search for "error" with 2 lines of context

**Advanced Usage with JSON Parameters:**

For more complex searches, you can provide a JSON object with multiple parameters:

```
@search_text {"pattern": "function.*test", "directory": "./src", "file_types": ["*.lua", "*.vim"], "ignore_case": true, "max_results": 50}
```

**Parameters:**

| Parameter          | Type    | Description                                                      |
| ------------------ | ------- | ---------------------------------------------------------------- |
| `pattern`          | string  | **Required**. Text pattern to search for (supports regex)        |
| `directory`        | string  | Directory path to search in (default: current working directory) |
| `ignore_case`      | boolean | Whether to ignore case (default: false)                          |
| `regex`            | boolean | Whether to use regex (default: true)                             |
| `max_results`      | integer | Maximum number of results (default: 100)                         |
| `context_lines`    | integer | Number of context lines to show around matches (default: 0)      |
| `whole_word`       | boolean | Whether to match whole words only (default: false)               |
| `file_types`       | array   | File type filter, e.g., `["*.py", "*.md", "*.txt"]`              |
| `exclude_patterns` | array   | Exclude file patterns, e.g., `["*.log", "node_modules/*"]`       |

**More Examples:**

1. **Case-insensitive search:**

   ```
   @search_text {"pattern": "config", "ignore_case": true}
   ```

2. **Search with file type filtering:**

   ```
   @search_text {"pattern": "function", "file_types": ["*.lua", "*.vim"]}
   ```

3. **Search with context and exclusions:**

   ```
   @search_text {"pattern": "FIXME", "context_lines": 3, "exclude_patterns": ["*.log", "node_modules/*"]}
   ```

4. **Whole word matching:**
   ```
   @search_text {"pattern": "test", "whole_word": true}
   ```

**Notes:**

- Uses ripgrep (rg) for fast, powerful text searching
- Supports full regex syntax for complex pattern matching
- Search is restricted by the `allowed_path` configuration setting
- Returns matching lines with file paths and line numbers
- If no matches are found, returns an informative message
- Particularly useful for code analysis, debugging, and finding references

#### `extract_memory`

Extract memories from conversation text into a three-tier memory system (working, daily, long-term). Automatically detects memory type and category based on content analysis.

**Usage:**

```
@extract_memory <parameters>
```

**Memory Types:**

| Type        | Icon | Lifetime     | Priority | Use Case                                   |
| ----------- | ---- | ------------ | -------- | ------------------------------------------ |
| `working`   | ⚡   | Session only | Highest  | Current tasks, decisions, active context   |
| `daily`     | 📅   | 7-30 days    | Medium   | Short-term goals, today's tasks, reminders |
| `long_term` | 💾   | Permanent    | Normal   | Facts, preferences, skills, knowledge      |

**Basic Examples:**

- `@extract_memory text="Python的GIL是全局解释器锁，我习惯用Vim写代码"` (auto-detect type and category)
- `@extract_memory text="今天要完成用户登录功能" memory_type="daily"` (force daily memory)
- `@extract_memory text="当前正在修复登录bug" memory_type="working"` (force working memory)

**Advanced Examples:**

1. **Extract with specific type and category:**

   ```
   @extract_memory text="Python的GIL是全局解释器锁" memory_type="long_term" category="fact"
   ```

2. **Extract working memory with importance:**

   ```
   @extract_memory text="当前任务：实现用户认证" memory_type="working" importance="high"
   ```

3. **Extract daily memory:**

   ```
   @extract_memory text="今天下午3点有会议" memory_type="daily" category="event"
   ```

4. **Batch extract multiple memories:**

   ```
   @extract_memory memories='[{"content":"事实1","category":"fact","memory_type":"long_term"},{"content":"偏好1","category":"preference"}]'
   ```

**Parameters:**

| Parameter     | Type   | Description                                                                            |
| ------------- | ------ | -------------------------------------------------------------------------------------- |
| `text`        | string | Text to analyze for memory extraction                                                  |
| `memories`    | array  | Pre-extracted memories array (alternative to `text` parameter)                         |
| `memory_type` | string | Memory type: `"long_term"`, `"daily"`, or `"working"` (auto-detected if not set)       |
| `category`    | string | Category: `"fact"`, `"preference"`, `"skill"`, or `"event"` (auto-detected if not set) |

**Memory Object Structure (for `memories` array):**

```json
{
  "content": "Memory content text",
  "memory_type": "working", // Optional: auto-detected if not specified
  "category": "fact", // Optional: auto-detected if not specified
  "work_type": "task", // Optional: only for working memory
  "importance": "high" // Optional: only for working memory
}
```

**Category Definitions:**

- **fact**: Verifiable objective facts, data, definitions, rules
- **preference**: Personal habits, routine behaviors, regular practices
- **skill**: Technical abilities and knowledge
- **event**: Specific events and occurrences

**Working Memory Types:**

- **general**: General information
- **task**: Current task or goal
- **decision**: Decision or choice made
- **context**: Contextual information
- **issue**: Issue or problem encountered

**Auto-Detection Rules:**

The system automatically detects memory type based on keywords:

- **Working Memory**: "当前/正在/current", "任务/task", "决策/decision", "问题/issue"
- **Daily Memory**: "今天/明天/today/tomorrow", "待办/todo", "临时/temporary"
- **Long-term Memory**: Other persistent information

**Notes:**

- Extracts only persistent and reusable information
- Automatically detects categories and memory types based on keywords
- Supports both raw text analysis and pre-processed memories
- Working memory has highest priority and is cleared when session ends
- Daily memory expires after configured retention days (default: 7)
- Long-term memory persists permanently
- Memory system must be enabled in chat.nvim configuration

#### `recall_memory`

Retrieve relevant information from the three-tier memory system with priority-based ranking. Automatically extracts keywords if no query is provided.

**Usage:**

```
@recall_memory <parameters>
```

**Memory Priority Order:**

1. ⚡ **Working Memory** - Current session tasks/decisions (highest priority)
2. 📅 **Daily Memory** - Recent temporary information (medium priority)
3. 💾 **Long-term Memory** - Permanent knowledge base (normal priority)

**Basic Examples:**

- `@recall_memory query="vim configuration"` - Search all memory types
- `@recall_memory` - Auto-extract keywords from current conversation
- `@recall_memory query="current task" memory_type="working"` - Search only working memory
- `@recall_memory query="today" memory_type="daily"` - Search only daily memory
- `@recall_memory query="python" memory_type="long_term"` - Search only long-term memory

**Advanced Examples:**

1. **Search with limit:**

   ```
   @recall_memory query="programming tips" limit=8
   ```

2. **Filter by memory type:**

   ```
   @recall_memory query="current task" memory_type="working"
   ```

3. **Search across all sessions:**

   ```
   @recall_memory query="vim" all_sessions=true
   ```

4. **Auto-extract from conversation:**

   ```
   @recall_memory
   ```

**Parameters:**

| Parameter      | Type    | Description                                                                |
| -------------- | ------- | -------------------------------------------------------------------------- |
| `query`        | string  | Search query (optional, auto-extracted from last message if not provided)  |
| `memory_type`  | string  | Filter by memory type: `"working"`, `"daily"`, or `"long_term"` (optional) |
| `limit`        | integer | Number of results (default: 5, maximum: 10)                                |
| `all_sessions` | boolean | Search all sessions instead of just current (default: false)               |

**Output Format:**

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

**Notes:**

- Returns formatted memory list that AI can reference for responses
- Searches across all memory types with priority ranking
- Working memory has highest priority and session isolation
- Daily memory shows expiration countdown
- Long-term memory shows access frequency
- Shows timestamps and contextual information
- Memory system must be enabled in chat.nvim configuration
- Useful for maintaining context across conversations

#### `set_prompt`

Read a prompt file and set it as the current session's system prompt.

**Usage:**

```
@set_prompt <filepath>
```

**Examples:**

- `@set_prompt ./AGENTS.md`
- `@set_prompt ./prompts/code_review.txt`
- `@set_prompt ~/.config/chat.nvim/default_prompt.md`

**Parameters:**

| Parameter  | Type   | Description         |
| ---------- | ------ | ------------------- |
| `filepath` | string | Path to prompt file |

**Notes:**

- Updates the current session's system prompt with file content
- File must be within the `allowed_path` configured in chat.nvim
- Useful for switching between different agent roles or task-specific prompts
- Supports relative and absolute paths

#### `fetch_web`

Fetch content from web URLs using curl with comprehensive HTTP support.

**Usage:**

```
@fetch_web <parameters>
```

**Basic Examples:**

- `@fetch_web url="https://example.com"` - Fetch content from a URL
- `@fetch_web url="https://api.github.com/repos/neovim/neovim" timeout=60 user_agent="MyApp/1.0"` - Fetch with custom timeout and user agent
- `@fetch_web url="https://api.github.com/user" headers=["Authorization: Bearer token123"]` - Fetch with custom headers
- `@fetch_web url="https://api.example.com/data" method="POST" data='{"key":"value"}' headers=["Content-Type: application/json"]` - POST request with JSON data
- `@fetch_web url="https://self-signed.example.com" insecure=true` - Disable SSL verification (testing only)
- `@fetch_web url="https://example.com/redirect" max_redirects=2` - Limit redirects

**Advanced Usage with JSON Parameters:**

For complex requests, you can provide a JSON object:

```
@fetch_web {"url": "https://example.com", "method": "POST", "data": "{\"key\":\"value\"}", "headers": ["Content-Type: application/json"], "timeout": 30}
```

**Parameters:**

| Parameter       | Type    | Description                                                                                            |
| --------------- | ------- | ------------------------------------------------------------------------------------------------------ |
| `url`           | string  | **Required**. URL to fetch (must start with http:// or https://)                                       |
| `method`        | string  | HTTP method (default: "GET", options: GET, POST, PUT, DELETE, PATCH, HEAD)                             |
| `headers`       | array   | Additional HTTP headers as strings (e.g., ["Authorization: Bearer token", "Accept: application/json"]) |
| `data`          | string  | Request body data for POST/PUT requests                                                                |
| `timeout`       | integer | Timeout in seconds (default: 30, minimum: 1, maximum: 300)                                             |
| `user_agent`    | string  | Custom User-Agent header string (default: "Mozilla/5.0 (compatible; chat.nvim)")                       |
| `insecure`      | boolean | Disable SSL certificate verification (use with caution, for testing only)                              |
| `max_redirects` | integer | Maximum number of redirects to follow (default: 5, set to 0 to disable)                                |
| `output`        | string  | Save response to file instead of displaying (e.g., "./response.html")                                  |

**More Examples:**

1. **Basic GET request:**

   ```
   @fetch_web url="https://jsonplaceholder.typicode.com/posts/1"
   ```

2. **POST request with JSON data:**

   ```
   @fetch_web url="https://api.example.com/users" method="POST" data='{"name": "John", "age": 30}' headers=["Content-Type: application/json"]
   ```

3. **With authentication header:**

   ```
   @fetch_web url="https://api.github.com/user/repos" headers=["Authorization: Bearer YOUR_TOKEN", "Accept: application/vnd.github.v3+json"]
   ```

4. **Save response to file:**

   ```
   @fetch_web url="https://example.com" output="./downloaded_page.html"
   ```

5. **Configure timeout and SSL verification:**
   ```
   @fetch_web url="https://slow-api.example.com" timeout=60 insecure=true
   ```

**Notes:**

- Uses curl internally for HTTP/HTTPS requests
- Requires curl to be installed and available in PATH
- SSL verification is enabled by default (disable with `insecure=true` for testing)
- Responses are limited to 10,000 characters for display
- For large responses, use the `output` parameter to save to a file
- Compression is automatically requested
- Timeout defaults to 30 seconds to prevent hanging
- User agent identifies as chat.nvim by default
- Only HTTP/HTTPS URLs are allowed (no file://, ftp://, etc.)
- Particularly useful for fetching API data, web scraping, or downloading content

#### `web_search`

Search the web using Firecrawl, Google Custom Search API, or SerpAPI.

**Usage:**

```
@web_search <parameters>
```

**Supported Engines:**

1. **Firecrawl** (default): https://firecrawl.dev
2. **Google**: Google Custom Search JSON API
3. **SerpAPI**: https://serpapi.com - supports multiple search engines (Google, Bing, DuckDuckGo, etc.)

**Configuration:**

API keys must be set in chat.nvim configuration:

```lua
require('chat').setup({
  api_key = {
    firecrawl = 'fc-YOUR_API_KEY',
    google = 'YOUR_GOOGLE_API_KEY',
    google_cx = 'YOUR_SEARCH_ENGINE_ID',
    serpapi = 'YOUR_SERPAPI_KEY'
  }
})
```

Alternatively, provide API keys directly as parameters.

**Examples:**

1. Basic Firecrawl search:

   ```
   @web_search query="firecrawl web scraping"
   ```

2. Firecrawl with result limit:

   ```
   @web_search query="neovim plugins" limit=10
   ```

3. Google search:

   ```
   @web_search query="latest news" engine="google"
   ```

4. Google search with custom API key and cx:

   ```
   @web_search query="test" engine="google" api_key="GOOGLE_API_KEY" cx="SEARCH_ENGINE_ID"
   ```

5. SerpAPI with Google (default):

   ```
   @web_search query="neovim plugins" engine="serpapi"
   ```

6. SerpAPI with Bing:

   ```
   @web_search query="latest news" engine="serpapi" serpapi_engine="bing"
   ```

7. SerpAPI with DuckDuckGo:

   ```
   @web_search query="privacy tools" engine="serpapi" serpapi_engine="duckduckgo"
   ```

8. Custom timeout:

   ```
   @web_search query="slow site" timeout=60
   ```

9. Firecrawl with scrape options:
   ```
   @web_search query="news" scrape_options={"formats":["markdown"]}
   ```

**Parameters:**

| Parameter        | Type    | Description                                                                                        |
| ---------------- | ------- | -------------------------------------------------------------------------------------------------- |
| `query`          | string  | **Required**. Search query string                                                                  |
| `engine`         | string  | Search engine to use: `"firecrawl"`, `"google"`, or `"serpapi"` (default: `"firecrawl"`)           |
| `limit`          | integer | Number of results to return (default: 5 for firecrawl, 10 for google/serpapi)                      |
| `scrape_options` | object  | Options for scraping result pages (Firecrawl only, see Firecrawl docs)                             |
| `api_key`        | string  | API key (optional if configured in config)                                                         |
| `cx`             | string  | Google Custom Search engine ID (required for Google engine if not in config)                       |
| `timeout`        | integer | Timeout in seconds (default: 30, minimum: 1, maximum: 300)                                         |
| `serpapi_engine` | string  | SerpAPI search engine: `"google"`, `"bing"`, `"duckduckgo"`, `"yahoo"`, `"baidu"`, etc. (optional) |

**SerpAPI Search Engines:**

When using SerpAPI, you can specify different search engines via the `serpapi_engine` parameter:

| Engine       | Description      |
| ------------ | ---------------- |
| `google`     | Google Search    |
| `bing`       | Microsoft Bing   |
| `duckduckgo` | DuckDuckGo       |
| `yahoo`      | Yahoo Search     |
| `baidu`      | Baidu            |
| `yandex`     | Yandex           |
| `ebay`       | eBay Search      |
| ...and more  | See SerpAPI docs |

**Notes:**

- Requires curl to be installed and available in PATH
- Firecrawl API key is required for Firecrawl searches
- Google API key and Custom Search engine ID (cx) are required for Google searches
- SerpAPI key is required for SerpAPI searches
- SerpAPI supports multiple search engines (Google, Bing, DuckDuckGo, etc.) through the `serpapi_engine` parameter
- Search results are returned in a formatted list with titles, URLs, and snippets
- Supports both Firecrawl, Google, and SerpAPI search engines with configurable options

#### `git_diff`

Run git diff to compare changes between working directory, index, or different branches.

**Usage:**

```
@git_diff <parameters>
```

**Basic Examples:**

- `@git_diff` - Show all unstaged changes in the repository
- `@git_diff cached=true` - Show staged changes (--cached)
- `@git_diff branch="main"` - Compare working directory with main branch
- `@git_diff path="./src"` - Show changes for specific file or directory
- `@git_diff branch="master" cached=true` - Compare staged changes with master branch

**Advanced Usage with JSON Parameters:**

For more complex comparisons, you can provide a JSON object:

```
@git_diff {"path": "./lua/chat", "branch": "develop", "cached": true}
```

**Parameters:**

| Parameter | Type    | Description                                                          |
| --------- | ------- | -------------------------------------------------------------------- |
| `path`    | string  | File or directory path to show diff for (optional)                   |
| `cached`  | boolean | Show staged changes (git diff --cached) (optional)                   |
| `branch`  | string  | Branch to compare against (e.g., "master", "origin/main") (optional) |

**More Examples:**

1. **View all unstaged changes:**

   ```
   @git_diff
   ```

2. **View staged changes only:**

   ```
   @git_diff cached=true
   ```

3. **Compare with another branch:**

   ```
   @git_diff branch="main"
   ```

4. **Check changes in specific file:**

   ```
   @git_diff path="./lua/chat/tools/git_diff.lua"
   ```

5. **Compare staged changes with master branch:**

   ```
   @git_diff branch="master" cached=true
   ```

6. **Combined usage:**
   ```
   @git_diff {"path": "./lua/chat/tools", "branch": "develop", "cached": false}
   ```

**Notes:**

- Requires git to be installed and available in PATH
- If no parameters are provided, shows all unstaged changes in the repository
- The `cached` flag shows changes that are staged (git diff --cached)
- The `branch` parameter allows comparing with another branch (git diff <branch>)
- The `path` parameter restricts diff output to specific file or directory
- Returns formatted git diff output with file names and change summaries
- Particularly useful for code review, version control, and change tracking
- **Asynchronous Execution**: This tool runs asynchronously without blocking Neovim's UI

#### `git_log`

Show commit logs with various filters and options.

**Usage:**

```
@git_log [parameters]
```

**Basic Examples:**

- `@git_log` - Show last 5 commits (default)
- `@git_log count=10` - Show last 10 commits
- `@git_log count=0` - Show all commits (no limit)
- `@git_log path="./src/main.lua"` - Show commits for specific file
- `@git_log author="john"` - Filter by author
- `@git_log since="2024-01-01"` - Commits since date
- `@git_log from="v1.4.0"` - Commits from tag to HEAD
- `@git_log from="v1.0.0" to="v2.0.0"` - Commits between tags
- `@git_log grep="fix"` - Search in commit messages

**Parameters:**

| Parameter  | Type    | Description                                                          |
| ---------- | ------- | -------------------------------------------------------------------- |
| `path`     | string  | File or directory path (default: current working directory)          |
| `count`    | integer | Limit number of commits (default: 5, use 0 for no limit)             |
| `oneline`  | boolean | Show each commit on a single line (default: true)                    |
| `author`   | string  | Filter commits by author name or email                               |
| `since`    | string  | Show commits after this date (e.g., "2024-01-01", "2 weeks ago")     |
| `from`     | string  | Starting tag/commit for range (e.g., "v1.4.0")                        |
| `to`       | string  | Ending tag/commit for range (default: HEAD)                          |
| `grep`     | string  | Search for pattern in commit messages                                |

**Notes:**

- Requires git to be installed and available in PATH
- If filters are set (author/since/grep/from/to), count defaults to no limit
- Date formats: "2024-01-01", "2 weeks ago", "yesterday", etc.
- Grep supports regex patterns in commit messages

#### `get_history`

Get conversation history messages from the current session.

**Usage:**

```
@get_history [parameters]
```

**Basic Examples:**

- `@get_history` - Get first 20 messages (default)
- `@get_history offset=0 limit=20` - Get first 20 messages (oldest)
- `@get_history offset=20 limit=20` - Get messages 21-40
- `@get_history offset=0 limit=50` - Get first 50 messages (max)

**Parameters:**

| Parameter | Type    | Description                                           |
| --------- | ------- | ----------------------------------------------------- |
| `offset`  | integer | Starting index (0 = oldest message, default: 0)       |
| `limit`   | integer | Number of messages to retrieve (default: 20, max: 50) |

**Notes:**

- Use this tool when you need to reference earlier messages not in current context window
- Returns messages with their role, content, and timestamp
- Maximum 50 messages per request
- Useful for maintaining context across long conversations

#### `plan`

Plan mode for creating, managing, and reviewing task plans with step-by-step tracking.

**Usage:**

```
@plan action="<action>" [parameters]
```

**Actions:**

| Action   | Description                                   |
| -------- | --------------------------------------------- |
| `create` | Create new plan with title and optional steps |
| `show`   | Show plan details by ID                       |
| `list`   | List all plans (optional status filter)       |
| `add`    | Add step to existing plan                     |
| `next`   | Start next pending step                       |
| `done`   | Mark current/completed step as done           |
| `review` | Review completed plan with summary            |
| `delete` | Delete a plan                                 |

**Basic Examples:**

1. **Create a new plan:**

   ```
   @plan action="create" title="Implement feature X" steps=["Design API", "Write code", "Test"]
   ```

2. **List all plans:**

   ```
   @plan action="list"
   ```

3. **List plans with status filter:**

   ```
   @plan action="list" status="in_progress"
   ```

4. **Show plan details:**

   ```
   @plan action="show" plan_id="plan-20250110-1234"
   ```

5. **Start next step:**

   ```
   @plan action="next" plan_id="plan-20250110-1234"
   ```

6. **Complete a step:**

   ```
   @plan action="done" plan_id="plan-20250110-1234" step_id=1
   ```

7. **Add step to existing plan:**

   ```
   @plan action="add" plan_id="plan-20250110-1234" step_content="Add documentation"
   ```

8. **Review completed plan:**

   ```
   @plan action="review" plan_id="plan-20250110-1234" summary="Feature implemented successfully" lessons=["Lesson 1", "Lesson 2"]
   ```

9. **Delete a plan:**

   ```
   @plan action="delete" plan_id="plan-20250110-1234"
   ```

**Advanced Usage with JSON Parameters:**

For more complex operations, you can provide a JSON object:

```
@plan {"action": "create", "title": "Refactor codebase", "steps": ["Analyze current structure", "Design new architecture", "Migrate modules", "Update tests"]}
```

**Parameters:**

| Parameter      | Type    | Description                                                                                |
| -------------- | ------- | ------------------------------------------------------------------------------------------ |
| `action`       | string  | **Required**. Plan action to perform (create, show, list, add, next, done, review, delete) |
| `title`        | string  | Plan title (required for create action)                                                    |
| `steps`        | array   | Initial steps array (optional for create action)                                           |
| `plan_id`      | string  | Plan ID (required for show, add, next, done, review, delete)                               |
| `step_content` | string  | Step content (required for add action)                                                     |
| `step_id`      | integer | Step ID (required for done action, auto-detected if not provided)                          |
| `notes`        | string  | Notes for step completion (optional for done action)                                       |
| `status`       | string  | Filter by status for list action (pending, in_progress, completed)                         |
| `summary`      | string  | Plan summary (for review action)                                                           |
| `lessons`      | array   | Lessons learned (for review action)                                                        |
| `issues`       | array   | Issues encountered (for review action)                                                     |

**Workflow Example:**

1. **Create a plan:**

   ```
   @plan action="create" title="Build REST API" steps=["Design endpoints", "Implement handlers", "Add authentication", "Write tests", "Deploy"]
   ```

   Response: `✅ Plan created: **Build REST API** ID: plan-20250115-5678`

2. **Start first step:**

   ```
   @plan action="next" plan_id="plan-20250115-5678"
   ```

   Response: `⏳ **Started Step 1:** Design endpoints`

3. **Complete the step:**

   ```
   @plan action="done" plan_id="plan-20250115-5678" notes="API endpoints documented"
   ```

   Response: `✅ **Completed Step 1:** Design endpoints`

4. **Continue with remaining steps...**

5. **Review the plan:**

   ```
   @plan action="review" plan_id="plan-20250115-5678" summary="API successfully built and deployed" lessons=["Test early", "Document as you go"]
   ```

**Notes:**

- Requires memory system to be enabled in chat.nvim configuration (`memory.enable = true`)
- Plans are automatically saved to `plans.json` in the memory storage directory
- Plan IDs follow the format `plan-YYYYMMDD-XXXX` (e.g., `plan-20250110-1234`)
- Steps are automatically tracked with status: pending, in_progress, completed
- When completing a step without `step_id`, the tool auto-detects the current in-progress step
- Plan reviews are stored in long-term memory for future reference
- Supports progress tracking with visual indicators (✅ completed, ⏳ in progress, ⬜ pending)
- Particularly useful for task management, project planning, and workflow organization

### Third-party Tools

#### `zettelkasten_create`

Create new zettelkasten notes, provided by [zettelkasten.nvim](https://github.com/wsdjeg/zettelkasten.nvim).

**Usage:**

```
@zettelkasten_create <parameters>
```

**Parameters:**

| Parameter | Type   | Description                        |
| --------- | ------ | ---------------------------------- |
| `title`   | string | The title of zettelkasten note     |
| `content` | string | The note body of zettelkasten      |
| `tags`    | array  | Optional tags for the note (max 3) |

**Notes:**

- Creates a new zettelkasten note with specified title and content
- Tags should be in English and limited to 3 to avoid synonyms
- Integration with zettelkasten.nvim plugin

#### `zettelkasten_get`

Retrieve zettelkasten notes by tags, provided by [zettelkasten.nvim](https://github.com/wsdjeg/zettelkasten.nvim).

**Usage:**

```
@zettelkasten_get <tags>
```

**Parameters:**

| Parameter | Type  | Description                                         |
| --------- | ----- | --------------------------------------------------- |
| `tags`    | array | Tags to search for (e.g., `["programming", "vim"]`) |

**Notes:**

- Returns JSON object containing matching notes
- Each note includes `file_name` and `title` fields
- Tags should be in English
- Integration with zettelkasten.nvim plugin

### How to Use Tools

1. **Direct invocation**: Include the tool call directly in your message:

   ```
   Can you review this code? @read_file ./my_script.lua
   ```

2. **Multiple tools**: Combine multiple tools in a single message:

   ```
   Compare these two configs: @read_file ./config1.json @read_file ./config2.json
   ```

3. **Natural integration**: The tool calls can be embedded naturally within your questions:

   ```
   What's wrong with this function? @read_file ./utils.lua
   ```

4. **Memory management**: Use memory tools for context-aware conversations:
   ```
   Based on what we discussed earlier about Vim: @recall_memory query="vim"
   ```

The AI assistant will process the tool calls, execute the specified operations, and incorporate their results into its response. This enables more context-aware assistance without needing to manually copy-paste file contents or repeat previous information.

### Custom Tools

chat.nvim supports both synchronous and **asynchronous** custom tools. Users can create `lua/chat/tools/<tool_name>.lua` file in their Neovim runtime path.

This module should provide at least two functions: `scheme()` and `<tool_name>` function. The `scheme()` function returns a table describing the tool's schema (name, description, parameters). The `<tool_name>` function is the actual implementation that will be called when the tool is invoked.

**Synchronous Tool**: Returns `{ content = "..." }` or `{ error = "..." }` directly.

**Asynchronous Tool**: Returns `{ jobid = <number> }` and calls `ctx.callback({ content = "..." })` when done.

#### Synchronous Tool Example

Here is an example for a synchronous `get_weather` tool:

```lua
local M = {}

---@param action { city: string, unit?: string }
function M.get_weather(action)
  if not action.city or action.city == '' then
    return { error = 'City name is required for weather information.' }
  end

  -- ... synchronous implementation ...

  return { content = 'Weather in ...' }
end

function M.scheme()
  return {
    type = 'function',
    ['function'] = {
      name = 'get_weather',
      description = 'Get weather information for a specific city.',
      parameters = { ... },
    },
  }
end

return M
```

#### Asynchronous Tool Example

For long-running operations, you can create asynchronous tools using `job.nvim`:

```lua
local M = {}
local job = require('job')

---@param action { url: string }
---@param ctx { cwd: string, session: string, callback: function }
function M.fetch_data(action, ctx)
  if not action.url or action.url == '' then
    return { error = 'URL is required.' }
  end

  local stdout = {}
  local stderr = {}

  local jobid = job.start({
    'curl',
    '-s',
    action.url,
  }, {
    on_stdout = function(_, data)
      for _, v in ipairs(data) do
        table.insert(stdout, v)
      end
    end,
    on_stderr = function(_, data)
      for _, v in ipairs(data) do
        table.insert(stderr, v)
      end
    end,
    on_exit = function(id, code, signal)
      if code == 0 and signal == 0 then
        -- Call the callback with the result
        ctx.callback({
          content = table.concat(stdout, '\n'),
          jobid = id,
        })
      else
        ctx.callback({
          error = 'Failed to fetch data: ' .. table.concat(stderr, '\n'),
          jobid = id,
        })
      end
    end,
  })

  -- Return jobid to indicate async execution
  if jobid > 0 then
    return { jobid = jobid }
  else
    return { error = 'Failed to start job' }
  end
end

function M.scheme()
  return {
    type = 'function',
    ['function'] = {
      name = 'fetch_data',
      description = 'Fetch data from a URL asynchronously.',
      parameters = {
        type = 'object',
        properties = {
          url = {
            type = 'string',
            description = 'URL to fetch data from',
          },
        },
        required = { 'url' },
      },
    },
  }
end

return M
```

**Key Points for Asynchronous Tools:**

1. Accept a second `ctx` parameter containing `{ cwd, session, callback }`
2. Return `{ jobid = <number> }` when starting async operation
3. Call `ctx.callback({ content = "..." })` or `ctx.callback({ error = "..." })` when done
4. The callback must include `jobid` in the result to match the async tracking
5. chat.nvim will wait for all async tools to complete before sending results to AI

## 🌐 HTTP API

chat.nvim includes a built-in HTTP server that allows external applications to send messages to your chat sessions. This enables integration with other tools, scripts, and automation workflows.

### Enabling the HTTP Server

The HTTP server is automatically started when the `http.api_key` configuration is set to a non-empty value:

```lua
require('chat').setup({
  -- ... other configuration
  http = {
    host = '127.0.0.1',    -- Default: '127.0.0.1'
    port = 7777,           -- Default: 7777
    api_key = 'your-secret-key', -- Required to enable server
  },
})
```

### API Endpoints

chat.nvim provides the following HTTP API endpoints for external integration:

| Endpoint    | Method | Description                                             |
| ----------- | ------ | ------------------------------------------------------- |
| `/`         | POST   | Send messages to a specified chat session               |
| `/sessions` | GET    | Get a list of all active session IDs                    |
| `/session`  | GET    | Get HTML preview of a session (requires `id` parameter) |

**Base URL**: `http://{host}:{port}/` where `{host}` and `{port}` are configured in your chat.nvim settings (default: `127.0.0.1:7777`)

**Authentication**: All requests require the `X-API-Key` header containing your configured API key.

**Example Usage**:

```bash
# Send message to session
curl -X POST http://127.0.0.1:7777/ \
  -H "X-API-Key: your-secret-key" \
  -H "Content-Type: application/json" \
  -d '{"session": "my-session", "content": "Hello from curl!"}'

# Get session list
curl -H "X-API-Key: your-secret-key" http://127.0.0.1:7777/sessions
```

For detailed request/response formats and examples, see the sections below.

### Request Format

```json
{
  "session": "session-id",
  "content": "Message content from external application"
}
```

**Parameters:**

| Parameter | Type   | Description                                 |
| --------- | ------ | ------------------------------------------- |
| `session` | string | Chat session ID.                            |
| `content` | string | Message content to send to the chat session |

### Response Format

#### POST `/`

- **Success**: HTTP 204 No Content
- **Authentication Error**: HTTP 401 Unauthorized (invalid or missing API key)
- **Validation Error**: HTTP 400 Bad Request (invalid JSON or missing required fields)
- **Method/Path Error**: HTTP 404 Not Found (wrong method or path)

#### GET `/sessions`

- **Success**: HTTP 200 OK, returns a JSON array of session IDs
  ```json
  [
    "2024-01-15-10-30-00",
    "2024-01-15-11-45-00",
    "2024-01-16-09-20-00"
  ]  # Example output: array of session ID strings
  ```
- **Authentication Error**: HTTP 401 Unauthorized (invalid or missing API key)
- **Method/Path Error**: HTTP 404 Not Found (wrong method or path)

**Note**: Session IDs follow the format `YYYY-MM-DD-HH-MM-SS` (e.g., `2024-01-15-10-30-00`) and are automatically generated when new sessions are created.

#### GET `/session`

Returns an HTML preview of the specified chat session.

**Request Parameters:**

| Parameter | Type   | Description                         |
| --------- | ------ | ----------------------------------- |
| `id`      | string | **Required**. Session ID to preview |

**Example Request:**

```bash
curl "http://127.0.0.1:7777/session?id=2024-01-15-10-30-00" \
  -H "X-API-Key: your-secret-key"
```

**Response:**

- **Success**: HTTP 200 OK, returns HTML content with `Content-Type: text/html; charset=utf-8`
- **Missing ID**: HTTP 400 Bad Request
- **Session Not Found**: HTTP 404 Not Found
- **Authentication Error**: HTTP 401 Unauthorized

**HTML Preview Features:**

- Clean, modern dark theme design
- Session metadata display (ID, provider, model, working directory, system prompt)
- Message formatting with role badges and timestamps
- Support for tool calls and results visualization
- Reasoning content (thinking) display
- Error messages highlighting
- Token usage statistics
- Responsive layout with scrollable sections

**Integration:**

The HTML preview can be opened via:

1. `:Chat preview` command in Neovim
2. `<C-o>` key binding in picker's chat source
3. Direct HTTP request to `/session?id=<session_id>` endpoint

### Message Queue System

Incoming messages are processed through a queue system:

1. Messages are immediately queued upon receipt
2. The queue is checked every 5 seconds
3. Messages are delivered to the chat session when it's not in progress
4. If a session is busy (processing another request), messages remain in the queue until the session becomes available

### Usage Examples

#### Using curl:

```bash
# Send a message to a session
curl -X POST http://127.0.0.1:7777/ \
  -H "X-API-Key: your-secret-key" \
  -H "Content-Type: application/json" \
  -d '{"session": "my-session", "content": "Hello from curl!"}'

# Get all session IDs
curl -H "X-API-Key: your-secret-key" http://127.0.0.1:7777/sessions
```

#### Using Python:

```python
import requests

# Send a message to a session
url = "http://127.0.0.1:7777/"
headers = {
    "X-API-Key": "your-secret-key",
    "Content-Type": "application/json"
}
data = {
    "session": "python-script",
    "content": "Message from Python script"
}
response = requests.post(url, json=data, headers=headers)
print(f"Status: {response.status_code}")

# Get session list
sessions_response = requests.get("http://127.0.0.1:7777/sessions", headers=headers)
if sessions_response.status_code == 200:
    sessions = sessions_response.json()
    print(f"Active sessions: {sessions}")
```

### Security Considerations

1. **API Key Protection**: Keep your API key secure and never commit it to version control
2. **Network Security**: By default, the server binds to localhost (127.0.0.1). Only allow external access if you have proper network security measures
3. **Input Validation**: All incoming messages are validated for proper JSON format and required fields
4. **Rate Limiting**: Consider implementing external rate limiting if needed for your use case

### Integration Ideas

- **CI/CD Pipelines**: Send build notifications or deployment status to chat sessions
- **Monitoring Systems**: Forward alerts from monitoring tools
- **Script Automation**: Trigger chat interactions from shell scripts
- **External Applications**: Integrate with other desktop or web applications
- **Session Management Tools**: External scripts can periodically fetch active session lists for cleanup or backup
- **Monitoring Dashboard**: Display status and statistics of all active sessions

## 🔍 Picker Integration

chat.nvim provides built-in picker sources for seamless integration with [picker.nvim](https://github.com/wsdjeg/picker.nvim).
These sources allow you to quickly access and manage your chat sessions, providers, and models.

**Note**: The `chat` picker source displays all your active sessions, allowing quick switching between parallel conversations with different models.

**Available Sources:**

1. `chat` - Search through your chat history sessions

   - Uses the **first message** of each session as the search string
   - Quickly resume previous conversations
   - Supports filtering and session management
     ![picker-chat](https://wsdjeg.net/images/picker-chat.png)

   **Keyboard Shortcuts in chat picker:**

   - `<CR>` (Enter): Open selected session
   - `<C-d>`: Delete selected session
   - `<C-o>`: Open HTML preview in browser

2. `chat_provider` - Switch between different AI providers

   - Dynamically change between supported providers (DeepSeek, OpenAI, etc.)
   - Real-time switching without restarting Neovim
     ![picker-chat](https://wsdjeg.net/images/picker-chat-provider.png)

3. `chat_model` - Select available models for the current provider
   - Lists all compatible models for your selected provider
   - Intelligent filtering based on provider capabilities
     ![picker-chat](https://wsdjeg.net/images/picker-chat-model.png)

## 💬 IM Integration

chat.nvim supports integration with multiple instant messaging platforms for remote AI interaction.

### Supported Platforms

| Platform | Icon | Bidirectional | Features                                |
| -------- | ---- | ------------- | --------------------------------------- |
| Discord  | 💬   | ✅ Yes        | Full-featured bot with session binding  |
| Lark     | 🐦   | ✅ Yes        | Feishu/Lark bot with message polling    |
| DingTalk | 📱   | ✅ Yes\*      | Webhook (one-way) or API (two-way)      |
| WeCom    | 💼   | ✅ Yes\*      | Enterprise WeChat webhook or API        |
| Telegram | ✈️   | ✅ Yes        | Bot API with group/private chat support |

\*Webhook mode is one-way only; API mode supports bidirectional communication.

### Discord

Discord integration allows you to interact with AI assistants via Discord messages.

#### Features

- **Bidirectional Communication**: Send messages from Discord to chat.nvim and receive responses
- **Session Binding**: Bind specific Discord channels to chat.nvim sessions
- **Remote Control**: Use Discord commands to manage sessions remotely
- **Automatic Polling**: Bot polls for new messages every 3 seconds
- **Message Mentions**: Bot responds to mentions and replies

#### Setup Guide

**1. Create Discord Application**

- Go to https://discord.com/developers/applications
- Click "New Application"
- Give it a name (e.g., "Chat.nvim Bot")

**2. Create Bot User**

- Navigate to "Bot" section
- Click "Add Bot"
- Copy the **Token** (this is your `integrations.discord.token`)

**3. Enable Message Content Intent**

- Under "Privileged Gateway Intents"
- Enable "Message Content Intent" ✅
- Save changes

**4. Get Channel ID**

- Enable Developer Mode in Discord (User Settings → Advanced → Developer Mode)
- Right-click your channel → Copy ID (this is your `integrations.discord.channel_id`)

**5. Invite Bot to Server**

- Go to "OAuth2" → "URL Generator"
- Select "bot" scope
- Required permissions: "Read Messages", "Send Messages", "Read Message History"
- Copy and open the generated URL
- Authorize the bot

**6. Configure chat.nvim**

```lua
integrations = {
  discord = {
    token = 'YOUR_DISCORD_BOT_TOKEN',
    channel_id = 'YOUR_CHANNEL_ID',
  },
}
```

#### Commands

**Neovim Commands:**

- `:Chat bridge discord` - Bind current chat.nvim session to Discord channel

**Discord Commands:**

- `/session` - Bind current Discord channel to active chat.nvim session
- `/clear` - Clear messages in the bound session

#### Workflow

1. Configure Discord bot token and channel ID
2. Open chat.nvim and create/start a session
3. Run `:Chat bridge discord` to bind the session
4. In Discord, type `/session` to confirm binding
5. Mention the bot or reply to its messages to interact
6. AI response will be sent back to Discord automatically

#### Technical Details

- **API**: Discord REST API v10
- **Polling**: 3-second intervals
- **Message Limit**: Auto-chunking for messages > 2000 characters
- **State Persistence**: `stdpath('data')/chat-discord-state.json`
- **Timeout Protection**: 5-second request timeout

#### Troubleshooting

**Bot not responding:**

1. Verify token and channel_id are correct
2. Check bot has "Message Content Intent" enabled
3. Ensure bot is invited with proper permissions
4. Make sure you're mentioning the bot or replying to its messages

**State issues:**

- Clear state: `:lua require('chat.integrations.discord').clear_state()`

### Lark (Feishu)

Lark/Feishu integration for enterprise communication.

#### Features

- **Bidirectional Communication**: Send and receive messages via Lark bot
- **Session Binding**: Bind Lark chats to chat.nvim sessions
- **Automatic Polling**: Polls for new messages every 3 seconds
- **Long Message Support**: Handles messages up to 30,720 characters

#### Setup Guide

**1. Create Lark App**

- Go to https://open.feishu.cn/app
- Create a new custom app
- Copy **App ID** and **App Secret**

**2. Configure Bot Permissions**

Required permissions:

- `im:message.group_msg` - Get all messages in groups (sensitive permission)
- `im:message` - Get and send messages in private chats and groups

Configuration steps:

1. Go to your app → "Permissions & Scopes"
2. Search for and enable the required permissions above
3. For sensitive permissions, you may need to apply for approval

**3. Get Chat ID**

- Use Lark API or app to get your chat_id
- For group chats, use the group ID

**4. Configure chat.nvim**

```lua
integrations = {
  lark = {
    app_id = 'YOUR_APP_ID',
    app_secret = 'YOUR_APP_SECRET',
    chat_id = 'YOUR_CHAT_ID',
  },
}
```

#### Commands

- `:Chat bridge lark` - Bind current session to Lark chat

#### Technical Details

- **API**: Lark Open API
- **Authentication**: Tenant Access Token (auto-refresh)
- **Polling**: 3-second intervals
- **Message Limit**: 30,720 characters
- **State Persistence**: `stdpath('data')/chat-lark-state.json`

### DingTalk

DingTalk integration with webhook or API mode.

#### Features

- **Two Modes**: Webhook (simple, one-way) or API (bidirectional)
- **Message Queue**: Sequential message processing
- **Long Message Support**: Auto-chunking for messages > 20,000 characters

#### Setup Guide

**Webhook Mode (Simple, One-Way):**

1. Create a custom robot in DingTalk group
2. Copy the webhook URL
3. Configure:

```lua
integrations = {
  dingtalk = {
    webhook = 'https://oapi.dingtalk.com/robot/send?access_token=XXX',
  },
}
```

**API Mode (Advanced, Bidirectional):**

1. Create an enterprise internal app
2. Get AppKey and AppSecret
3. Configure:

```lua
integrations = {
  dingtalk = {
    app_key = 'YOUR_APP_KEY',
    app_secret = 'YOUR_APP_SECRET',
    conversation_id = 'YOUR_CONVERSATION_ID',
    user_id = 'YOUR_USER_ID',
  },
}
```

#### Technical Details

- **API**: DingTalk Open Platform API
- **Authentication**: Access Token (auto-refresh)
- **Message Limit**: 20,000 characters
- **State Persistence**: `stdpath('data')/chat-dingtalk-state.json`

### WeCom (Enterprise WeChat)

WeCom integration with webhook or API mode.

#### Features

- **Two Modes**: Webhook (simple, one-way) or API (bidirectional)
- **Corporate Integration**: Full enterprise WeChat support
- **Message Queue**: Sequential processing

#### Setup Guide

**Webhook Mode (Simple, One-Way):**

1. Add a webhook robot in WeCom group
2. Copy the webhook key
3. Configure:

```lua
integrations = {
  wecom = {
    webhook_key = 'YOUR_WEBHOOK_KEY',
  },
}
```

**API Mode (Advanced, Bidirectional):**

1. Create an enterprise application
2. Get CorpID, CorpSecret, and AgentID
3. Configure:

```lua
integrations = {
  wecom = {
    corp_id = 'YOUR_CORP_ID',
    corp_secret = 'YOUR_CORP_SECRET',
    agent_id = 'YOUR_AGENT_ID',
    user_id = 'YOUR_USER_ID',
  },
}
```

#### Technical Details

- **API**: WeCom API
- **Authentication**: Access Token (auto-refresh)
- **Message Limit**: 2,048 characters
- **State Persistence**: `stdpath('data')/chat-wecom-state.json`

### Telegram

Telegram bot integration with full feature support.

#### Features

- **Full Bot API Support**: Works in groups and private chats
- **Markdown Support**: Send formatted messages with Markdown
- **Reply Support**: Reply to specific messages
- **Long Message Support**: Auto-chunking for messages > 4,096 characters
- **Bot Commands**: Support for `/session` and `/clear` commands

#### Setup Guide

**1. Create Telegram Bot**

- Open Telegram and search for `@BotFather`
- Send `/newbot` command
- Follow instructions to create your bot
- Copy the **Bot Token** (format: `123456789:ABCdefGHIjklMNOpqrsTUVwxyz`)

**2. Get Chat ID**

**For Private Chat:**

- Start a conversation with your bot
- Send a message to the bot
- Visit: `https://api.telegram.org/bot<YOUR_BOT_TOKEN>/getUpdates`
- Find the `"chat":{"id":` value in the response

**For Group Chat:**

- Add bot to group
- Send a message mentioning the bot
- Visit the same URL to get the group chat ID

**3. Configure chat.nvim**

```lua
integrations = {
  telegram = {
    bot_token = 'YOUR_BOT_TOKEN',
    chat_id = 'YOUR_CHAT_ID',
  },
}
```

#### Commands

**Neovim Commands:**

- `:Chat bridge telegram` - Bind current session to Telegram chat

**Telegram Commands:**

- `/session` - Bind current Telegram chat to active session
- `/clear` - Clear messages in the bound session

#### Workflow

1. Configure Telegram bot token and chat ID
2. Open chat.nvim and create/start a session
3. Run `:Chat bridge telegram` to bind the session
4. In Telegram, send a message to the bot or mention it in a group
5. AI response will be sent back to Telegram automatically

#### Technical Details

- **API**: Telegram Bot API
- **Polling**: 3-second intervals via getUpdates
- **Message Format**: Markdown support
- **Message Limit**: Auto-chunking for messages > 4,096 characters
- **State Persistence**: `stdpath('data')/chat-telegram-state.json`
- **Bot Detection**: Auto-fetches and caches bot username

#### Troubleshooting

**Bot not responding:**

1. Verify bot token is correct
2. Check if chat_id is correct (private chat or group)
3. For groups, make sure bot has read permissions
4. Try sending `/start` to the bot first

**State issues:**

- Clear state: `:lua require('chat.integrations.telegram').clear_state()`

### Common Features

All IM integrations share these common features:

**Commands:**

- `:Chat bridge <platform>` - Bind current session to platform
- `/session` - Check/update session binding
- `/clear` - Clear current session messages

**Technical Details:**

- **Polling Interval**: 3 seconds (configurable per platform)
- **Message Queue**: Sequential processing to prevent race conditions
- **State Persistence**: JSON files in `stdpath('data')`
- **Auto-reconnect**: Automatic recovery from network issues
- **Timeout Protection**: 5-second request timeout

### Platform-Specific Notes

**Discord:**

- Requires "Message Content Intent" enabled
- Bot must be mentioned or replied to in group chats
- Private channels require direct messages

**Lark:**

- Requires app approval for production use
- Tenant access token is auto-refreshed
- Supports rich message types (text, cards, etc.)

**DingTalk:**

- Webhook mode is simplest but one-way only
- API mode requires enterprise app registration
- Stream mode recommended for bidirectional communication

**WeCom:**

- Webhook mode is simplest but one-way only
- API mode requires corporate approval
- Internal apps have more permissions

**Telegram:**

- Works in both private and group chats
- Groups require bot to be admin for some features
- Supports inline queries and callbacks

### Contributing New Integrations

To add a new IM platform integration:

1. Create `lua/chat/integrations/<platform>.lua`
2. Implement required functions:
   - `connect(callback)` - Start listening for messages
   - `disconnect()` - Stop listening
   - `send_message(content)` - Send message
   - `current_session()` - Get current session ID
   - `set_session(session)` - Set current session
   - `cleanup()` - Cleanup resources
3. Update `lua/chat/integrations/init.lua`
4. Add documentation to README

See `lua/chat/integrations/discord.lua` for reference implementation.

## 📣 Self-Promotion

Like this plugin? Star the repository on
GitHub.

Love this plugin? Follow [me](https://wsdjeg.net/) on
[GitHub](https://github.com/wsdjeg).

## 💬 Feedback

If you encounter any bugs or have suggestions, please file an issue in the [issue tracker](https://github.com/wsdjeg/chat.nvim/issues).

## 📄 License

This project is licensed under the GPL-3.0 License.
