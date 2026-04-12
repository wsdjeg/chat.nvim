---
layout: default
title: git_merge
parent: Tools
nav_order: 22
---

# git_merge

Merge branches.

## Usage

```
@git_merge branch="<name>" [message="<msg>"] [no_ff=true] [ff_only=true]
```

## Examples

- `@git_merge branch="feature-x"` - Merge feature branch
- `@git_merge branch="develop" message="Update from develop"` - Merge with custom message
- `@git_merge branch="main" no_ff=true` - Force merge commit
- `@git_merge abort=true` - Abort current merge
- `@git_merge continue=true` - Continue after conflict resolution

## Parameters

| Parameter   | Type    | Description                                                      |
| ----------- | ------- | ---------------------------------------------------------------- |
| `branch`    | string  | Branch to merge                                                  |
| `message`   | string  | Merge commit message                                             |
| `no_ff`     | boolean | Create a merge commit even if fast-forward is possible (--no-ff) |
| `ff_only`   | boolean | Abort if fast-forward is not possible (--ff-only)                |
| `abort`     | boolean | Abort the current merge (--abort)                                |
| `continue`  | boolean | Continue the current merge after resolving conflicts             |

## Notes

{: .info }
> - Requires git to be installed and in PATH
> - Use `no_ff=true` to create a merge commit even if fast-forward is possible
> - Use `ff_only=true` to abort if fast-forward is not possible
> - Use `abort=true` to cancel an ongoing merge after conflicts
> - Use `continue=true` after resolving merge conflicts

