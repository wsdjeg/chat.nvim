# chat.nvim

A lightweight, extensible Neovim chat plugin with AI integration.

[![Run Tests](https://github.com/wsdjeg/chat.nvim/actions/workflows/test.yml/badge.svg)](https://github.com/wsdjeg/chat.nvim/actions/workflows/test.yml)
[![GitHub License](https://img.shields.io/github/license/wsdjeg/chat.nvim)](LICENSE)
[![GitHub Release](https://img.shields.io/github/v/release/wsdjeg/chat.nvim)](https://github.com/wsdjeg/chat.nvim/releases)
[![luarocks](https://img.shields.io/luarocks/v/wsdjeg/chat.nvim)](https://luarocks.org/modules/wsdjeg/chat.nvim)

![chat.nvim](https://wsdjeg.net/images/chat-nvim-intro.png)

## ✨ Features

- **Multiple AI Providers** - DeepSeek, GitHub AI, OpenAI, Anthropic, Gemini, Ollama, and more
- **Three-Tier Memory System** - Working, daily, and long-term memory with smart retrieval
- **Tool Integration** - File operations, git commands, web search, custom tools
- **MCP Support** - Model Context Protocol for extended tool capabilities
- **IM Integration** - Discord, Telegram, Slack, Lark, DingTalk, WeCom
- **HTTP API** - Built-in server for external integration
- **Parallel Sessions** - Multiple conversations with different models simultaneously

## 📦 Installation

```lua
-- lazy.nvim
{
  'wsdjeg/chat.nvim',
  dependencies = {
    'wsdjeg/job.nvim', -- Required
    'wsdjeg/picker.nvim', -- Optional but recommended
  },
}

-- nvim-plug
require('plug').add({
  {
    'wsdjeg/chat.nvim',
    depends = { 'wsdjeg/job.nvim', 'wsdjeg/picker.nvim' },
  },
})
```

## 🚀 Quick Start

```vim
:Chat          " Open chat window
:Chat new      " Start a new session
:Chat prev     " Switch to previous session
:Chat next     " Switch to next session
```

## 📖 Documentation

For full documentation, visit **[nvim.chat](https://nvim.chat)**

## 📄 License

GPL-3.0 License
