---
layout: default
title: set_prompt
parent: Tools
nav_order: 5
---

# set_prompt

{: .no_toc }

Read a prompt file and set it as the current session's system prompt.

## Usage

```
@set_prompt <filepath>
```

## Examples

- `@set_prompt ./AGENTS.md`
- `@set_prompt ./prompts/code_review.txt`
- `@set_prompt ~/.config/chat.nvim/default_prompt.md`

## Parameters

| Parameter  | Type   | Description         |
| ---------- | ------ | ------------------- |
| `filepath` | string | Path to prompt file |

## Notes

{: .warning }

> - Updates the current session's system prompt with file content
> - File must be within the `allowed_path` configured in chat.nvim
> - Useful for switching between different agent roles or task-specific prompts
> - Supports relative and absolute paths

