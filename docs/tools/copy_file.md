---
layout: default
title: copy_file
parent: Tools
nav_order: 3
---

# copy_file

Copy a file or directory (recursive).

## Usage

```
@copy_file source="<path>" destination="<path>" [overwrite=true]
```

## Examples

- `@copy_file source="./config.json" destination="./config.backup.json"` - Copy a file
- `@copy_file source="./src" destination="./src_copy"` - Copy a directory recursively
- `@copy_file source="./templates/" destination="./new_project/templates/" overwrite=true` - Overwrite existing destination

## Parameters

| Parameter      | Type    | Description                                                        |
| -------------- | ------- | ------------------------------------------------------------------ |
| `source`       | string  | **Required**. Source file/directory path (relative to cwd or absolute) |
| `destination`  | string  | **Required**. Destination file/directory path (relative to cwd or absolute) |
| `overwrite`    | boolean | Overwrite destination if it exists (default: false)                |

## Notes

{: .info }
> - Works for both files and directories
> - Directory copies are recursive
> - Source is preserved (unlike `move_file` which removes source)
> - Both source and destination must be within working directory (cwd) and allowed_path config
> - Prevents copying a directory into itself

