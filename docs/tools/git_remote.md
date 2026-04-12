---
layout: default
title: git_remote
parent: Tools
nav_order: 25
---

# git_remote

Manage set of tracked repositories (read-only).

## Usage

```
@git_remote [action="<action>"] [name="<name>"]
```

## Examples

- `@git_remote` - List all remotes
- `@git_remote action="list"` - List all remotes (verbose)
- `@git_remote action="get-url" name="origin"` - Get origin URL
- `@git_remote action="get-url" name="origin" push=true` - Get push URL

## Parameters

| Parameter | Type    | Description                                              |
| --------- | ------- | -------------------------------------------------------- |
| `action`  | string  | Action to perform (default: list)                        |
| `name`    | string  | Remote name (required for get-url)                       |
| `verbose` | boolean | Show verbose output for list (default: true)             |
| `push`    | boolean | Get push URL instead of fetch URL (for get-url)          |

## Actions

| Action     | Description                    |
| ---------- | ------------------------------ |
| `list`     | List remote repositories       |
| `get-url`  | Get URL of a remote            |

## Notes

{: .info }
> - Requires git to be installed and in PATH
> - This is a read-only operation
> - Use `action="get-url"` with `name` parameter to get remote URL
> - Use `push=true` to get push URL instead of fetch URL

