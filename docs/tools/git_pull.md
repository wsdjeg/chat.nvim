---
layout: default
title: git_pull
parent: Tools
nav_order: 23
---

# git_pull

{: .no_toc }

Pull changes from remote repository and merge.

## Usage

```
@git_pull [remote="<name>"] [branch="<name>"] [rebase=true] [force=true]
```

## Examples

- `@git_pull` - Pull from origin (current branch)
- `@git_pull branch="main"` - Pull specific branch from origin
- `@git_pull remote="upstream" branch="main"` - Pull from different remote
- `@git_pull rebase=true` - Use rebase instead of merge
- `@git_pull force=true` - Force pull

## Parameters

| Parameter | Type    | Description                                      |
| --------- | ------- | ------------------------------------------------ |
| `remote`  | string  | Remote name (optional)                           |
| `branch`  | string  | Branch name to pull (optional)                   |
| `rebase`  | boolean | Use rebase instead of merge (--rebase)           |
| `force`   | boolean | Force pull (--force)                             |

## Notes

{: .info }
> - Requires git to be installed and in PATH
> - Default remote is "origin" if not specified
> - Use `rebase=true` to avoid merge commits
> - Use `force=true` with caution (overwrites local changes)

