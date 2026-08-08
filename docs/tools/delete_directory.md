---
layout: default
title: delete_directory
parent: Tools
nav_order: 4
---

# delete_directory

Delete a directory (recursive).

## Usage

```
@delete_directory path="<path>"
```

## Examples

- `@delete_directory path="./old_build"` - Delete a directory and all contents
- `@delete_directory path="./temp/cache"` - Delete nested cache directory

## Parameters

| Parameter | Type   | Description                                                        |
| --------- | ------ | ------------------------------------------------------------------ |
| `path`    | string | **Required**. Directory path to delete (relative to cwd or absolute) |

## Notes

{: .info }
> - Equivalent to `rm -rf` - deletes the directory and all contents recursively
> - Cannot delete the working directory (cwd) itself for safety
> - Path must be within working directory (cwd) and allowed_path config
> - If path does not exist, returns error
> - If path is a file (not directory), returns error (use `write_file` with `action="remove"` instead)

{: .warning }
> This operation is irreversible. Use with caution.

