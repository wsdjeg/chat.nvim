
---
layout: default
title: Tools
parent: Usage Guide
nav_order: 2
---

# Tools

{: .no_toc }

Execute commands, read files, search code, and more with AI-powered tools.

## Table of contents
{: .no_toc .text-delta }
1. TOC
{:toc}

---

chat.nvim supports tool call functionality, allowing the AI assistant to interact with your filesystem, manage memories, and perform other operations during conversations. Tools are invoked using the `@tool_name` syntax directly in your messages.

---

## MCP Tools

MCP (Model Context Protocol) tools are automatically discovered and integrated when MCP servers are configured. These tools follow the naming pattern `mcp_<server>_<tool>` and work seamlessly with built-in tools.

### Example MCP Tools

- `mcp_open_webSearch_search` - Web search via MCP server
- `mcp_open_webSearch_fetchGithubReadme` - Fetch GitHub README via MCP
- `mcp_open_webSearch_fetchCsdnArticle` - Fetch CSDN article via MCP

MCP tools are automatically available when their servers are configured in the `mcp` section of your setup configuration. See [MCP Configuration](mcp.md) for details.

### Using MCP Tools

```
@mcp_open_webSearch_search query="neovim plugins" engines=["bing"] limit=10
@mcp_open_webSearch_fetchGithubReadme url="https://github.com/wsdjeg/chat.nvim"
```

MCP tools support all parameter types defined by their servers and execute asynchronously without blocking Neovim's UI.

---

## Available Tools

### read_file

Reads the content of a file and makes it available to the AI assistant.

#### Usage

```
@read_file <filepath>
```

#### Examples

- `@read_file ./src/main.lua` - Read a Lua file in the current directory
- `@read_file /etc/hosts` - Read a system file using absolute path
- `@read_file ../config.json` - Read a file from a parent directory

#### Advanced Usage with Line Ranges

```
@read_file ./src/main.lua line_start=10 line_to=20
```

#### Parameters

| Parameter     | Type    | Description                                                      |
| ------------- | ------- | ---------------------------------------------------------------- |
| `filepath`    | string  | **Required**. File path to read                                  |
| `line_start`  | integer | Starting line number (1-indexed, default: 1)                     |
| `line_to`     | integer | Ending line number (1-indexed, default: last line)               |

#### Notes

{: .info }
> - File paths can be relative to the current working directory or absolute
> - Supports line range selection with `line_start` and `line_to` parameters
> - Line numbers are 1-indexed (first line is line 1)
> - The AI will receive the file content for context
> - This is particularly useful for code review, debugging, or analyzing configuration files

---

### find_files

Finds files in the current working directory that match a given pattern.

#### Usage

```
@find_files <pattern>
```

#### Examples

- `@find_files *.lua` - Find all Lua files in the current directory
- `@find_files **/*.md` - Recursively find all Markdown files
- `@find_files src/**/*.js` - Find JavaScript files in the `src` directory and its subdirectories
- `@find_files README*` - Find files starting with "README"

#### Parameters

| Parameter   | Type    | Description                                                  |
| ----------- | ------- | ------------------------------------------------------------ |
| `pattern`   | string  | **Required**. Glob pattern to match files                    |
| `directory` | string  | Directory to search in (default: current working directory)  |
| `hidden`    | boolean | Include hidden files (default: false)                        |
| `no_ignore` | boolean | Do not respect .gitignore (default: false)                   |
| `exclude`   | array   | Exclude patterns (e.g., `["*.test.lua", "node_modules/*"]`)  |
| `max_results` | integer | Maximum number of results (default: 100, max: 1000)        |

#### Notes

{: .info }
> - Uses ripgrep (rg) for fast file finding with glob pattern support
> - Smart case: lowercase patterns are case-insensitive, uppercase are case-sensitive
> - Searches are limited to the current working directory
> - File searching is restricted by the `allowed_path` configuration setting

---

### search_text

Advanced text search tool using ripgrep (rg) to search text content in directories with regex support, file type filtering, exclusion patterns, and other advanced features.

#### Usage

```
@search_text <pattern> [options]
```

#### Basic Examples

- `@search_text "function.*test"` - Search for regex pattern in current directory
- `@search_text "TODO:" --file-types "*.lua"` - Search TODO comments in Lua files
- `@search_text "error" --context-lines 2` - Search for "error" with 2 lines of context

#### Parameters

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

#### Notes

{: .info }
> - Uses ripgrep (rg) for fast, powerful text searching
> - Supports full regex syntax for complex pattern matching
> - Search is restricted by the `allowed_path` configuration setting
> - Returns matching lines with file paths and line numbers
> - Particularly useful for code analysis, debugging, and finding references

---

### extract_memory

Extract memories from conversation text into a three-tier memory system (working, daily, long-term). Automatically detects memory type and category based on content analysis.

#### Usage

```
@extract_memory <parameters>
```

#### Memory Types

| Type        | Icon | Lifetime     | Priority | Use Case                                   |
| ----------- | ---- | ------------ | -------- | ------------------------------------------ |
| `working`   | ⚡   | Session only | Highest  | Current tasks, decisions, active context   |
| `daily`     | 📅   | 7-30 days    | Medium   | Short-term goals, today's tasks, reminders |
| `long_term` | 💾   | Permanent    | Normal   | Facts, preferences, skills, knowledge      |

#### Basic Examples

- `@extract_memory text="Python 的 GIL 是全局解释器锁，我习惯用 Vim 写代码"` (auto-detect type and category)
- `@extract_memory text="今天要完成用户登录功能" memory_type="daily"` (force daily memory)
- `@extract_memory text="当前正在修复登录 bug" memory_type="working"` (force working memory)

#### Parameters

| Parameter     | Type   | Description                                                                            |
| ------------- | ------ | -------------------------------------------------------------------------------------- |
| `text`        | string | Text to analyze for memory extraction                                                  |
| `memories`    | array  | Pre-extracted memories array (alternative to `text` parameter)                         |
| `memory_type` | string | Memory type: `"long_term"`, `"daily"`, or `"working"` (auto-detected if not set)       |
| `category`    | string | Category: `"fact"`, `"preference"`, `"skill"`, or `"event"` (auto-detected if not set) |

#### Auto-Detection Rules

The system automatically detects memory type based on keywords:

- **Working Memory**: "当前/正在/current", "任务/task", "决策/decision", "问题/issue"
- **Daily Memory**: "今天/明天/today/tomorrow", "待办/todo", "临时/temporary"
- **Long-term Memory**: Other persistent information

#### Notes

{: .info }
> - Extracts only persistent and reusable information
> - Automatically detects categories and memory types based on keywords
> - Working memory has highest priority and is cleared when session ends
> - Daily memory expires after configured retention days (default: 7)
> - Long-term memory persists permanently
> - Memory system must be enabled in chat.nvim configuration

---

### recall_memory

Retrieve relevant information from the three-tier memory system with priority-based ranking. Automatically extracts keywords if no query is provided.

#### Usage

```
@recall_memory <parameters>
```

#### Memory Priority Order

1. ⚡ **Working Memory** - Current session tasks/decisions (highest priority)
2. 📅 **Daily Memory** - Recent temporary information (medium priority)
3. 💾 **Long-term Memory** - Permanent knowledge base (normal priority)

#### Basic Examples

- `@recall_memory query="vim configuration"` - Search all memory types
- `@recall_memory` - Auto-extract keywords from current conversation
- `@recall_memory query="current task" memory_type="working"` - Search only working memory
- `@recall_memory query="today" memory_type="daily"` - Search only daily memory
- `@recall_memory query="python" memory_type="long_term"` - Search only long-term memory

#### Parameters

| Parameter      | Type    | Description                                                                |
| -------------- | ------- | -------------------------------------------------------------------------- |
| `query`        | string  | Search query (optional, auto-extracted from last message if not provided)  |
| `memory_type`  | string  | Filter by memory type: `"working"`, `"daily"`, or `"long_term"` (optional) |
| `limit`        | integer | Number of results (default: 5, maximum: 10)                                |
| `all_sessions` | boolean | Search all sessions instead of just current (default: false)               |

#### Notes

{: .info }
> - Returns formatted memory list that AI can reference for responses
> - Searches across all memory types with priority ranking
> - Working memory has highest priority and session isolation
> - Daily memory shows expiration countdown
> - Long-term memory shows access frequency
> - Useful for maintaining context across conversations

---

### git_diff

Run git diff to compare changes between working directory, index, or different branches.

#### Usage

```
@git_diff <parameters>
```

#### Basic Examples

- `@git_diff` - Show all unstaged changes in the repository
- `@git_diff cached=true` - Show staged changes (--cached)
- `@git_diff branch="main"` - Compare working directory with main branch
- `@git_diff path="./src"` - Show changes for specific file or directory

#### Parameters

| Parameter | Type    | Description                                                          |
| --------- | ------- | -------------------------------------------------------------------- |
| `path`    | string  | File or directory path to show diff for (optional)                   |
| `cached`  | boolean | Show staged changes (git diff --cached) (optional)                   |
| `branch`  | string  | Branch to compare against (e.g., "master", "origin/main") (optional) |

#### Notes

{: .info }
> - Requires git to be installed and available in PATH
> - Asynchronous execution - does not block Neovim's UI

---

### git_log

Show commit logs with various filters and options.

#### Usage

```
@git_log [parameters]
```

#### Basic Examples

- `@git_log` - Show last 5 commits (default)
- `@git_log count=10` - Show last 10 commits
- `@git_log path="./src/main.lua"` - Show commits for specific file
- `@git_log author="john"` - Filter by author

#### Parameters

| Parameter | Type    | Description                                                      |
| --------- | ------- | ---------------------------------------------------------------- |
| `path`    | string  | File or directory path (default: current working directory)      |
| `count`   | integer | Limit number of commits (default: 5, use 0 for no limit)         |
| `oneline` | boolean | Show each commit on a single line (default: true)                |
| `author`  | string  | Filter commits by author name or email                           |
| `since`   | string  | Show commits after this date (e.g., "2024-01-01", "2 weeks ago") |
| `from`    | string  | Starting tag/commit for range (e.g., "v1.4.0")                   |
| `to`      | string  | Ending tag/commit for range (default: HEAD)                      |
| `grep`    | string  | Search for pattern in commit messages                            |

---

### git_status

Show the working tree status.

#### Usage

```
@git_status [parameters]
```

#### Basic Examples

- `@git_status` - Show repository status (short format)
- `@git_status path="./src"` - Status for specific path
- `@git_status short=false` - Long format output

#### Parameters

| Parameter     | Type    | Description                       |
| ------------- | ------- | --------------------------------- |
| `path`        | string  | File or directory path (optional) |
| `short`       | boolean | Use short format (default: true)  |
| `show_branch` | boolean | Show branch info (default: true)  |

---

### get_history

Get conversation history messages from the current session.

#### Usage

```
@get_history [parameters]
```

#### Basic Examples

- `@get_history` - Get first 20 messages (default)
- `@get_history offset=20 limit=20` - Get messages 21-40
- `@get_history offset=0 limit=50` - Get first 50 messages (max)

#### Parameters

| Parameter | Type    | Description                                           |
| --------- | ------- | ----------------------------------------------------- |
| `offset`  | integer | Starting index (0 = oldest message, default: 0)       |
| `limit`   | integer | Number of messages to retrieve (default: 20, max: 50) |

#### Notes

{: .info }
> - Use this tool when you need to reference earlier messages not in current context window
> - Returns messages with their role, content, and timestamp
> - Maximum 50 messages per request
> - Useful for maintaining context across long conversations

---

### plan

Plan mode for creating, managing, and reviewing task plans with step-by-step tracking.

#### Usage

```
@plan action="<action>" [parameters]
```

#### Actions

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

#### Basic Examples

1. **Create a new plan:**

   ```
   @plan action="create" title="Implement feature X" steps=["Design API", "Write code", "Test"]
   ```

2. **List all plans:**

   ```
   @plan action="list"
   ```

3. **Start next step:**

   ```
   @plan action="next" plan_id="plan-20250110-1234"
   ```

4. **Complete a step:**

   ```
   @plan action="done" plan_id="plan-20250110-1234" step_id=1
   ```

---

## Third-party Tools

### zettelkasten_create

Create new zettelkasten notes, provided by [zettelkasten.nvim](https://github.com/wsdjeg/zettelkasten.nvim).

#### Usage

```
@zettelkasten_create <parameters>
```

#### Parameters

| Parameter | Type   | Description                        |
| --------- | ------ | ---------------------------------- |
| `title`   | string | The title of zettelkasten note     |
| `content` | string | The note body of zettelkasten      |
| `tags`    | array  | Optional tags for the note (max 3) |

---

### zettelkasten_get

Retrieve zettelkasten notes by tags, provided by [zettelkasten.nvim](https://github.com/wsdjeg/zettelkasten.nvim).

#### Usage

```
@zettelkasten_get <tags>
```

#### Parameters

| Parameter | Type  | Description                                         |
| --------- | ----- | --------------------------------------------------- |
| `tags`    | array | Tags to search for (e.g., `["programming", "vim"]`) |

---

## How to Use Tools

### 1. Direct invocation

Include the tool call directly in your message:

```
Can you review this code? @read_file ./my_script.lua
```

### 2. Multiple tools

Combine multiple tools in a single message:

```
Compare these two configs: @read_file ./config1.json @read_file ./config2.json
```

### 3. Natural integration

The tool calls can be embedded naturally within your questions:

```
What's wrong with this function? @read_file ./utils.lua
```

### 4. Memory management

Use memory tools for context-aware conversations:

```
Based on what we discussed earlier about Vim: @recall_memory query="vim"
```

The AI assistant will process the tool calls, execute the specified operations, and incorporate their results into its response.

---

## Custom Tools

chat.nvim supports both synchronous and **asynchronous** custom tools. Users can create `lua/chat/tools/<tool_name>.lua` file in their Neovim runtime path.

### Synchronous Tool Example

```lua
local M = {}

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
      parameters = {
        type = 'object',
        properties = {
          city = {
            type = 'string',
            description = 'City name',
          },
          unit = {
            type = 'string',
            description = 'Temperature unit (celsius or fahrenheit)',
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

### Asynchronous Tool Example

For long-running operations, you can create asynchronous tools using `job.nvim`:

```lua
local M = {}
local job = require('job')

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

### Key Points for Asynchronous Tools

{: .info }
> 1. Accept a second `ctx` parameter containing `{ cwd, session, callback }`
> 2. Return `{ jobid = <number> }` when starting async operation
> 3. Call `ctx.callback({ content = "..." })` or `ctx.callback({ error = "..." })` when done
> 4. The callback must include `jobid` in the result to match the async tracking
> 5. chat.nvim will wait for all async tools to complete before sending results to AI

---

## Next Steps

- [Memory System](memory.md) - Learn about the memory system
- [MCP](mcp.md) - Model Context Protocol
- [Providers](providers.md) - Configure AI providers

