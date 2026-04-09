---
layout: default
title: search_text
parent: Tools
nav_order: 2
---

# search_text

{: .no_toc }

Advanced text search tool using ripgrep (rg) to search text content in directories with regex support, file type filtering, exclusion patterns, and other advanced features.

## Usage

```
@search_text <pattern> [options]
```

## Examples

- `@search_text "function.*test"` - Search for regex pattern in current directory
- `@search_text "TODO:" --file-types "*.lua"` - Search TODO comments in Lua files
- `@search_text "error" --context-lines 2` - Search for "error" with 2 lines of context

## Advanced Usage with JSON Parameters

For more complex searches, you can provide a JSON object with multiple parameters:

```
@search_text {"pattern": "function.*test", "directory": "./src", "file_types": ["*.lua", "*.vim"], "ignore_case": true, "max_results": 50}
```

## Parameters

| Parameter          | Type    | Description                                                      |
| ------------------ | ------- | ---------------------------------------------------------------- |
| `pattern`          | string  | **Required**. Text pattern to search for (supports regex)        |
| `directory`        | string  | Directory path to search in (default: current working directory) |
| `ignore_case`      | boolean | Whether to ignore case (default: false)                          |
| `regex`            | boolean | Whether to use regex (default: true)                             |
| `max_results`      | integer | Maximum number of results (default: 100)                         |
| `context_lines`    | integer | Number of context lines to show around matches (default: 0)      |
| `whole_word`       | boolean | Whether to match whole words only (default: false)               |
| `file_types`       | array   | File type filter, e.g., `["*.py", "*.md", "*.txt"]`              |
| `exclude_patterns` | array   | Exclude file patterns, e.g., `["*.log", "node_modules/*"]`       |

## Notes

{: .info }

> - Uses ripgrep (rg) for fast, powerful text searching
> - Supports full regex syntax for complex pattern matching
> - Search is restricted by the `allowed_path` configuration setting
> - Returns matching lines with file paths and line numbers
> - Particularly useful for code analysis, debugging, and finding references

