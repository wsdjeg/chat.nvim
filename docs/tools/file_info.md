---
layout: default
title: file_info
parent: Tools
nav_order: 5
---

# file_info

Get file or directory metadata.

## Usage

```
@file_info filepath="<path>"
```

## Examples

- `@file_info filepath="./src/main.lua"` - Get metadata for a Lua file
- `@file_info filepath="./src/"` - Get metadata for a directory
- `@file_info filepath="./config.json"` - Get metadata for a JSON file

## Parameters

| Parameter  | Type   | Description                                              |
| ---------- | ------ | -------------------------------------------------------- |
| `filepath` | string | **Required**. File or directory path (relative to cwd or absolute) |

## Output

Returns the following metadata:

| Field        | Description                              |
| ------------ | ---------------------------------------- |
| Path         | Resolved absolute path                   |
| Type         | File type (file, dir, link, etc.)        |
| Size         | File size (human-readable + bytes)       |
| Entries      | Number of entries (for directories)      |
| Modified     | Last modification timestamp              |
| Permissions  | File permissions                         |
| Lines        | Line count (for text files under 1MB)    |
| Fileformat   | Detected line-ending format: `unix (LF)`, `dos (CRLF)` or `mac (CR)` |

## Notes

{: .info }
> - Lighter than `read_file` when you only need metadata, not content
> - Path must be within working directory (cwd) and allowed_path config
> - Line count is only calculated for text files smaller than 1MB
> - `Fileformat` is detected from the first line ending (omitted when the file has no line breaks);
>   pass the detected value as `fileformat` to `write_file` to preserve line endings

