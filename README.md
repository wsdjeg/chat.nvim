# chat.nvim

A lightweight and extensible pure-Lua chat plugin for Neovim,

[![GitHub License](https://img.shields.io/github/license/wsdjeg/chat.nvim)](LICENSE)
[![GitHub Issues or Pull Requests](https://img.shields.io/github/issues/wsdjeg/chat.nvim)](https://github.com/wsdjeg/chat.nvim/issues)
[![GitHub commit activity](https://img.shields.io/github/commit-activity/m/wsdjeg/chat.nvim)](https://github.com/wsdjeg/chat.nvim/commits/master/)
[![GitHub Release](https://img.shields.io/github/v/release/wsdjeg/chat.nvim)](https://github.com/wsdjeg/chat.nvim/releases)
[![luarocks](https://img.shields.io/luarocks/v/wsdjeg/chat.nvim)](https://luarocks.org/modules/wsdjeg/chat.nvim)

![chat.nvim](https://github.com/user-attachments/assets/bc51314c-a983-4b9e-9056-e1bf4dc51acc)

## Installation

Using nvim-plug:

```lua
require('plug').add({
  {
    'wsdjeg/chat.nvim',
    opt = {
      provider = 'deepseek',
      api_key = 'your api key',
      width = 0.8, -- 80% of vim.o.columns
      height = 0.8, -- 80% of vim.o.lines
      border = 'rounded',
    },
  },
})
```

## Usage

Use `:Chat` command to open this plugin.

| mode     | key binding | description                                   |
| -------- | ----------- | --------------------------------------------- |
| `Normal` | `<Enter>`   | Sent message                                  |
| `Normal` | `q`         | Close chat windows                            |
| `Normal` | `<Tab>`     | Switch between input window and result window |

## 🔍 Picker source

chat.nvim provides built-in picker sources for seamless integration with [picker.nvim](https://github.com/wsdjeg/picker.nvim).
These sources allow you to quickly access and manage your chat sessions, providers, and models.

**Available Sources:**

1. `chat` - Search through your chat history sessions
   - Uses the **first message** of each session as the search string
   - Quickly resume previous conversations
   - Supports filtering and session management

2. `chat_provider` - Switch between different AI providers
   - Dynamically change between supported providers (DeepSeek, OpenAI, etc.)
   - Real-time switching without restarting Neovim

3. `chat_model` - Select available models for the current provider
   - Lists all compatible models for your selected provider
   - Intelligent filtering based on provider capabilities
