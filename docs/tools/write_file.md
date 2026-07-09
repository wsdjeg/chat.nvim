---
layout: default
title: write_file
parent: Tools
nav_order: 2
---

# write_file

Write, modify, or delete file content.

## Usage

```
@write_file filepath="<path>" [action="<action>"] [content="<content>"]
```

## Examples

- `@write_file filepath="./src/main.lua" action="create" content="print('hello')"` - Create new file
- `@write_file filepath="./src/main.lua" action="overwrite" content="new content"` - Overwrite file
- `@write_file filepath="./src/main.lua" action="append" content="\n-- added"` - Append content
- `@write_file filepath="./src/main.lua" action="insert" line_start=5 content="-- comment"` - Insert at line
- `@write_file filepath="./src/main.lua" action="delete" line_start=5 line_to=10` - Delete lines
- `@write_file filepath="./src/main.lua" action="replace" line_start=5 line_to=10 content="new lines"` - Replace lines
- `@write_file filepath="./src/main.lua" action="str_replace" old_str="local x = 1" new_str="local x = 2"` - Replace string
- `@write_file filepath="./src/main.lua" action="str_replace" old_str="TODO" new_str="DONE" replace_all=true` - Replace all occurrences
- `@write_file filepath="./src/main.lua" action="remove"` - Delete entire file

## Parameters

| Parameter     | Type     | Description                                                      |
| ------------- | -------- | ---------------------------------------------------------------- |
| `filepath`    | string   | **Required**. File path (relative to cwd or absolute)            |
| `action`      | string   | Action to perform (default: create)                              |
| `content`     | string   | Content to write (required for create/overwrite/append/insert/replace) |
| `line_start`  | integer  | Starting line number, 1-indexed (for insert/delete/replace)      |
| `line_to`     | integer  | Ending line number, 1-indexed (for delete/replace)               |
| `old_str`     | string   | String to find (for str_replace, literal matching, no regex)     |
| `new_str`     | string   | Replacement string (for str_replace, can be empty to delete text) |
| `replace_all` | boolean  | Replace all occurrences of old_str (default: false, requires exactly one match) |
| `backup`      | boolean  | Create backup before modification (default: false)               |
| `validate`    | boolean  | Validate syntax after modification for code files (default: false) |

## Actions

| Action       | Description                                                       |
| ------------ | ----------------------------------------------------------------- |
| `create`     | Create new file (fails if exists)                                 |
| `overwrite`  | Overwrite entire file content                                     |
| `append`     | Append content to end of file                                     |
| `insert`     | Insert content at specific line                                   |
| `delete`     | Delete specific line range                                        |
| `replace`    | Replace specific line range with new content                      |
| `str_replace`| Replace string by matching old_str (no line numbers needed)       |
| `remove`     | Delete entire file                                                |

## Notes

{: .info }
> - Line numbers are 1-indexed (first line is line 1)
> - `line_start` and `line_to` are both inclusive (e.g., line_start=5 line_to=10 deletes lines 5-10, including both)
> - Filepath must be within working directory (cwd) and allowed_path config
> - For insert: line_start can be #lines+1 to append at end
> - For str_replace: `old_str` uses literal string matching (no regex/patterns), supports multi-line matching
> - For str_replace: by default, `old_str` must match exactly once; use `replace_all=true` to replace all occurrences
> - For str_replace: `new_str` can be empty to delete the matched text
> - Use `validate=true` for code files to catch syntax errors (supports Lua and Python)
> - Use `backup=true` to create backup before modification (format: `<filepath>.backup.<timestamp>`)

