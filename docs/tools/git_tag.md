---
layout: default
title: git_tag
parent: Tools
nav_order: 28
---

# git_tag

Manage git tags.

## Usage

```
@git_tag action="<action>" [name="<name>"] [message="<msg>"] [remote="<name>"]
```

## Examples

- `@git_tag action="create" name="v1.0.0" message="Initial release"` - Create annotated tag
- `@git_tag action="create" name="v1.0.0"` - Create lightweight tag
- `@git_tag action="list"` - List all tags
- `@git_tag action="delete" name="v1.0.0"` - Delete local tag
- `@git_tag action="push" name="v1.0.0"` - Push specific tag
- `@git_tag action="push" remote="origin"` - Push all tags
- `@git_tag action="create" name="v1.0.0" force=true` - Overwrite existing tag

## Parameters

| Parameter | Type    | Description                                              |
| --------- | ------- | -------------------------------------------------------- |
| `action`  | string  | Action type: create, list, delete, push (default: list)  |
| `name`    | string  | Tag name                                                 |
| `message` | string  | Tag message (for annotated tags)                         |
| `force`   | boolean | Force tag creation/deletion                              |
| `remote`  | string  | Remote name for push action (default: origin)            |

## Tag Types

| Type          | Description                              |
| ------------- | ---------------------------------------- |
| Lightweight   | Just a pointer to a commit               |
| Annotated     | Includes a message and stores metadata   |

## Notes

{: .info }
> - Requires git to be installed and in PATH
> - Annotated tags include a message and store metadata
> - Lightweight tags are just pointers to commits
> - Use `force=true` with caution when overwriting tags
> - Use `action="push"` without name to push all tags

