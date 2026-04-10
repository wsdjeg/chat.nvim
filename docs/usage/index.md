---
layout: default
title: Usage
nav_order: 4
has_children: false
---

# Usage

{: .no_toc }

## Table of contents

{: .no_toc .text-delta }

<!-- prettier-ignore -->
- content
{:toc}

---

chat.nvim provides several commands to manage your AI conversations. The main command is `:Chat`, which opens the chat window. You can also navigate between sessions using the following commands.

## Basic Commands

| Command               | Description                                         |
| --------------------- | --------------------------------------------------- |
| `:Chat`               | Open the chat window with the current session       |
| `:Chat new`           | Start a new chat session                            |
| `:Chat prev`          | Switch to the previous chat session                 |
| `:Chat next`          | Switch to the next chat session                     |
| `:Chat delete`        | Delete current session and create new empty session |
| `:Chat clear`         | Clear all messages in current session               |
| `:Chat cd <dir>`      | Change current session cwd, open chat window        |
| `:Chat save <path>`   | Save current session to specified file path         |
| `:Chat load <path>`   | Load session from file path or URL                  |
| `:Chat share`         | Share current session via pastebin                  |
| `:Chat preview`       | Open HTML preview of current session in browser     |
| `:Chat bridge`        | Bind current session to external platform (Discord) |
| `:Chat unbridge [im]` | Unbind integration (all or specific platform)       |

---

## MCP Commands

Manage MCP (Model Context Protocol) servers with the following commands:

### Stop MCP servers

```vim
:Chat mcp stop
```

Stops all running MCP servers and cleans up resources.

### Start MCP servers

```vim
:Chat mcp start
```

Starts all configured MCP servers. Note: Servers are automatically started when opening the chat window.

### Restart MCP servers

```vim
:Chat mcp restart
```

Restarts all MCP servers (stops and starts with a delay for cleanup).

{: .info }

> - MCP servers are automatically started when you open the chat window (`:Chat`)
> - MCP servers are automatically stopped when you exit Neovim
> - Use these commands for manual control if needed (e.g., after changing configuration)

---

## Parallel Sessions

chat.nvim supports running multiple chat sessions simultaneously, with each session operating independently:

- **Independent Model Selection**: Each session can use a different AI model (e.g., Session A with DeepSeek, Session B with GitHub AI)
- **Separate Contexts**: Sessions maintain their own conversation history, working directory, and settings
- **Quick Switching**: Use `:Chat prev` and `:Chat next` to navigate between active sessions
- **Isolated Workflows**: Perfect for comparing model responses or working on multiple projects simultaneously

### Workflow Example

1. Start a session with DeepSeek: `:Chat new` (then select DeepSeek model)
2. Switch to GitHub AI for a different task: `:Chat new` (select GitHub model)
3. Toggle between sessions: `:Chat prev` / `:Chat next`
4. Each session preserves its unique context and conversation flow

---

## Examples

### 1. Start a new conversation

```vim
:Chat new
```

This creates a fresh session and opens the chat window.

### 2. Resume a previous conversation

```vim
:Chat prev
```

Cycles backward through your saved sessions.

### 3. Switch to the next conversation

```vim
:Chat next
```

Cycles forward through your saved sessions.

### 4. Open or force to the chat window

```vim
:Chat
```

This command will not change current sessions.

### 5. Delete current session

```vim
:Chat delete
```

Cycles to next session or create a new session if current session is latest one.

### 6. Change the working directory of current session

```vim
:Chat cd ../picker.nvim/
```

If the current session is in progress, the working directory will not be changed, and a warning message will be printed.

### 7. Clear messages in current session

```vim
:Chat clear
```

If the current session is in progress, a warning message will be printed, and current session will not be cleared. This command also will forced to chat window.

### 8. Work with multiple parallel sessions

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

### 9. Save current session to a file

```vim
:Chat save ~/sessions/my-session.json
```

Saves the current session to a JSON file for backup or sharing.

### 10. Load session from file

```vim
:Chat load ~/sessions/my-session.json
```

Loads a previously saved session from a JSON file.

### 11. Load session from URL

```vim
:Chat load https://paste.rs/xxxxx
```

Loads a session from a URL (e.g., from paste.rs).

### 12. Share current session

```vim
:Chat share
```

Uploads the current session to paste.rs and copies the URL to clipboard. This allows easy sharing of conversations with others.

### 13. Preview current session in browser

```vim
:Chat preview
```

Opens an HTML preview of the current session in your default browser. The preview includes session metadata, messages, tool calls, and token usage statistics. You can also use `<C-o>` in the picker's chat source to open previews.

{: .info }

> All sessions are automatically saved and can be resumed later. For more advanced session management, see the [Picker Integration](#picker-integration) section below.

---

## Key Bindings

{: .warning }

### Input Window Key Bindings

The following key bindings are available in the **Input** window:

| Mode     | Key Binding  | Description                             |
| -------- | ------------ | --------------------------------------- |
| `Normal` | `<Enter>`    | Send message                            |
| `Normal` | `q`          | Close chat window                       |
| `Normal` | `<Tab>`      | Switch between input and result windows |
| `Normal` | `Ctrl-C`     | Cancel current request                  |
| `Normal` | `Ctrl-N`     | Open new session                        |
| `Normal` | `Ctrl-D`     | Delete current session                  |
| `Normal` | `r`          | Retry last cancelled request            |
| `Normal` | `alt-h`      | Previous chat session                   |
| `Normal` | `alt-l`      | Next chat session                       |
| `Normal` | `<Leader>fr` | Run `:Picker chat`                      |
| `Normal` | `<Leader>fp` | Run `:Picker chat_provider`             |
| `Normal` | `<Leader>fm` | Run `:Picker chat_model`                |

### Result Window Key Bindings

The following key bindings are available in the **Result** window:

| Mode     | Key Binding | Description                             |
| -------- | ----------- | --------------------------------------- |
| `Normal` | `q`         | Close chat window                       |
| `Normal` | `<Tab>`     | Switch between input and result windows |

---

## Picker Integration

chat.nvim provides built-in picker sources for seamless integration with [picker.nvim](https://github.com/wsdjeg/picker.nvim). These sources allow you to quickly access and manage your chat sessions, providers, and models.

{: .info }

> The `chat` picker source displays all your active sessions, allowing quick switching between parallel conversations with different models.

### Available Sources

#### 1. `chat` - Session History

Search through your chat history sessions:

- Uses the **first message** of each session as the search string
- Quickly resume previous conversations
- Supports filtering and session management

**Keyboard Shortcuts:**

- `<CR>` (Enter): Open selected session
- `<C-d>`: Delete selected session
- `<C-o>`: Open HTML preview in browser

#### 2. `chat_provider` - Provider Switcher

Switch between different AI providers:

- Dynamically change between supported providers (DeepSeek, OpenAI, etc.)
- Real-time switching without restarting Neovim

#### 3. `chat_model` - Model Selector

Select available models for the current provider:

- Lists all compatible models for your selected provider
- Intelligent filtering based on provider capabilities

---

## Session Management

### Automatic Saving

All sessions are automatically saved to:

```
stdpath('data')/chat.nvim/sessions/
```

### Session Files

Each session is stored as a JSON file with the following structure:

```json
{
  "id": "2024-01-15-10-30-00",
  "provider": "deepseek",
  "model": "deepseek-chat",
  "cwd": "/path/to/project",
  "messages": [
    {
      "role": "user",
      "content": "Hello!",
      "timestamp": "2024-01-15T10:30:00"
    },
    {
      "role": "assistant",
      "content": "Hi! How can I help you?",
      "timestamp": "2024-01-15T10:30:05"
    }
  ],
  "created_at": "2024-01-15T10:30:00",
  "updated_at": "2024-01-15T10:30:05"
}
```

### Session Commands

| Command             | Description                       |
| ------------------- | --------------------------------- |
| `:Chat save <path>` | Save session to custom location   |
| `:Chat load <path>` | Load session from file or URL     |
| `:Chat share`       | Upload session to paste.rs        |
| `:Chat preview`     | Open HTML preview in browser      |
| `:Chat delete`      | Delete current session            |
| `:Chat clear`       | Clear messages in current session |

---

## Window Management

### Floating Window

chat.nvim uses a floating window interface with:

- **Dual-window layout**: Separate input and result windows
- **Configurable dimensions**: Adjust width and height via configuration
- **Border styles**: Support for all Neovim border styles
- **Auto-scroll**: Intelligent scrolling behavior

### Window Dimensions

Configure window size in your setup:

```lua
require('chat').setup({
  width = 0.8,   -- 80% of screen width
  height = 0.8,  -- 80% of screen height
  border = 'rounded',
})
```

### Border Options

Supports all Neovim border styles:

- `"none"` - No border
- `"single"` - Single line border
- `"double"` - Double line border
- `"rounded"` - Rounded corners (default)
- `"solid"` - Solid border
- `"shadow"` - Shadow effect

---

## Streaming Responses

### Real-time Streaming

chat.nvim supports streaming responses from AI providers:

- **Real-time display**: See responses as they're generated
- **Cancellation support**: Press `Ctrl-C` to cancel ongoing requests
- **Retry mechanism**: Press `r` to retry the last cancelled request

### Token Usage Tracking

Real-time token consumption is displayed for each response:

```
Input: 150 tokens | Output: 75 tokens | Total: 225 tokens
```

{: .info }

> Token counts are displayed in the result window after each response, helping you monitor API usage.

---

## Tips and Tricks

### 1. Quick Session Switching

Use keyboard shortcuts for fast navigation:

- `alt-h` - Previous session
- `alt-l` - Next session
- `<Leader>fr` - Open session picker

### 2. Working with Multiple Projects

Use `:Chat cd` to change the working directory for each session:

```vim
:Chat cd ~/projects/project-a
" Work on project A...

:Chat new
:Chat cd ~/projects/project-b
" Work on project B...
```

### 3. Sharing Sessions

Share your conversations with others:

```vim
:Chat share
" URL copied to clipboard: https://paste.rs/xxxxx
```

### 4. Preview Sessions in Browser

Generate beautiful HTML previews:

```vim
:Chat preview
" Opens browser with formatted conversation
```

### 5. Session Backup

Save important sessions to files:

```vim
:Chat save ~/backups/important-session.json
```

---

Learn how to use chat.nvim's advanced features for enhanced productivity.

## Overview

chat.nvim provides powerful features beyond basic chatting:

- **Memory System**: Three-tier memory for context retention
- **MCP Protocol**: Extended tool capabilities via external servers
- **Tools**: 20+ built-in tools for file operations, Git, web search, etc.

---

## Features

### Memory System

chat.nvim implements a sophisticated three-tier memory system:

- **Working Memory** ⚡ - Session-scoped, highest priority
- **Daily Memory** 📅 - Temporary, auto-expires after 7-30 days
- **Long-term Memory** 💾 - Permanent knowledge storage

Learn more: [Memory System](/docs/memory/)

### MCP (Model Context Protocol)

Native MCP support for extended tool capabilities:

- Connect to MCP servers via stdio or HTTP
- Automatically discover MCP tools
- Seamlessly integrate with built-in tools

Learn more: [MCP](/docs/mcp/)

### Built-in Tools

20+ built-in tools for various operations:

- File: `read_file`, `write_file`, `find_files`, `search_text`
- Git: `git_add`, `git_commit`, `git_diff`, `git_log`, etc.
- Web: `fetch_web`, `web_search`
- Memory: `extract_memory`, `recall_memory`
- Planning: `plan`

## Next Steps

- [Providers](/docs/providers/) - Configure AI providers
- [Tools](/docs/tools/) - Explore available tools
- [Memory System](/docs/memory/) - Learn about the memory system
- [API Documentation](/docs/api/http/) - HTTP API integration
