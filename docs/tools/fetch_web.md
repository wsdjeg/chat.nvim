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
- `@fetch_web url="https://example.com" max_length=0` - Fetch full content without truncation
- `@fetch_web url="https://example.com" max_length=50000` - Fetch with custom truncation limit
- `@fetch_web url="https://example.com" markdown=true` - Convert HTML pages to Markdown before returning

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
| `max_length`     | integer | Maximum characters to display (default: 10000, set to 0 or -1 to disable truncation) |
| `markdown`      | boolean | Convert HTML response to Markdown via the html2markdown CLI before returning     |
| `output`        | string  | Save response to file instead of displaying (e.g., "./response.html")            |

## Notes

{: .warning }

> - Requires curl to be installed and available in PATH
> - SSL verification is enabled by default (disable with `insecure=true` for testing)
> - Responses are limited to 10,000 characters for display by default
> - Use `max_length=0` to disable truncation and get full content
> - For large responses, use the `output` parameter to save to a file

## Markdown conversion (markdown=true)

{: .info }

> - `markdown=true` pipes the HTML response through the [html2markdown](https://github.com/JohannesKaufmann/html-to-markdown) CLI, so the LLM receives clean Markdown instead of raw HTML (greatly reduces tokens)
> - Requires the `html2markdown` binary in PATH:
>   - `brew install JohannesKaufmann/tap/html2markdown`
>   - `go install github.com/JohannesKaufmann/html-to-markdown/v2/cli/html2markdown@latest`
> - Conversion only happens when the response is HTML; JSON and plain text are returned as-is
> - `max_length` truncation applies after conversion, to the Markdown output
> - Ignored when the `output` parameter is set (raw response is saved to file)

