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

### Single File

```
@git_add path="src/main.lua"
```

### Multiple Files

**IMPORTANT**: Use JSON array format without quotes around the array.

```
# Correct format (JSON array, no quotes around the whole array)
@git_add path=["src/main.lua", "src/utils.lua", "README.md"]

# Wrong format (array wrapped in quotes - will NOT work)
@git_add path="["src/main.lua", "src/utils.lua"]"
```

### Add All Changes

```
@git_add all=true
```

### Add Directory

```
@git_add path="./src"
@git_add path="."
```

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

{: .warning }
> **Multiple Files Format**: When adding multiple files, use JSON array format:
> - ✅ Correct: `path=["file1.lua", "file2.lua"]`
> - ❌ Wrong: `path="["file1.lua", "file2.lua"]"`
>
> The array should NOT be wrapped in quotes!
