---
layout: default
title: git_status
parent: Tools
nav_order: 10
---

# git_status

Show the working tree status.

## Usage

```
@git_status [parameters]
```

## Examples

- `@git_status` - Show repository status (short format)
- `@git_status path="./src"` - Status for specific path
- `@git_status short=false` - Long format output

## Parameters

| Parameter     | Type    | Description                       |
| ------------- | ------- | --------------------------------- |
| `path`        | string  | File or directory path (optional) |
| `short`       | boolean | Use short format (default: true)  |
| `show_branch` | boolean | Show branch info (default: true)  |

