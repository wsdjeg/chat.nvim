---
layout: default
title: Tools
nav_order: 5
has_children: true
---

<!-- prettier-ignore-start -->
# Tools
{: .no_toc }
## Table of contents
{: .no_toc }
<!-- prettier-ignore-end -->

<!-- prettier-ignore -->
- content
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

MCP tools are automatically available when their servers are configured in the `mcp` section of your setup configuration. See [MCP Configuration](../mcp/) for details.

---

## Available Tools

here is a list of available tools:

| tool name                                    | description                                                        |
| -------------------------------------------- | ------------------------------------------------------------------ |
| [read_file](./read_file.md)                  | Reads the content of a file                                        |
| [write_file](./write_file.md)                | Write, modify, or delete file content                              |
| [find_files](./find_files.md)                | Finds files in the current working directory                       |
| [search_text](./search_text.md)              | Advanced text search using ripgrep                                 |
| [extract_memory](./extract_memory.md)        | Extract memories from conversation text                            |
| [recall_memory](./recall_memory.md)          | Retrieve relevant information from memory system                   |
| [set_prompt](./set_prompt.md)                | Set system prompt from file                                        |
| [fetch_web](./fetch_web.md)                  | Fetch content from web URLs                                        |
| [web_search](./web_search.md)                | Search the web using multiple engines                              |
| [make](./make.md)                            | Run make targets                                                   |
| [git_add](./git_add.md)                      | Stage file changes for commit                                      |
| [git_branch](./git_branch.md)                | Manage git branches                                                |
| [git_checkout](./git_checkout.md)            | Switch branches or restore files                                   |
| [git_commit](./git_commit.md)                | Create a git commit                                                |
| [git_config](./git_config.md)                | Get, set, or list git configuration                                |
| [git_diff](./git_diff.md)                    | Run git diff to compare changes                                    |
| [git_fetch](./git_fetch.md)                  | Fetch changes from remote repository                               |
| [git_log](./git_log.md)                      | Show commit logs with filters                                      |
| [git_merge](./git_merge.md)                  | Merge branches                                                     |
| [git_pull](./git_pull.md)                    | Pull changes from remote and merge                                 |
| [git_push](./git_push.md)                    | Push commits to remote repository                                  |
| [git_remote](./git_remote.md)                | Manage remote repositories                                         |
| [git_reset](./git_reset.md)                  | Reset current HEAD to specified state                              |
| [git_show](./git_show.md)                    | Show detailed changes of a specific commit                         |
| [git_stash](./git_stash.md)                  | Stash changes in git repository                                    |
| [git_status](./git_status.md)                | Show the working tree status                                       |
| [git_tag](./git_tag.md)                      | Manage git tags                                                    |
| [get_history](./get_history.md)              | Get conversation history messages                                  |
| [plan](./plan.md)                            | Plan mode for task management                                      |

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

This module should provide at least two functions: `scheme()` and `<tool_name>` function. The `scheme()` function returns a table describing the tool's schema (name, description, parameters). The `<tool_name>` function is the actual implementation that will be called when the tool is invoked.

### Synchronous Tool Example

Here is an example for a synchronous `get_weather` tool:

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

- [Memory System](../memory/) - Learn about the memory system
- [HTTP API](../api/http/) - HTTP API integration
- [IM Integration](../integrations/im/) - Instant messaging integrations
