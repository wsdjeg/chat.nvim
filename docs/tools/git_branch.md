---
layout: default
title: git_branch
parent: Tools
nav_order: 17
---

# git_branch

Manage git branches.

## Usage

```
@git_branch [branch="<name>"] [create=true] [delete=true] [all=true]
```

## Examples

- `@git_branch` - List local branches
- `@git_branch all=true` - List all branches including remote
- `@git_branch branch="new-feature" create=true` - Create new branch
- `@git_branch branch="old-feature" delete=true` - Delete branch
- `@git_branch branch="bugfix" create=true force=true` - Force create/reset
- `@git_branch branch="temp" delete=true force=true` - Force delete

## Parameters

| Parameter | Type    | Description                                              |
| --------- | ------- | -------------------------------------------------------- |
| `list`    | boolean | List branches (default: true if no branch specified)     |
| `all`     | boolean | List all branches including remote ones (-a)             |
| `branch`  | string  | Branch name to create or delete                          |
| `create`  | boolean | Create a new branch                                      |
| `delete`  | boolean | Delete a branch                                          |
| `force`   | boolean | Force delete or reset                                    |
| `track`   | boolean | Set up tracking relationship                             |

## Notes

{: .info }
> - Requires git to be installed and in PATH
> - Default action is list if no branch specified
> - Use `create=true` to create a new branch from current HEAD
> - Use `delete=true` to delete a branch (uses -d, safe delete)
> - Use `force=true` with delete for -D (force delete)
> - Use `all=true` to show remote branches in list mode

