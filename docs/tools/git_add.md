---
layout: default
title: git_add
parent: Tools
nav_order: 16
---

# git_add

Stage file changes for commit.

## Usage

```
@git_add [path="<path>"] [all=true]
```

## Examples

- `@git_add path="src/main.lua"` - Add specific file
- `@git_add path=["src/main.lua", "src/utils.lua"]` - Add multiple files
- `@git_add all=true` - Add all changes (git add -A)
- `@git_add path="."` - Add all changes in current directory
- `@git_add path="./src"` - Add all changes in directory

## Parameters

| Parameter | Type            | Description                                      |
| --------- | --------------- | ------------------------------------------------ |
| `path`    | string\|array   | File or directory path(s) to add (optional)      |
| `all`     | boolean         | Add all changes (like git add -A) (optional)     |

## Notes

{: .info }
> - Requires git to be installed and in PATH
> - By default (no arguments), adds changes in current directory
> - Use `all=true` to add all changes in the repository
> - Files must be within the working directory

