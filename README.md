<h1 align="center">
<a href="https://nvim.chat">
  <img src="https://wsdjeg.net/images/chat-nvim-intro.png" width="440" alt="chat.nvim"/>
  </a>
</h1>

[Quick Start](https://nvim.chat/quick-start/) \|
[Documentation](https://nvim.chat/documentation/) \|
[Tools](https://nvim.chat/tools/) \|
[Providers](https://nvim.chat/providers/)

[![Run Tests](https://github.com/wsdjeg/chat.nvim/actions/workflows/test.yml/badge.svg)](https://github.com/wsdjeg/chat.nvim/actions/workflows/test.yml)
[![GitHub License](https://img.shields.io/github/license/wsdjeg/chat.nvim)](LICENSE)
[![GitHub Issues or Pull Requests](https://img.shields.io/github/issues/wsdjeg/chat.nvim)](https://github.com/wsdjeg/chat.nvim/issues)
[![GitHub commit activity](https://img.shields.io/github/commit-activity/m/wsdjeg/chat.nvim)](https://github.com/wsdjeg/chat.nvim/commits/master/)
[![GitHub Release](https://img.shields.io/github/v/release/wsdjeg/chat.nvim)](https://github.com/wsdjeg/chat.nvim/releases)
[![luarocks](https://img.shields.io/luarocks/v/wsdjeg/chat.nvim)](https://luarocks.org/modules/wsdjeg/chat.nvim)

chat.nvim is a lightweight, extensible chat plugin for Neovim with AI integration.
It supports multiple AI providers, tool calls, memory system, and IM integrations.
Chat with AI assistants directly in your editor using a clean, floating window interface.

## Features

- **Multiple AI Providers:** DeepSeek, GitHub AI, OpenAI, Anthropic, Gemini, Ollama, and more
- **Three-Tier Memory System:** Working, daily, and long-term memory with smart retrieval
- **Tool Integration:** File operations, git commands, web search, and custom tools
- **MCP Support:** Model Context Protocol for extended tool capabilities
- **IM Integration:** Discord, Telegram, Slack, Lark, DingTalk, WeCom
- **HTTP API:** Built-in server for external integration
- **Parallel Sessions:** Multiple conversations with different models simultaneously

## Installation

```lua
-- lazy.nvim
{
  'wsdjeg/chat.nvim',
  dependencies = {
    'wsdjeg/job.nvim', -- Required
    'wsdjeg/picker.nvim', -- Optional but recommended
  },
}
```

## Contribute

This project wouldn't exist without all the people who contributed.

<a href="https://github.com/wsdjeg/chat.nvim/graphs/contributors"><img src="https://opencollective.com/chat-nvim/contributors.svg?width=890&button=false" /></a>

## License

chat.nvim is released under the GPL-3.0 License.

<!-- vim:set nowrap: -->
