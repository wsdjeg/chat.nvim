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
    - [Prerequisites](#prerequisites)
    - [Package Manager Installation](#package-manager-installation)
        - [Using lazy.nvim](#using-lazynvim)
        - [Using nvim-plug](#using-nvim-plug)
        - [Using packer.nvim](#using-packernvim)
        - [Using lazy.nvim with minimal configuration](#using-lazynvim-with-minimal-configuration)
    - [Manual Installation](#manual-installation)
    - [Post-Installation Setup](#post-installation-setup)
    - [Quick Start](#quick-start)
- [🔧 Configuration](#-configuration)
    - [Basic Options](#basic-options)
    - [API Key Configuration](#api-key-configuration)
    - [File Access Control](#file-access-control)
    - [Memory System Configuration](#memory-system-configuration)
    - [Complete Configuration Example](#complete-configuration-example)
    - [Configuration Notes](#configuration-notes)
- [⚙️ Usage](#-usage)
    - [Basic Commands](#basic-commands)
    - [Parallel Sessions](#parallel-sessions)
    - [Examples](#examples)
    - [Key Bindings](#key-bindings)
- [🤖 Providers](#-providers)
    - [Built-in Providers](#built-in-providers)
    - [Custom Providers](#custom-providers)
- [Tools](#tools)
- [Available Tools](#available-tools)
    - [`read_file`](#read_file)
    - [`find_files`](#find_files)
    - [`search_text`](#search_text)
    - [`extract_memory`](#extract_memory)
    - [`recall_memory`](#recall_memory)
    - [`set_prompt`](#set_prompt)
    - [`fetch_web`](#fetch_web)
    - [`web_search`](#web_search)
- [Third-party Tools](#third-party-tools)
    - [`zettelkasten_create`](#zettelkasten_create)
    - [`zettelkasten_get`](#zettelkasten_get)
- [How to Use Tools](#how-to-use-tools)
- [Custom Tools](#custom-tools)
- [🔍 Picker Integration](#-picker-integration)
- [📣 Self-Promotion](#-self-promotion)
- [💬 Feedback](#-feedback)
- [📄 License](#-license)
- [💬 Feedback](#-feedback-1)
- [📄 License](#-license-1)

<!-- vim-markdown-toc -->

## ✨ Features

- **Multiple AI Providers**: Built-in support for DeepSeek, GitHub AI, Moonshot, OpenRouter, Qwen, SiliconFlow, Tencent, BigModel, Volcengine, OpenAI, LongCat, and custom providers
- **Tool Call Integration**: Built-in tools for file operations (`@read_file`, `@find_files`, `@search_text`), memory management (`@extract_memory`, `@recall_memory`), web operations (`@fetch_web`, `@web_search`), and prompt management (`@set_prompt`)
- **Memory System**: Long-term memory storage and retrieval with automatic extraction of factual information and preferences
- **Parallel Sessions**: Run multiple independent conversations with different AI models, each maintaining separate context and settings
- **Session Management**: Commands for creating (`:Chat new`), navigating (`:Chat prev/next`), clearing (`:Chat clear`), deleting (`:Chat delete`) sessions, and changing working directory (`:Chat cd`)
- **Picker Integration**: Seamless integration with picker.nvim for browsing chat history (`picker-chat`), switching providers (`chat_provider`), and selecting models (`chat_model`)
- **Floating Window Interface**: Clean, non-intrusive dual-window layout with configurable dimensions and borders
- **Streaming Responses**: Real-time AI responses with cancellation support (`Ctrl-C`) and retry mechanism (`r`)
- **Token Usage Tracking**: Display real-time token consumption for each response
- **Lightweight Implementation**: Pure Lua with minimal dependencies and comprehensive error handling
- **Customizable Configuration**: Flexible setup for API keys, allowed paths, memory settings, and system prompts

## 📦 Installation

### Prerequisites

1. **System Dependencies** (optional but recommended for full functionality):
   - [`ripgrep` (rg)](https://github.com/BurntSushi/ripgrep): Required for the `@search_text` tool
   - [`curl`](https://curl.se/): Required for the `@fetch_web` tool
   - Install with your package manager:
     ```bash
     # Ubuntu/Debian
     sudo apt install ripgrep curl
     
     # macOS
     brew install ripgrep curl
     
     # Arch Linux
     sudo pacman -S ripgrep curl
     ```

2. **Neovim Plugin Dependencies**:
   - [`job.nvim`](https://github.com/wsdjeg/job.nvim): **Required** dependency for asynchronous operations
   - [`picker.nvim`](https://github.com/wsdjeg/picker.nvim): **Recommended** for enhanced session and provider management

### Package Manager Installation

#### Using [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
{
  'wsdjeg/chat.nvim',
  dependencies = {
    'wsdjeg/job.nvim',           -- Required
    'wsdjeg/picker.nvim',        -- Optional but recommended
  },
  opts = {
    provider = 'deepseek',
    api_key = {
      deepseek = 'sk-xxxxxxxxxxxx',
      github = 'github_pat_xxxxxxxx',
      -- Add other provider keys as needed
    },
    width = 0.8,
    height = 0.8,
    border = 'rounded',
    allowed_path = vim.fn.getcwd(), -- Allow access to current directory
    system_prompt = 'You are a helpful programming assistant.',
    memory = {
      enable = true,
      max_memories = 500,
      retrieval_limit = 3,
      similarity_threshold = 0.3,
    },
  },
}
```

#### Using [nvim-plug](https://github.com/junegunn/vim-plug)

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
        deepseek = 'sk-xxxxxxxxxxxx',
        github = 'github_pat_xxxxxxxx',
      },
      width = 0.8,
      height = 0.8,
      border = 'rounded',
      allowed_path = vim.fn.getcwd(),
      system_prompt = 'You are a helpful programming assistant.',
      memory = {
        enable = true,
        max_memories = 500,
        retrieval_limit = 3,
        similarity_threshold = 0.3,
      },
    },
  },
})
```

#### Using [packer.nvim](https://github.com/wbthomason/packer.nvim)

```lua
use {
  'wsdjeg/chat.nvim',
  requires = {
    'wsdjeg/job.nvim',
    'wsdjeg/picker.nvim', -- Optional
  },
  config = function()
    require('chat').setup({
      provider = 'deepseek',
      api_key = {
        deepseek = 'sk-xxxxxxxxxxxx',
        github = 'github_pat_xxxxxxxx',
      },
      width = 0.8,
      height = 0.8,
      border = 'rounded',
      allowed_path = vim.fn.getcwd(),
      system_prompt = 'You are a helpful programming assistant.',
      memory = {
        enable = true,
        max_memories = 500,
        retrieval_limit = 3,
        similarity_threshold = 0.3,
      },
    })
  end
}
```

#### Using [lazy.nvim](https://github.com/folke/lazy.nvim) with minimal configuration

```lua
{
  'wsdjeg/chat.nvim',
  dependencies = { 'wsdjeg/job.nvim' },
  opts = {} -- Uses all defaults
}
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

| Option          | Type   | Default            | Description                                               |
| --------------- | ------ | ------------------ | --------------------------------------------------------- |
| `width`         | number | `0.8`              | Chat window width (percentage of screen width, 0.0-1.0)   |
| `height`        | number | `0.8`              | Chat window height (percentage of screen height, 0.0-1.0) |
| `border`        | string | `'rounded'`        | Window border style, supports all Neovim border options   |
| `provider`      | string | `'deepseek'`       | Default AI provider                                       |
| `model`         | string | `'deepseek-chat'`  | Default AI model                                          |
| `strftime`      | string | `'%m-%d %H:%M:%S'` | Time display format                                       |
| `system_prompt` | string | `''`               | Default system prompt                                     |

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

### Memory System Configuration

Configure the behavior of the long-term memory system:

```lua
memory = {
  enable = true,                    -- Whether to enable the memory system
  max_memories = 500,               -- Maximum number of memories to store
  retrieval_limit = 3,              -- Maximum memories to retrieve per query
  similarity_threshold = 0.3,       -- Text similarity threshold (0-1)
  storage_dir = vim.fn.stdpath('cache') .. '/chat.nvim/memory/',
}
```

### Complete Configuration Example

```lua
require('chat').setup({
  -- Window settings
  width = 0.8,
  height = 0.8,
  border = 'rounded',

  -- AI provider settings
  provider = 'deepseek',
  model = 'deepseek-chat',
  api_key = {
    deepseek = 'sk-xxxxxxxxxxxx',
    github = 'github_pat_xxxxxxxx',
  },

  -- File access control
  allowed_path = {
    vim.fn.getcwd(),               -- Current working directory
    vim.fn.expand('~/.config/nvim'), -- Neovim config directory
  },

  -- Other settings
  strftime = '%Y-%m-%d %H:%M',
  system_prompt = 'You are a helpful programming assistant.',

  -- Memory system
  memory = {
    enable = true,
    max_memories = 1000,
    retrieval_limit = 5,
    similarity_threshold = 0.25,
  },
})
```

### Configuration Notes

1. **Path Security**: `allowed_path` restricts which file paths tools can access. Empty string disables all file access. Recommended to set to your current project directory for security.
2. **API Keys**: Only configure keys for providers you plan to use. Providers can be switched at runtime via the picker.
3. **Memory System**: Enabled by default, automatically extracts facts and preferences from conversations. Can be disabled with `memory.enable = false`.
4. **Dynamic Updates**: Some configurations (like provider and model) can be changed dynamically at runtime via the picker.

## ⚙️ Usage

chat.nvim provides several commands to manage your AI conversations.
The main command is `:Chat`, which opens the chat window.
You can also navigate between sessions using the following commands.

### Basic Commands

| Command          | Description                                         |
| ---------------- | --------------------------------------------------- |
| `:Chat`          | Open the chat window with the current session       |
| `:Chat new`      | Start a new chat session                            |
| `:Chat prev`     | Switch to the previous chat session                 |
| `:Chat next`     | Switch to the next chat session                     |
| `:Chat delete`   | Delete current session and create new empty session |
| `:Chat clear`    | Clear all messages in current session               |
| `:Chat cd <dir>` | Change current session cwd, open chat window        |

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
| `Normal` | `<Leaer>fr`  | run `:Picker chat`                      |
| `Normal` | `<Leaer>fp`  | run `:Picker chat_provider`             |
| `Normal` | `<Leader>fm` | run `:Picker chat_model`                |

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
8. `bigmodel` - [BigModel AI](https://bigmodel.cn/)
9. `volcengine` - [Volcengine AI](https://console.volcengine.com)
10. `openai` - [OpenAI](https://developers.openai.com/api/docs/)
11. `longcat` - [LongCat AI](https://longcat.chat/platform/docs/)

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

chat.nvim supports tool call functionality, allowing the AI assistant to interact with your filesystem, manage memories, and perform other operations during conversations. Tools are invoked using the `@tool_name` syntax directly in your messages.

## Available Tools

### `read_file`

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

### `find_files`

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

### `search_text`

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
| `exclude_patterns` | array   | Exclude file patterns, e.g., `["*.log", "tmp/*"]`                |

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

### `extract_memory`

Extract long-term memories from conversation text, focusing ONLY on factual information and habitual patterns. Filters out subjective feelings, temporary states, and irrelevant chatter.

**Usage:**

```
@extract_memory <parameters>
```

**Examples:**

- `@extract_memory text="Python的GIL是全局解释器锁，我习惯用Vim写代码" category="fact"`
- `@extract_memory text="我每天早晨6点起床锻炼，通常下午3点喝咖啡" category="preference"`

**Parameters:**

| Parameter  | Type   | Description                                                           |
| ---------- | ------ | --------------------------------------------------------------------- |
| `text`     | string | Text to analyze for memory extraction                                 |
| `memories` | array  | Pre-extracted memories array (alternative to `text` parameter)        |
| `category` | string | Suggested category: `"fact"`, `"preference"`, `"skill"`, or `"event"` |

**Category Definitions:**

- **fact**: Verifiable objective facts, data, definitions, rules
- **preference**: Personal habits, routine behaviors, regular practices
- **skill**: Technical abilities and knowledge
- **event**: Specific events and occurrences

**Notes:**

- Extracts only persistent and reusable information
- Automatically detects categories based on keywords
- Supports both raw text analysis and pre-processed memories
- Memory system must be enabled in chat.nvim configuration

### `recall_memory`

Retrieve relevant information from long-term memory and add to current conversation. Automatically extracts keywords if no query is provided.

**Usage:**

```
@recall_memory <parameters>
```

**Examples:**

- `@recall_memory query="vim configuration"`
- `@recall_memory query="programming tips" limit=8`
- `@recall_memory` (automatically extracts keywords from current conversation)

**Parameters:**

| Parameter      | Type    | Description                                                  |
| -------------- | ------- | ------------------------------------------------------------ |
| `query`        | string  | Search query (optional, auto-extracted if not provided)      |
| `limit`        | integer | Number of results (default: 5, maximum: 10)                  |
| `all_sessions` | boolean | Search all sessions instead of just current (default: false) |

**Notes:**

- Returns formatted memory list that AI can reference for responses
- Searches across categories and content
- Shows timestamps and contextual information
- Memory system must be enabled in chat.nvim configuration
- Useful for maintaining context across conversations

### `set_prompt`

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

### `fetch_web`

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

### `web_search`

Search the web using either Firecrawl or Google Custom Search API.

**Usage:**

```
@web_search <parameters>
```

**Supported Engines:**

1. **Firecrawl** (default): https://firecrawl.dev
2. **Google**: Google Custom Search JSON API

**Configuration:**

API keys must be set in chat.nvim configuration:

```lua
require('chat').setup({
  api_key = {
    firecrawl = 'fc-YOUR_API_KEY',
    google = 'YOUR_GOOGLE_API_KEY',
    google_cx = 'YOUR_SEARCH_ENGINE_ID'
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

5. Custom timeout:

   ```
   @web_search query="slow site" timeout=60
   ```

6. Firecrawl with scrape options:
   ```
   @web_search query="news" scrape_options={"formats":["markdown"]}
   ```

**Parameters:**

| Parameter        | Type    | Description                                                                                    |
| ---------------- | ------- | ---------------------------------------------------------------------------------------------- |
| `query`          | string  | Search query string                                                                            |
| `engine`         | string  | Search engine to use: `"firecrawl"` or `"google"` (default: `"firecrawl"`)                     |
| `limit`          | integer | Number of results to return (default: 5 for firecrawl, 10 for google)                          |
| `scrape_options` | object  | Options for scraping result pages (Firecrawl only, see Firecrawl docs)                         |
| `api_key`        | string  | API key (optional if configured in config.api_key.firecrawl or config.api_key.google)          |
| `cx`             | string  | Google Custom Search engine ID (required for Google engine if not in config.api_key.google_cx) |
| `timeout`        | integer | Timeout in seconds (default: 30, minimum: 1, maximum: 300)                                     |

**Notes:**

- Requires curl to be installed and available in PATH.
- Firecrawl API key is required for Firecrawl searches.
- Google API key and Custom Search engine ID (cx) are required for Google searches.
- Search results are returned in a formatted list.
- Supports both Firecrawl and Google search engines with configurable options.

## Third-party Tools

### `zettelkasten_create`

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

### `zettelkasten_get`

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

## How to Use Tools

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

## Custom Tools

chat.nvim also supports custom tools. Users can create `lua/chat/tools/<tool_name>.lua` file in their Neovim runtime path.

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

**Note**: The `chat` picker source displays all your active sessions, allowing quick switching between parallel conversations with different models.

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

## 💬 Feedback

If you encounter any bugs or have suggestions, please file an issue in the [issue tracker](https://github.com/wsdjeg/chat.nvim/issues).

## 📄 License

This project is licensed under the GPL-3.0 License.
