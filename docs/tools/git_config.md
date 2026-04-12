---
layout: default
title: git_config
parent: Tools
nav_order: 20
---

# git_config

Get, set, or list git configuration.

## Usage

```
@git_config action="<action>" [key="<key>"] [value="<value>"] [global=true]
```

## Examples

- `@git_config action="get" key="user.name"` - Get user name
- `@git_config action="set" key="user.email" value="user@example.com"` - Set user email
- `@git_config action="list"` - List all config
- `@git_config action="list" global=true` - List global config
- `@git_config action="get" key="core.editor" global=true` - Get global editor config
- `@git_config action="unset" key="user.name"` - Unset config key

## Parameters

| Parameter | Type    | Description                                              |
| --------- | ------- | -------------------------------------------------------- |
| `action`  | string  | Action type: get, set, list, or unset (default: get)     |
| `key`     | string  | Config key (e.g., "user.name" or "user.email")           |
| `value`   | string  | Config value (for set action)                            |
| `global`  | boolean | Use global config file                                   |
| `local`   | boolean | Use local config file (default)                          |
| `system`  | boolean | Use system config file                                   |
| `file`    | string  | Use specified config file path                           |

## Notes

{: .info }
> - Requires git to be installed and in PATH
> - Default scope is local (repository config)
> - Use `global=true` for user-wide settings
> - Use `system=true` for system-wide settings
> - Use `file` to specify a custom config file path

