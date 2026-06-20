---
layout: default
title: create_directory
parent: Tools
nav_order: 4
---

# create_directory

Create a directory (including parent directories).

## Usage

```
@create_directory path="<path>"
```

## Examples

- `@create_directory path="./src/utils"` - Create a nested directory
- `@create_directory path="./test/integration/fixtures"` - Create multiple levels
- `@create_directory path="./docs/api/v1"` - Create directory structure

## Parameters

| Parameter | Type   | Description                                                     |
| --------- | ------ | --------------------------------------------------------------- |
| `path`    | string | **Required**. Directory path to create (relative to cwd or absolute) |

## Notes

{: .info }
> - Equivalent to `mkdir -p` — creates all intermediate directories as needed
> - If the directory already exists, reports success without error
> - If path exists as a file, returns error
> - Path must be within working directory (cwd) and allowed_path config

