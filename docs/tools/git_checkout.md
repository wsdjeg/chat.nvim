---
layout: default
title: git_checkout
parent: Tools
nav_order: 18
---

# git_checkout

Switch branches or restore working tree files.

## Usage

```
@git_checkout branch="<name>" [new_branch="<name>"] [file="<path>"]
```

## Examples

- `@git_checkout branch="develop"` - Switch to develop branch
- `@git_checkout new_branch="bugfix/login"` - Create new branch
- `@git_checkout file="README.md"` - Restore file
- `@git_checkout branch="feature" force=true` - Force switch (discard changes)
- `@git_checkout branch="origin/main" track=true` - Track and checkout remote branch
- `@git_checkout branch="v1.0.0" detach=true` - Checkout commit/tag (detached HEAD)

## Parameters

| Parameter   | Type    | Description                                          |
| ----------- | ------- | ---------------------------------------------------- |
| `branch`    | string  | Branch name to checkout                              |
| `new_branch`| string  | Create and checkout a new branch (-b)                |
| `file`      | string  | File path to restore from HEAD                       |
| `force`     | boolean | Force checkout                                       |
| `track`     | boolean | Set up tracking for remote branch                    |
| `detach`    | boolean | Detached HEAD (checkout commit or tag)               |

## Notes

{: .info }
> - Requires git to be installed and in PATH
> - Use `branch` for switching to existing branches or commits
> - Use `new_branch` to create and checkout a new branch (-b)
> - Use `file` to restore specific files from HEAD
> - Use `track=true` to set up upstream tracking for remote branches
> - Use `detach=true` when checking out commits or tags for detached HEAD
> - Use `force=true` to discard local changes when switching branches

