---
layout: default
title: find_tool
parent: Tools
nav_order: 47
---

# find_tool

Search and discover tools by name or keyword, and enable them for the current turn.

With lazy tool loading (default), only essential tools are sent with each request to save prompt tokens. The `find_tool` tool embeds a live catalog of all available tools (name + one-line introduction), so the AI model can look up any tool on demand.

## Usage

```
@find_tool query="<tool name or keyword>"
@find_tool query=["<tool name 1>", "<tool name 2>"]
```

## Examples

- `@find_tool query="git_log"` - Enable `git_log` for this turn
- `@find_tool query="git log"` - Spaces are normalized (`git_log`)
- `@find_tool query="git"` - List the names of tools matching the keyword "git"
- `@find_tool query="gcm"` - Fuzzy (subsequence) match resolves to `git_commit`
- `@find_tool query=["git_add", "git_commit"]` - Enable several tools in one call
- `@find_tool query="list"` - Remind that the catalog is in the tool description

## Parameters

| Parameter | Type                   | Description                                          |
| --------- | ---------------------- | ---------------------------------------------------- |
| `query`   | string \| string[]     | Tool name(s) or keyword(s) to search for (required)  |

`query` accepts either a single string or an array of strings. The array form
enables multiple tools in one round trip, which is faster than calling
`find_tool` once per tool when the model already knows which tools it needs.
Duplicated entries are activated once and reported once.

## Matching

Each query is resolved in this order:

1. **Exact name** - case-insensitive, spaces normalized to underscores
   (`git log` → `git_log`).
2. **Substring** - the query appears in the tool name or its one-line
   introduction. A unique hit is enabled directly; several hits are listed by
   name only.
3. **Fuzzy subsequence** - only when nothing matched above and the query is at
   least 3 characters long. An abbreviation whose characters appear in order
   inside a tool name counts as a match (`gcm` → `git_commit`, `wfl` →
   `write_file`). This stays cheap because it only runs as a fallback, and an
   ambiguous subsequence still returns the candidate names rather than
   guessing.

## Behavior

Responses are deliberately terse - they only report what happened:

| Situation            | Response                                                            |
| -------------------- | ------------------------------------------------------------------- |
| Exact name match     | `Enabled tool "git_log".` - activated for this turn                 |
| Unique partial match | Same as exact match (enabled directly, saves a round trip)           |
| Multiple matches     | `"git" matched 4 tools: git_add, git_branch, ...` - names only       |
| No match             | `No tool matched "xyz". The catalog of available tools is in the find_tool description above...` |
| `list` / empty query | Reminder that the catalog is already in the tool description        |

With an array query, one line is emitted per entry, so a single call can report
both `Enabled tool "git_add".` and `No tool matched "xyz".`.

No schema is echoed back. Once a tool is enabled, its full description and parameter schema appear in the tools list of the **next** request, so returning them here would only duplicate tokens. The catalog likewise already lives in the `find_tool` description, so unknown queries never repeat it.

The only exception: when there is no session to activate the tool in (e.g. a standalone invocation outside a chat session), the full schema is returned, because the tool would otherwise never become callable. For an array query the payload carries a `tools` array with every matched schema.

## Activation & Turn Scope

- Tools enabled by `find_tool` are activated for the current turn only: when the model replies with plain text (no tool calls), the turn is complete and activation is cleared
- The next turn starts fresh from the essential toolset plus `find_tool`
- Tools that were already called in the still-open turn are automatically re-included in requests (self-healing after an abort or restart mid tool-call loop)
- The request's tools array keeps a deterministic, append-only order: `tools.essential` → tools called in this turn → activated tools (in activation order) → `find_tool` last. Activating a tool only appends one entry, so the provider's prompt cache for the preceding prefix stays valid

## Example Flow

A typical turn with lazy tool loading:

```
You   : "Commit my changes"
Model : @find_tool query="git commit"     -> Enabled tool "git_commit".
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

