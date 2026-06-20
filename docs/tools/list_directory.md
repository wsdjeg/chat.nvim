---
layout: default
title: list_directory
parent: Tools
nav_order: 6
---

# list_directory

List directory contents with file metadata.

## Usage

```
@list_directory path="<path>" [recursive=true] [show_hidden=true] [max_results=50]
```

## Examples

- `@list_directory path="./src"` - List top-level contents of src directory
- `@list_directory path="./" recursive=true` - List all files recursively
- `@list_directory path="./test" show_hidden=true` - Include hidden files
- `@list_directory path="./project" max_results=50` - Limit results to 50 entries

## Parameters

| Parameter      | Type    | Description                                              |
| -------------- | ------- | -------------------------------------------------------- |
| `path`         | string  | **Required**. Directory path to list (relative to cwd or absolute) |
| `recursive`    | boolean | List recursively (default: false)                        |
| `show_hidden`  | boolean | Show hidden files (default: false)                       |
| `max_results`  | number  | Maximum number of entries to return (default: 200)       |

## Output Format

Each entry shows:

- Type indicator (`[DIR]` for directories, blank for files, `[LINK]` for symlinks)
- File/directory name
- File size (human-readable)
- Modification time

Directories are shown first, sorted alphabetically within each group.

## Notes

{: .info }
> - Non-recursive by default (top-level entries only)
> - Hidden files (starting with `.`) are hidden by default
> - Results are capped at `max_results` (default 200) to prevent overflow
> - Path must be within working directory (cwd) and allowed_path config

