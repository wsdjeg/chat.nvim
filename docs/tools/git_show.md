---
layout: default
title: git_show
parent: Tools
nav_order: 11
---

# git_show

Show detailed changes of a specific commit.

## Usage

```
@git_show commit=<commit> [parameters]
```

## Examples

- `@git_show commit="abc123"` - Show commit details
- `@git_show commit="v1.0.0"` - Show tag commit
- `@git_show commit="HEAD~1"` - Show previous commit

## Parameters

| Parameter | Type    | Description                                                         |
| --------- | ------- | ------------------------------------------------------------------- |
| `commit`  | string  | Commit hash, tag, or reference (e.g., "abc123", "v1.0.0", "HEAD~1") |
| `stat`    | boolean | Show stat only (file list with change counts) (optional)            |
| `path`    | string  | Filter to specific file path (optional)                             |

