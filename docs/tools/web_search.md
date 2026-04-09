---
layout: default
title: web_search
parent: Tools
nav_order: 7
---

# web_search

{: .no_toc }

Search the web using Firecrawl, Google Custom Search API, or SerpAPI.

## Usage

```
@web_search <parameters>
```

## Supported Engines

1. **Firecrawl** (default): https://firecrawl.dev
2. **Google**: Google Custom Search JSON API
3. **SerpAPI**: https://serpapi.com - supports multiple search engines

## Configuration

API keys must be set in chat.nvim configuration:

```lua
require('chat').setup({
  api_key = {
    firecrawl = 'fc-YOUR_API_KEY',
    google = 'YOUR_GOOGLE_API_KEY',
    google_cx = 'YOUR_SEARCH_ENGINE_ID',
    serpapi = 'YOUR_SERPAPI_KEY'
  }
})
```

## Examples

1. Basic Firecrawl search:

   ```
   @web_search query="firecrawl web scraping"
   ```

2. SerpAPI with DuckDuckGo:

   ```
   @web_search query="privacy tools" engine="serpapi" serpapi_engine="duckduckgo"
   ```

## Parameters

| Parameter        | Type    | Description                                                                              |
| ---------------- | ------- | ---------------------------------------------------------------------------------------- |
| `query`          | string  | **Required**. Search query string                                                        |
| `engine`         | string  | Search engine to use: `"firecrawl"`, `"google"`, or `"serpapi"` (default: `"firecrawl"`) |
| `limit`          | integer | Number of results to return (default: 5 for firecrawl, 10 for google/serpapi)            |
| `api_key`        | string  | API key (optional if configured in config)                                               |
| `serpapi_engine` | string  | SerpAPI search engine: `"google"`, `"bing"`, `"duckduckgo"`, etc. (optional)             |

