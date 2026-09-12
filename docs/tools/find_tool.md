---
layout: default
title: find_tool
parent: Tools
nav_order: 47
---

# find_tool

Search and discover tools by name or keyword, and get the full parameter schema.

With lazy tool loading (default), only essential tools are sent with each request to save prompt tokens. The `find_tool` tool embeds a live catalog of all available tools (name + one-line introduction), so the AI model can look up any tool on demand.

## Usage

```
@find_tool query="<tool name or keyword>"
```

## Examples

- `@find_tool query="git_log"` - Get the full parameter schema of `git_log`
- `@find_tool query="git log"` - Spaces are normalized (`git_log`)
- `@find_tool query="git"` - List all tools matching the keyword "git"
- `@find_tool query="list"` - Return the full catalog with introductions

## Parameters

| Parameter | Type   | Description                                    |
| --------- | ------ | ---------------------------------------------- |
| `query`   | string | Tool name or keyword to search for (required) |

## Behavior

- Exact name match (case-insensitive): returns the full tool schema and activates the tool for the current turn - it becomes callable in the next response
- Unique partial match: returns the schema directly (saves a round trip)
- Multiple matches: returns the candidate list with introductions
- No match: returns the full catalog to help refine the query
- `list` / `all` / `catalog` / empty query: returns the full catalog

## Activation & Turn Scope

- Tools returned by `find_tool` are activated for the current turn only: when the model replies with plain text (no tool calls), the turn is complete and activation is cleared
- The next turn starts fresh from the essential toolset plus `find_tool`
- Tools that were already called in the still-open turn are automatically re-included in requests (self-healing after an abort or restart mid tool-call loop)

## Example Flow

A typical turn with lazy tool loading:

```
You   : "Commit my changes"
Model : @find_tool query="git commit"     git_commit activated for this turn
Model : @git_add                          discovery continues in the same turn
Model : @git_commit message="feat: add x"
Model : "Committed as abc1234."           plain text, no tool call: turn ends, activation cleared
```

## Configuration

Lazy tool loading is controlled by the `tools` section:

```lua
require('chat').setup({
  tools = {
    lazy = true, -- send only essential + activated tools (default)
    essential = { 'read_file', 'list_directory', 'search_text', 'find_files', 'get_time' },
  },
})
```

Set `tools.lazy = false` to send all tools with every request (previous behavior).

## Notes

{: .info }
> - MCP tools are part of the catalog and can be discovered via `find_tool` too
> - Activated tools are turn-scoped and never persisted to disk

