---
layout: default
title: git_diff
parent: Tools
nav_order: 8
---

# git_diff

{: .no_toc }

Run git diff to compare changes between working directory, index, or different branches.

## Usage

```
@git_diff <parameters>
```

## Examples

- `@git_diff` - Show all unstaged changes in the repository
- `@git_diff cached=true` - Show staged changes (--cached)
- `@git_diff branch="main"` - Compare working directory with main branch
- `@git_diff path="./src"` - Show changes for specific file or directory

## Parameters

| Parameter | Type    | Description                                                          |
| --------- | ------- | -------------------------------------------------------------------- |
| `path`    | string  | File or directory path to show diff for (optional)                   |
| `cached`  | boolean | Show staged changes (git diff --cached) (optional)                   |
| `branch`  | string  | Branch to compare against (e.g., "master", "origin/main") (optional) |

## Notes

{: .info }

> - Requires git to be installed and available in PATH
> - Asynchronous execution - does not block Neovim's UI

