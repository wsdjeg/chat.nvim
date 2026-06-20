---
layout: default
title: officecli
parent: Tools
nav_order: 21
---

# officecli

Run officecli to view office documents (currently supports Excel .xlsx).

## Usage

```
@officecli filepath="<path>" [command="view"] [mode="<mode>"]
```

## Examples

- `@officecli filepath="data.xlsx"` - Default text mode
- `@officecli filepath="data.xlsx" mode="text"` - Plain text dump
- `@officecli filepath="data.xlsx" mode="text" start=1 end=50` - Pagination
- `@officecli filepath="data.xlsx" mode="text" cols="A,B,C"` - Column filter
- `@officecli filepath="data.xlsx" mode="text" max_lines=100` - Limit output lines
- `@officecli filepath="data.xlsx" mode="annotated"` - Show formulas and types
- `@officecli filepath="data.xlsx" mode="outline"` - Structural overview
- `@officecli filepath="data.xlsx" mode="stats"` - Summary statistics
- `@officecli filepath="data.xlsx" mode="issues"` - Detect formula errors
- `@officecli filepath="data.xlsx" mode="html" browser=true` - Open in browser
- `@officecli filepath="data.xlsx" mode="text" json=true` - JSON output

## Parameters

| Parameter   | Type    | Description                                                        |
| ----------- | ------- | ------------------------------------------------------------------ |
| `filepath`  | string  | **Required**. Path to the office file (e.g., `users.xlsx`)         |
| `command`   | string  | officecli command (currently only `view` is supported)             |
| `mode`      | string  | View mode (default: `text`)                                        |
| `start`     | integer | Start row for pagination (1-indexed, inclusive)                    |
| `end`       | integer | End row for pagination (1-indexed, inclusive)                      |
| `cols`      | string  | Column filter, comma-separated (e.g., `"A,B,C"`)                   |
| `max_lines` | integer | Maximum number of output lines                                     |
| `json`      | boolean | Output as JSON                                                     |
| `browser`   | boolean | Open in default browser (only valid with `mode="html"`)            |

## View Modes

| Mode        | Description                                              |
| ----------- | -------------------------------------------------------- |
| `text`      | Plain text dump, tab-separated cell values per row       |
| `annotated` | Each cell with reference, value, type/formula, and warnings |
| `outline`   | Structural overview (sheets, rows, cols, formula counts) |
| `stats`     | Summary statistics across all sheets                     |
| `issues`    | Detect formula errors (`#REF!`, `#VALUE!`, `#NAME?`, `#DIV/0!`) |
| `html`      | Render as interactive HTML                               |

## Notes

{: .info }
> - Requires `officecli` to be installed and available in PATH
> - Install on Windows: `scoop install https://raw.githubusercontent.com/wsdjeg/Main-Plus/refs/heads/main/bucket/officecli.json`
> - The `browser` flag is only valid with `mode="html"`

