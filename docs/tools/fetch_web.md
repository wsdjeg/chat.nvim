---
layout: default
title: fetch_web
parent: Tools
nav_order: 6
---

# fetch_web

Fetch content from web URLs using curl with comprehensive HTTP support.

## Usage

```
@fetch_web <parameters>
```

## Examples

- `@fetch_web url="https://example.com"` - Fetch content from a URL
- `@fetch_web url="https://api.github.com/repos/neovim/neovim" timeout=60` - Fetch with custom timeout

## Parameters

| Parameter       | Type    | Description                                                                      |
| --------------- | ------- | -------------------------------------------------------------------------------- |
| `url`           | string  | **Required**. URL to fetch (must start with http:// or https://)                 |
| `method`        | string  | HTTP method (default: "GET", options: GET, POST, PUT, DELETE, PATCH, HEAD)       |
| `headers`       | array   | Additional HTTP headers as strings (e.g., ["Authorization: Bearer token"])       |
| `data`          | string  | Request body data for POST/PUT requests                                          |
| `timeout`       | integer | Timeout in seconds (default: 30, minimum: 1, maximum: 300)                       |
| `user_agent`    | string  | Custom User-Agent header string (default: "Mozilla/5.0 (compatible; chat.nvim)") |
| `insecure`      | boolean | Disable SSL certificate verification (use with caution, for testing only)        |
| `max_redirects` | integer | Maximum number of redirects to follow (default: 5, set to 0 to disable)          |
| `output`        | string  | Save response to file instead of displaying (e.g., "./response.html")            |

## Notes

{: .warning }

> - Requires curl to be installed and available in PATH
> - SSL verification is enabled by default (disable with `insecure=true` for testing)
> - Responses are limited to 10,000 characters for display
> - For large responses, use the `output` parameter to save to a file

