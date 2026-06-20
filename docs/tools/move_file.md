---
layout: default
title: move_file
parent: Tools
nav_order: 7
---

# move_file

Move or rename a file/directory.

## Usage

```
@move_file source="<path>" destination="<path>" [overwrite=true]
```

## Examples

- `@move_file source="./src/old.lua" destination="./src/new.lua"` - Rename a file
- `@move_file source="./src/utils.lua" destination="./lib/utils.lua"` - Move a file to another directory
- `@move_file source="./old_dir" destination="./new_dir" overwrite=true` - Rename directory, overwriting existing

## Parameters

| Parameter      | Type    | Description                                                        |
| -------------- | ------- | ------------------------------------------------------------------ |
| `source`       | string  | **Required**. Source file/directory path (relative to cwd or absolute) |
| `destination`  | string  | **Required**. Destination file/directory path (relative to cwd or absolute) |
| `overwrite`    | boolean | Overwrite destination if it exists (default: false)                |

## Notes

{: .info }
> - Works for both files and directories
> - Rename is attempted first (same-device, instant)
> - Falls back to copy + delete for cross-device moves
> - Both source and destination must be within working directory (cwd) and allowed_path config
> - Unlike `copy_file`, the source is removed after a successful move

