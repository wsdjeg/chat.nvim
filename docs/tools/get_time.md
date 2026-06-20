---
layout: default
title: get_time
parent: Tools
nav_order: 14
---

# get_time

Get current time and date information.

## Usage

```
@get_time [format="<format>"] [timezone="<timezone>"]
```

## Examples

- `@get_time` - Get complete time information (default)
- `@get_time format="iso"` - Get ISO 8601 format only
- `@get_time timezone="utc"` - Get UTC time
- `@get_time format="unix"` - Get Unix timestamp only
- `@get_time format="human"` - Get human-readable format

## Parameters

| Parameter   | Type   | Description                                                        |
| ----------- | ------ | ------------------------------------------------------------------ |
| `format`    | string | Output format: `iso`, `unix`, `human`, or `all` (default: `all`)  |
| `timezone`  | string | Timezone: `local` or `utc` (default: `local`)                     |

## Output Formats

| Format  | Example                                              |
| ------- | ---------------------------------------------------- |
| `iso`   | `2025-01-10T14:30:00+08:00`                         |
| `unix`  | `1736490600`                                         |
| `human` | `2025年1月10日 星期五 14:30:00`                       |
| `all`   | Complete JSON with date details, timezone, and relative info |

## Notes

{: .info }
> - The `all` format includes date details (year, month, day, weekday), timezone offset, and relative info (is_weekend, time_of_day)
> - Both local and UTC times are included in the `all` format

