---
layout: default
title: get_weather
parent: Tools
nav_order: 15
---

# get_weather

Get weather data from Meizu weather API.

## Usage

```
@get_weather [city_id="<id>"] [city_ids=["id1", "id2"]] [timeout=30]
```

## Examples

- `@get_weather` - Get weather for default city (南昌)
- `@get_weather city_id="101010100"` - Get weather for 北京
- `@get_weather city_id="101020100"` - Get weather for 上海
- `@get_weather city_ids=["101010100", "101020100"]` - Get weather for multiple cities

## Parameters

| Parameter  | Type             | Description                                              |
| ---------- | ---------------- | -------------------------------------------------------- |
| `city_id`  | string\|number   | Single numeric city ID (e.g., 101240101 for 南昌)        |
| `city_ids` | array            | Multiple numeric city IDs. If provided, `city_id` is ignored |
| `timeout`  | integer          | Timeout in seconds (default: 30, min: 1, max: 300)       |

## Common City IDs

| City ID    | City   |
| ---------- | ------ |
| 101240101  | 南昌   |
| 101010100  | 北京   |
| 101020100  | 上海   |
| 101280601  | 深圳   |
| 101280101  | 广州   |
| 101270101  | 成都   |
| 101210101  | 杭州   |

## Notes

{: .info }
> - Requires `curl` to be installed and available in PATH
> - If no city ID is provided, defaults to 101240101 (南昌)
> - City IDs must contain digits only

