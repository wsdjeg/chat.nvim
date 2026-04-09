---
layout: default
title: git_stash
parent: Tools
nav_order: 27
---

# git_stash

{: .no_toc }

Stash changes in git repository.

## Usage

```
@git_stash action="<action>" [message="<msg>"] [index=<n>]
```

## Examples

- `@git_stash action="save" message="Work in progress"` - Save current changes
- `@git_stash action="list"` - List all stashes
- `@git_stash action="pop"` - Pop latest stash
- `@git_stash action="drop" index=2` - Drop stash at index 2
- `@git_stash action="apply" index=1` - Apply stash at index 1
- `@git_stash action="clear"` - Remove all stashes

## Parameters

| Parameter | Type    | Description                                              |
| --------- | ------- | -------------------------------------------------------- |
| `action`  | string  | Action type: save, list, pop, drop, apply, clear         |
| `message` | string  | Message for save action                                  |
| `index`   | number  | Stash index (default: 0 for most recent)                 |

## Actions

| Action   | Description                          |
| -------- | ------------------------------------ |
| `save`   | Save current changes to stash        |
| `list`   | List all stashes                     |
| `pop`    | Apply and remove stash               |
| `drop`   | Delete a stash                       |
| `apply`  | Apply without removing               |
| `clear`  | Remove all stashes                   |

## Notes

{: .info }
> - Requires git to be installed and in PATH
> - Index 0 is the most recent stash
> - Use `apply` to keep stash for later use, `pop` to remove after applying
> - Use `drop` to delete a specific stash
> - Use `clear` to remove all stashes at once

