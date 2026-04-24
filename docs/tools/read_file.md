---
layout: default
title: read_file
parent: Tools
nav_order: 1
---

# read_file

Reads the content of a file and makes it available to the AI assistant.

## Usage

```
@read_file <filepath>
```

## Examples

- `@read_file ./src/main.lua` - Read a Lua file in the current directory
- `@read_file /etc/hosts` - Read a system file using absolute path
- `@read_file ../config.json` - Read a file from a parent directory

## Advanced Usage with Line Ranges

```
@read_file ./src/main.lua line_start=10 line_to=20
```

## Parameters

| Parameter     | Type    | Description                                                      |
| ------------- | ------- | ---------------------------------------------------------------- |
| `filepath`    | string  | **Required**. File path to read                                  |
| `line_start`  | integer | Starting line number (1-indexed, default: 1)                     |
| `line_to`     | integer | Ending line number (1-indexed, default: last line)               |

## Output Format

The tool returns structured XML output for easier parsing:

**Full file:**
```xml
<FileContent>
file content here
</FileContent>
```

**With line range:**
```xml
<FileContent lines="10-20">
content from lines 10 to 20
</FileContent>
```

## Notes

{: .info }
> - File paths can be relative to the current working directory or absolute
> - Supports line range selection with `line_start` and `line_to` parameters
> - Line numbers are 1-indexed (first line is line 1)
> - The AI will receive the file content for context
> - This is particularly useful for code review, debugging, or analyzing configuration files
