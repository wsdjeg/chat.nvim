---
layout: default
title: git_rebase
parent: Tools
nav_order: 24.5
---

# git_rebase

Rebase current branch onto another branch.

## Usage

```
@git_rebase branch="<name>"
@git_rebase abort=true
@git_rebase continue=true
@git_rebase skip=true
```

## Examples

- `@git_rebase branch="main"` - Rebase current branch onto main
- `@git_rebase branch="develop"` - Rebase onto develop
- `@git_rebase abort=true` - Abort current rebase
- `@git_rebase continue=true` - Continue after conflict resolution
- `@git_rebase skip=true` - Skip current commit and continue

## Parameters

| Parameter  | Type    | Description                                                   |
| ---------- | ------- | ------------------------------------------------------------- |
| `branch`   | string  | Branch to rebase onto                                         |
| `abort`    | boolean | Abort the current rebase (--abort)                            |
| `continue` | boolean | Continue the current rebase after resolving conflicts (--continue) |
| `skip`     | boolean | Skip the current commit and continue rebase (--skip)          |

## Notes

{: .warning }
> - Requires git to be installed and in PATH
> - Rebase rewrites history. Use with caution on shared branches
> - Use `abort=true` to cancel an in-progress rebase after conflicts
> - Use `continue=true` after resolving rebase conflicts (--continue)
> - Use `skip=true` to skip the current commit that has conflicts (--skip)
> - Unlike merge, rebase creates a linear history without merge commits

