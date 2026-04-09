---
layout: default
title: find_files
parent: Tools
nav_order: 1
---

# find_files

{: .no_toc }

Finds files in the current working directory that match a given pattern.

## Usage

```
@find_files <pattern>
```

## Examples

- `@find_files *.lua` - Find all Lua files in the current directory
- `@find_files **/*.md` - Recursively find all Markdown files
- `@find_files src/**/*.js` - Find JavaScript files in the `src` directory and its subdirectories
- `@find_files README*` - Find files starting with "README"

## Parameters

| Parameter     | Type    | Description                                                 |
| ------------- | ------- | ----------------------------------------------------------- |
| `pattern`     | string  | **Required**. Glob pattern to match files                   |
| `directory`   | string  | Directory to search in (default: current working directory) |
| `hidden`      | boolean | Include hidden files (default: false)                       |
| `no_ignore`   | boolean | Do not respect .gitignore (default: false)                  |
| `exclude`     | array   | Exclude patterns (e.g., `["*.test.lua", "node_modules/*"]`) |
| `max_results` | integer | Maximum number of results (default: 100, max: 1000)         |

## Notes

{: .info }

> - Uses ripgrep (rg) for fast file finding with glob pattern support
> - Smart case: lowercase patterns are case-insensitive, uppercase are case-sensitive
> - Searches are limited to the current working directory
> - File searching is restricted by the `allowed_path` configuration setting
