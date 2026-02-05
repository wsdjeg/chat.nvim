# chat.nvim

A lightweight, extensible chat plugin for Neovim with AI integration.
Chat with AI assistants directly in your editor using a clean, floating window interface.

[![GitHub License](https://img.shields.io/github/license/wsdjeg/chat.nvim)](LICENSE)
[![GitHub Issues or Pull Requests](https://img.shields.io/github/issues/wsdjeg/chat.nvim)](https://github.com/wsdjeg/chat.nvim/issues)
[![GitHub commit activity](https://img.shields.io/github/commit-activity/m/wsdjeg/chat.nvim)](https://github.com/wsdjeg/chat.nvim/commits/master/)
[![GitHub Release](https://img.shields.io/github/v/release/wsdjeg/chat.nvim)](https://github.com/wsdjeg/chat.nvim/releases)
[![luarocks](https://img.shields.io/luarocks/v/wsdjeg/chat.nvim)](https://luarocks.org/modules/wsdjeg/chat.nvim)

![chat.nvim](https://wsdjeg.net/images/chat-nvim-intro.png)

<!-- vim-markdown-toc GFM -->

- [✨ Features](#-features)
- [📦 Installation](#-installation)
- [⚙️ Usage](#-usage)
    - [Key Bindings](#key-bindings)
- [🤖 Providers](#-providers)
    - [Built-in Providers](#built-in-providers)
    - [Custom Providers](#custom-providers)
- [🔍 Picker Integration](#-picker-integration)
- [📣 Self-Promotion](#-self-promotion)
- [💬 Feedback](#-feedback)
- [📄 License](#-license)

<!-- vim-markdown-toc -->
## ✨ Features

- **Multiple AI Providers**: Built-in support for GitHub AI and DeepSeek
- **Custom Provider Support**: Easily add your own AI providers
- **Floating Window Interface**: Clean, non-intrusive chat interface
- **Session Management**: Resume previous conversations
- **Picker Integration**: Seamless integration with [picker.nvim](https://github.com/wsdjeg/picker.nvim)
- **Streaming Responses**: Real-time AI responses with cancellation support
- **Lightweight**: Pure Lua implementation with minimal dependencies

## 📦 Installation

Using nvim-plug:

```lua
require('plug').add({
  {
    'wsdjeg/chat.nvim',
    depends = { {
      'wsdjeg/job.nvim',
    } },
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

## ⚙️ Usage

Use the `:Chat` command to launch this plugin.

### Key Bindings

The following key bindings are available in the **Input** window:

| Mode     | Key Binding | Description                           |
| -------- | ----------- | ------------------------------------- |
| `Normal` | `<Enter>`   | Send message                          |
| `Normal` | `q`         | Close chat window                     |
| `Normal` | `<Tab>`     | Switch between input and result windows |
| `Normal` | `Ctrl-C`    | Cancel current request                |
| `Normal` | `r`         | Retry last cancelled request          |

The following key bindings are available in the **Result** window:

| Mode     | Key Binding | Description                           |
| -------- | ----------- | ------------------------------------- |
| `Normal` | `q`         | Close chat window                     |
| `Normal` | `<Tab>`     | Switch between input and result windows |

## 🤖 Providers

### Built-in Providers

1. **`deepseek`** - [DeepSeek AI](https://platform.deepseek.com/)
   - Models: `deepseek-chat`, `deepseek-coder`
   - Requires: API key from DeepSeek platform

2. **`github`** - [GitHub AI](https://github.com/features/ai)
   - Models: Provider-specific models
   - Requires: GitHub AI access token

### Custom Providers

chat.nvim also supports custom provider, just create `lua/chat/providers/<provider_name>.lua`, this lua module
should provides two functions `request` and `available_models`,
here is an example for using [free_chatgpt_api](https://github.com/popjane/free_chatgpt_api)

```lua
local M = {}
local job = require('job')
local sessions = require('chat.sessions')

function M.available_models()
  return {
    'gpt-4o-mini',
  }
end

function M.request(requestObj)
  local cmd = {
    'curl',
    '-s',
    'https://free.v36.cm/v1/chat/completions',
    '-H',
    'Content-Type: application/json',
    '-H',
    'Authorization: Bearer ' .. requestObj.api_key,
    '-X',
    'POST',
    '-d',
    vim.json.encode({
      model = requestObj.model,
      messages = requestObj.messages,
      stream = true,
    }),
  }

  local jobid = job.start(cmd, {
    on_stdout = requestObj.on_stdout,
    on_exit = requestObj.on_exit,
  })
  sessions.set_session_jobid(requestObj.session, jobid)
end

return M
```

## 🔍 Picker Integration

chat.nvim provides built-in picker sources for seamless integration with [picker.nvim](https://github.com/wsdjeg/picker.nvim).
These sources allow you to quickly access and manage your chat sessions, providers, and models.

**Available Sources:**

1. `chat` - Search through your chat history sessions

   - Uses the **first message** of each session as the search string
   - Quickly resume previous conversations
   - Supports filtering and session management
   ![picker-chat](https://wsdjeg.net/images/picker-chat.png)

2. `chat_provider` - Switch between different AI providers

   - Dynamically change between supported providers (DeepSeek, OpenAI, etc.)
   - Real-time switching without restarting Neovim
   ![picker-chat](https://wsdjeg.net/images/picker-chat-provider.png)

3. `chat_model` - Select available models for the current provider
   - Lists all compatible models for your selected provider
   - Intelligent filtering based on provider capabilities
   ![picker-chat](https://wsdjeg.net/images/picker-chat-model.png)

## 📣 Self-Promotion

Like this plugin? Star the repository on
GitHub.

Love this plugin? Follow [me](https://wsdjeg.net/) on
[GitHub](https://github.com/wsdjeg).

## 💬 Feedback

If you encounter any bugs or have suggestions, please file an issue in the [issue tracker](https://github.com/wsdjeg/chat.nvim/issues).

## 📄 License

This project is licensed under the GPL-3.0 License.
