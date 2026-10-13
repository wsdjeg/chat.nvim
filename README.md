# chat.nvim

`chat.nvim` is a lightweight, extensible chat plugin for Neovim with AI integration.
Chat with AI assistants directly in your editor using a clean, floating window interface.
It supports 20+ AI providers, a three-tier memory system, 45+ built-in tools,
MCP protocol, IM integrations, and an HTTP API for external access.
Full documentation is available at [nvim.chat](https://nvim.chat).

[![Run Tests](https://github.com/wsdjeg/chat.nvim/actions/workflows/test.yml/badge.svg)](https://github.com/wsdjeg/chat.nvim/actions/workflows/test.yml)
[![GitHub License](https://img.shields.io/github/license/wsdjeg/chat.nvim)](LICENSE)
[![GitHub Issues or Pull Requests](https://img.shields.io/github/issues/wsdjeg/chat.nvim)](https://github.com/wsdjeg/chat.nvim/issues)
[![GitHub commit activity](https://img.shields.io/github/commit-activity/m/wsdjeg/chat.nvim)](https://github.com/wsdjeg/chat.nvim/commits/master/)
[![GitHub Release](https://img.shields.io/github/v/release/wsdjeg/chat.nvim)](https://github.com/wsdjeg/chat.nvim/releases)
[![luarocks](https://img.shields.io/luarocks/v/wsdjeg/chat.nvim)](https://luarocks.org/modules/wsdjeg/chat.nvim)

![chat-nvim](https://github.com/user-attachments/assets/42ea71b2-7b0f-497e-b236-d9ae5a207a8a)

<!-- vim-markdown-toc GFM -->

- [✨ Features](#-features)
- [📦 Installation](#-installation)
- [🔧 Configuration](#-configuration)
- [⚙️ Basic Usage](#-basic-usage)
- [🧠 Memory System](#-memory-system)
- [🛠️ Tools](#-tools)
- [🔌 MCP Support](#-mcp-support)
- [💬 IM Integration](#-im-integration)
- [🌐 HTTP API](#-http-api)
- [📣 Self-Promotion](#-self-promotion)
- [💬 Feedback](#-feedback)
- [📄 License](#-license)

<!-- vim-markdown-toc -->

## ✨ Features

- **🤖 20+ AI Providers** - DeepSeek, OpenAI, Anthropic, GitHub Models, Gemini, Ollama, Baidu, Xiaomi, Alibaba Cloud, Moonshot, Tencent, and more
- **🧠 Three-Tier Memory** - Working, daily, and long-term memory with automatic extraction and priority-based retrieval
- **🛠️ 45+ Built-in Tools** - File operations, Git integration, web search and fetch, email, scheduling, user profiles
- **🧩 Slash Commands** - Built-in skills (`/model`, `/provider`, `/cwd`, `/pin`, `/title`, `/retry`, ...) with custom skill registration
- **🔍 Lazy Tool Discovery** - Only essential tools are sent with each request; other tools are activated on demand via a built-in catalog
- **🔄 Parallel Sessions** - Multiple conversations with different models simultaneously
- **🔌 MCP Protocol** - Native Model Context Protocol support via stdio and HTTP transports
- **💬 IM Integration** - Discord, Telegram, Slack, Lark, DingTalk, WeCom, WeChat
- **🌐 HTTP API** - Built-in server for external integration with API key authentication
- **👤 User Profiles** - Per-user preferences and skills for personalized assistance
- **⏰ Scheduled Tasks** - One-time or recurring tasks that persist across Neovim restarts
- **⚡ Streaming Responses** - Real-time AI responses with cancellation and token tracking

## 📦 Installation

chat.nvim works with all major Neovim plugin managers.

- **Using [lazy.nvim](https://github.com/folke/lazy.nvim)**

  ```lua
  {
    'wsdjeg/chat.nvim',
    dependencies = {
      'wsdjeg/job.nvim', -- Required
      'wsdjeg/picker.nvim', -- Optional but recommended
    },
  }
  ```

- **Using [nvim-plug](https://github.com/wsdjeg/nvim-plug)**

  ```lua
  require('plug').add({
    {
      'wsdjeg/chat.nvim',
      depends = {
        'wsdjeg/job.nvim',
        'wsdjeg/picker.nvim',
      },
    },
  })
  ```

- **Using [luarocks](https://luarocks.org/)**

  ```
  luarocks install chat.nvim
  ```

## 🔧 Configuration

The following is the default configuration of chat.nvim.
See the [Configuration Guide](https://nvim.chat/configuration/) for full details.

```lua
require('chat').setup({
  -- window options
  width = 0.8,
  height = 0.8,
  auto_scroll = true,
  border = 'rounded',
  -- default AI provider and model
  provider = 'deepseek',
  model = 'deepseek-v4-flash',
  -- time display format
  strftime = '%m-%d %H:%M:%S',
  -- display names for the AI and user, used in the chat window
  -- and on role badges in the HTML preview
  names = {
    bot = 'Bot',
    user = 'You',
  },
  -- enable RenderMarkdown for result buffer
  render_markdown = true,
  -- default system prompt
  system_prompt = '',
  -- restrict file tool access to specific paths (string or list of strings)
  allowed_path = '',
  -- HTTP server for external integration
  http = {
    host = '127.0.0.1',
    port = 7777,
    api_key = '', -- set to non-empty to enable
  },
  -- API keys for providers
  api_key = {
    deepseek = 'your-deepseek-api-key',
    openai = 'your-openai-api-key',
    -- ...
  },
})
```

## ⚙️ Basic Usage

Open the chat window:

```vim
:Chat
```

Switch provider or model with slash commands (in the prompt window):

```
/provider openai
/model gpt-4o
```

Or use [picker.nvim](https://github.com/wsdjeg/picker.nvim) keybindings (in the input window):

| Key Binding  | Action                          |
| ------------ | ------------------------------- |
| `<Leader>fp` | Switch provider via picker      |
| `<Leader>fm` | Switch model via picker         |
| `<Leader>fr` | Browse session history via picker |

Navigate and manage sessions:

```vim
:Chat new      " create a new session
:Chat prev     " previous session
:Chat next     " next session
:Chat delete   " delete the current session
:Chat save f   " save the session to a file
:Chat load f   " load a session from a file or URL
:Chat share    " share the session to a pastebin
:Chat preview  " open the HTML preview in your browser
```

See the [Usage Guide](https://nvim.chat/usage/) for all commands and keybindings.

## 🧠 Memory System

chat.nvim implements a three-tier memory system:

| Type | Lifetime | Purpose |
|------|----------|---------|
| **Working** | Session | Current context, decisions, active tasks |
| **Daily** | 7-30 days | Tasks, reminders, schedules |
| **Long-term** | Permanent | Preferences, facts, skills |

Memories are automatically extracted during conversations and retrieved with priority-based ranking.
See the [Memory Guide](https://nvim.chat/memory/) for details.

## 🛠️ Tools

45+ built-in tools are available for AI assistants to interact with your environment:

- **File Operations** - Read, write, copy, move, and search files and directories
- **Git Integration** - Status, diff, log, commit, push, branch, rebase, stash, tag
- **Web Search** - Search the web via Firecrawl, Google, or SerpAPI
- **Web Fetch** - Fetch URLs and convert HTML to markdown
- **Email** - Send emails via the system `mail` command
- **Mastodon** - Read-only Mastodon: fetch toots, threads, and timelines
- **Memory Management** - Extract and recall memories
- **Scheduled Tasks** - One-time or recurring tasks, persisted across restarts
- **User Profiles** - Manage per-user preferences and skills
- **Task Plans** - Create and manage task plans
- **Office Documents** - View Excel files with multiple modes
- **Development** - Run make targets, check LSP diagnostics, get weather/time, convert images via ffmpeg

Tools are lazy-loaded by default: only the essential tools plus a `find_tool` discovery
catalog are sent with each request to save prompt tokens, and other tools are activated
on demand for the current turn. Set `tools.lazy = false` to send all tools with every
request.

See the [Tools Guide](https://nvim.chat/tools/) for the full list and usage.

## 🔌 MCP Support

Native [Model Context Protocol](https://modelcontextprotocol.io/) support for extended tool capabilities:

```lua
require('chat').setup({
  mcp = {
    mcpServers = {
      -- stdio transport
      filesystem = {
        command = 'npx',
        args = { '-y', '@modelcontextprotocol/server-filesystem', '/path/to/dir' },
      },
      -- HTTP transport
      remote = {
        url = 'http://localhost:3000/mcp',
      },
    },
  },
})
```

See the [MCP Guide](https://nvim.chat/mcp/) for details.

## 💬 IM Integration

Connect messaging platforms for remote AI interaction:

- **Discord** - Chat with AI via Discord bot
- **Telegram** - Send messages and receive AI responses
- **Slack** - Slash command integration
- **Lark** - Feishu/Lark bot support
- **DingTalk** - DingTalk robot integration
- **WeCom** - WeChat Work integration
- **WeChat** - WeChat official account support

See the [Integrations Guide](https://nvim.chat/integrations/) for setup instructions.

## 🌐 HTTP API

The built-in HTTP server allows external applications to send messages to chat.nvim:

```bash
curl -X POST http://127.0.0.1:7777/ \
  -H "Content-Type: application/json" \
  -H "X-API-Key: your-secret-api-key" \
  -d '{"content":"Hello","session":"default"}'
```

See the [API Guide](https://nvim.chat/api/) for all endpoints.

## 📣 Self-Promotion

If you like this plugin, please star it on [GitHub](https://github.com/wsdjeg/chat.nvim).
Also check out my other Neovim plugins:

- [nvim-plug](https://github.com/wsdjeg/nvim-plug) - Asynchronous plugin manager
- [picker.nvim](https://github.com/wsdjeg/picker.nvim) - Fuzzy picker
- [job.nvim](https://github.com/wsdjeg/job.nvim) - Async job execution
- [flygrep.nvim](https://github.com/wsdjeg/flygrep.nvim) - Asynchronous grep

## 💬 Feedback

If you encounter any bugs or have suggestions, please file an issue in the
[issue tracker](https://github.com/wsdjeg/chat.nvim/issues)

## 📄 License

Licensed under GPL-3.0.

