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
    - [Basic Commands](#basic-commands)
    - [Examples](#examples)
    - [Key Bindings](#key-bindings)
- [🤖 Providers](#-providers)
    - [Built-in Providers](#built-in-providers)
    - [Custom Providers](#custom-providers)
- [Tools](#tools)
    - [Available Tools](#available-tools)
        - [`read_file`](#read_file)
        - [`find_files`](#find_files)
    - [Third party Tools](#third-party-tools)
    - [How to Use Tools](#how-to-use-tools)
    - [Custom tools](#custom-tools)
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
      api_key = {
        deepseek = 'xxxxx',
        github = 'xxxxx',
      },
      width = 0.8, -- 80% of vim.o.columns
      height = 0.8, -- 80% of vim.o.lines
      border = 'rounded',
      -- default allowed_path is empty string, which means no files is allowed.
      -- this also can be a table of string.
      allowed_path = '',
    },
  },
})
```

## ⚙️ Usage

chat.nvim provides several commands to manage your AI conversations.
The main command is `:Chat`, which opens the chat window.
You can also navigate between sessions using the following commands.

### Basic Commands

| Command        | Description                                   |
| -------------- | --------------------------------------------- |
| `:Chat`        | Open the chat window with the current session |
| `:Chat new`    | Start a new chat session                      |
| `:Chat prev`   | Switch to the previous chat session           |
| `:Chat next`   | Switch to the next chat session               |
| `:Chat delete` | Delete current session                        |

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

4. **Open the chat window** (without changing sessions):
   ```vim
   :Chat
   ```
5. **Delete current session**:

   ```vim
   :Chat delete
   ```

   Cycles to next session or create a new session if current session is latest one.

All sessions are automatically saved and can be resumed later. For more advanced session management,
see the [Picker Integration](#-picker-integration) section below.

### Key Bindings

The following key bindings are available in the **Input** window:

| Mode     | Key Binding | Description                             |
| -------- | ----------- | --------------------------------------- |
| `Normal` | `<Enter>`   | Send message                            |
| `Normal` | `q`         | Close chat window                       |
| `Normal` | `<Tab>`     | Switch between input and result windows |
| `Normal` | `Ctrl-C`    | Cancel current request                  |
| `Normal` | `r`         | Retry last cancelled request            |
| `Normal` | `alt-h`     | previous chat session                   |
| `Normal` | `alt-l`     | next chat session                       |

The following key bindings are available in the **Result** window:

| Mode     | Key Binding | Description                             |
| -------- | ----------- | --------------------------------------- |
| `Normal` | `q`         | Close chat window                       |
| `Normal` | `<Tab>`     | Switch between input and result windows |

## 🤖 Providers

### Built-in Providers

1. `deepseek` - [DeepSeek AI](https://platform.deepseek.com/)
2. `github` - [GitHub AI](https://github.com/features/ai)
3. `moonshot` - [Moonshot AI](https://platform.moonshot.cn/)
4. `openrouter` - [OpenRouter](https://openrouter.ai/)
5. `qwen` - [Alibaba Cloud Qwen](https://www.aliyun.com/product/bailian)
6. `siliconflow` - [SiliconFlow](https://www.siliconflow.cn/)
7. `tencent` - [Tencent Hunyuan](https://cloud.tencent.com/document/product/1729)

### Custom Providers

chat.nvim also supports custom provider, just create `lua/chat/providers/<provider_name>.lua`, this lua module
should provides two functions `request` and `available_models`,
here is an example for using [free_chatgpt_api](https://github.com/popjane/free_chatgpt_api)

file: `~/.config/nvim/lua/chat/provides/free_chatgpt_api.lua`

```lua
local M = {}
local job = require('job')
local sessions = require('chat.sessions')
local config = require('chat.config')

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
    'Authorization: Bearer ' .. config.config.api_key.free_chatgpt,
    '-X',
    'POST',
    '@-',
  }

  local body = vim.json.encode({
    model = sessions.get_session_model(opt.session),
    messages = opt.messages,
    thinking = {
      type = 'enabled',
    },
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

return M
```

## Tools

chat.nvim supports tool call functionality, allowing the AI assistant to interact with your filesystem and other resources during conversations. Tools are invoked using the `@tool_name` syntax directly in your messages.

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

**Notes:**

- File paths can be relative to the current working directory or absolute
- The AI will receive the complete file content for context
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

- The pattern follows Vim's `globpath` syntax
- Searches are limited to the current working directory
- Returns a list of found files, with one file path per line
- Returns a message if no files are found based on the given pattern
- File searching is restricted by the `allowed_path` configuration setting

### Third party Tools

- `zettelkasten_create` - create new zettelkasten notes, provided by [zettelkasten.nvim](https://github.com/wsdjeg/zettelkasten.nvim)

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

The AI assistant will process the tool calls, read the specified files, and incorporate their content into its response. This enables more context-aware assistance without needing to manually copy-paste file contents.

### Custom tools

chat.nvim also supports custom tools. User can create `lua/chat/tools/<tool_name>.lua` file in their neovim runtime path.

This module should provide at least two functions: `scheme()` and `<tool_name>` function. The `scheme()` function returns a table describing the tool's schema (name, description, parameters). The `<tool_name>` function is the actual implementation that will be called when the tool is invoked.

The `tools.lua` module automatically discovers all tools in the `lua/chat/tools/` directory and provides an `available_tools()` function to list them, and a `call(func, arguments)` function to invoke a specific tool.

Here is an example for a `get_weather` tool:

```lua
local M = {}

---@param action { city: string, unit?: string }
function M.get_weather(action)
  if not action.city or action.city == '' then
    return {
      error = 'City name is required for weather information.',
    }
  end

  local unit = action.unit or 'celsius'
  local valid_units = { 'celsius', 'fahrenheit' }
  if not vim.tbl_contains(valid_units, unit) then
    return {
      error = 'Unit must be either "celsius" or "fahrenheit".',
    }
  end

  -- Simulate fetching weather data (in a real implementation, you would call an API here)
  local temperature = math.random(15, 35)  -- Random temperature between 15°C and 35°C
  local conditions = { 'Sunny', 'Cloudy', 'Rainy', 'Partly Cloudy', 'Windy' }
  local condition = conditions[math.random(1, #conditions)]

  -- Convert temperature if needed
  if unit == 'fahrenheit' then
    temperature = math.floor((temperature * 9/5) + 32)
  end

  return {
    content = string.format(
      'Weather in %s:\n- Temperature: %d°%s\n- Condition: %s\n- Humidity: %d%%\n- Wind Speed: %d km/h',
      action.city,
      temperature,
      unit == 'celsius' and 'C' or 'F',
      condition,
      math.random(40, 90),
      math.random(5, 25)
    ),
  }
end

function M.scheme()
  return {
    type = 'function',
    ['function'] = {
      name = 'get_weather',
      description = 'Get weather information for a specific city. Use @get_weather {city: "City Name"} to get weather details.',
      parameters = {
        type = 'object',
        properties = {
          city = {
            type = 'string',
            description = 'City name for weather information',
          },
          unit = {
            type = 'string',
            description = 'Temperature unit: "celsius" or "fahrenheit"',
            enum = { 'celsius', 'fahrenheit' },
          },
        },
        required = { 'city' },
      },
    },
  }
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
