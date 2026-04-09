---
layout: default
title: git_fetch
parent: Tools
nav_order: 21
---

# git_fetch

{: .no_toc }

Fetch changes from remote repository.

## Usage

```
@git_fetch [remote="<name>"] [branch="<name>"] [all=true] [prune=true]
```

## Examples

- `@git_fetch` - Fetch from origin (default)
- `@git_fetch remote="upstream" branch="main"` - Fetch specific branch from upstream
- `@git_fetch all=true prune=true` - Fetch all remotes and remove deleted branches
- `@git_fetch tags=true` - Fetch all tags

## Parameters

| Parameter | Type    | Description                                              |
| --------- | ------- | -------------------------------------------------------- |
| `remote`  | string  | Remote name (default: "origin")                          |
| `branch`  | string  | Branch name to fetch                                     |
| `all`     | boolean | Fetch all remotes (--all)                                |
| `prune`   | boolean | Remove local branches that no longer exist on remote     |
| `tags`    | boolean | Fetch all tags (--tags)                                  |

## Notes

{: .info }
> - Requires git to be installed and in PATH
> - Default remote is "origin" if not specified
> - Unlike git_pull, this does not merge changes into your current branch
> - Use `prune=true` to clean up local branches that were deleted on remote

