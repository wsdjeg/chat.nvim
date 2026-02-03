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

Use `:Picker chat` to fuzzy find chat sessions.
