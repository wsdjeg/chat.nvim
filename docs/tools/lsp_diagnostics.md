---
layout: default
title: lsp_diagnostics
parent: Tools
nav_order: 20
---

# lsp_diagnostics

Get LSP diagnostics (errors, warnings, hints) for a file.

## Usage

```
@lsp_diagnostics filepath="<path>" [severity="<level>"] [line_start=N] [line_to=N]
```

## Examples

- `@lsp_diagnostics filepath="./src/main.lua"` - Get all diagnostics
- `@lsp_diagnostics filepath="./src/main.lua" severity="Error"` - Get only errors
- `@lsp_diagnostics filepath="./src/main.lua" severity="Warn"` - Get only warnings
- `@lsp_diagnostics filepath="./src/main.lua" line_start=10 line_to=20` - Get diagnostics for lines 10-20

## Parameters

| Parameter    | Type    | Description                                                        |
| ------------ | ------- | ------------------------------------------------------------------ |
| `filepath`   | string  | **Required**. File path to get diagnostics for (must be within cwd) |
| `severity`   | string  | Filter by severity: `Error`, `Warn`, `Info`, `Hint`, or `All` (default: `All`) |
| `line_start` | integer | Starting line number (1-indexed, inclusive)                        |
| `line_to`    | integer | Ending line number (1-indexed, inclusive)                          |

## Output Format

```
Found 2 diagnostic(s) in /path/to/file.lua:

  [Error] Line 10, Col 5: Undefined variable 'foo'
    (source: lua_ls, code: 114)
  [Warn] Line 20, Col 1: Unused local variable 'bar'
    (source: lua_ls)
```

## Notes

{: .info }
> - Requires an LSP client to be attached to the file
> - Line numbers are 1-indexed (first line is line 1)
> - `line_start` and `line_to` are both inclusive
> - filepath must be within the current working directory

