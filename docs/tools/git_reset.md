---
layout: default
title: git_reset
parent: Tools
nav_order: 26
---

# git_reset

Reset current HEAD to the specified state.

## Usage

```
@git_reset [mode="<mode>"] [commit="<commit>"] [path="<path>"]
```

## Examples

- `@git_reset mode="soft" commit="HEAD~1"` - Undo last commit, keep changes staged
- `@git_reset mode="hard" commit="abc123"` - Reset to specific commit, discard changes
- `@git_reset path="README.md"` - Unstage changes to README.md
- `@git_reset mode="hard"` - Discard all local changes

## Parameters

| Parameter | Type    | Description                                              |
| --------- | ------- | -------------------------------------------------------- |
| `mode`    | string  | Reset mode: soft, mixed, or hard (default: mixed)        |
| `commit`  | string  | Commit hash, tag, or reference (default: HEAD)           |
| `path`    | string  | Specific file path or directory to reset                 |

## Reset Modes

| Mode    | Description                                      |
| ------- | ------------------------------------------------ |
| `soft`  | Moves HEAD only, keeps changes staged            |
| `mixed` | Moves HEAD, unstages changes (default)           |
| `hard`  | Moves HEAD, discards all changes                 |

## Notes

{: .warning }
> - Use `--hard` with caution as it permanently discards changes!
> - Consider stashing changes first if you might need them later
> - Requires git to be installed and in PATH

