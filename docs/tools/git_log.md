---
layout: default
title: git_log
parent: Tools
nav_order: 9
---

# git_log

Show commit logs with various filters and options.

## Usage

```
@git_log [parameters]
```

## Examples

- `@git_log` - Show last 5 commits (default)
- `@git_log count=10` - Show last 10 commits
- `@git_log path="./src/main.lua"` - Show commits for specific file
- `@git_log author="john"` - Filter by author

## Parameters

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

