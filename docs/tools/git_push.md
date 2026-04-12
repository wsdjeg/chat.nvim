---
layout: default
title: git_push
parent: Tools
nav_order: 24
---

# git_push

Push commits to remote repository.

## Usage

```
@git_push [remote="<name>"] [branch="<name>"] [set_upstream=true] [force=true]
```

## Examples

- `@git_push branch="feature-x"` - Push specific branch
- `@git_push remote="origin" branch="main"` - Push to origin
- `@git_push set_upstream=true branch="new-branch"` - Set upstream and push
- `@git_push force=true branch="main"` - Force push
- `@git_push all=true` - Push all branches
- `@git_push tags=true` - Push all tags

## Parameters

| Parameter      | Type    | Description                                      |
| -------------- | ------- | ------------------------------------------------ |
| `remote`       | string  | Remote name (default: "origin")                  |
| `branch`       | string  | Branch name to push                              |
| `set_upstream` | boolean | Set upstream for the branch (-u)                 |
| `force`        | boolean | Force push (--force)                             |
| `all`          | boolean | Push all branches (--all)                        |
| `tags`         | boolean | Push tags (--tags)                               |

## Notes

{: .info }
> - Requires git to be installed and in PATH
> - Default remote is "origin"
> - Use `set_upstream=true` to track remote branch
> - Use `force=true` with caution (rewrites history)
> - Use `all=true` to push all branches at once
> - Use `tags=true` to push all tags

