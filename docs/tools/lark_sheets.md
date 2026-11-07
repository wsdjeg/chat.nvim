---
layout: default
title: lark_sheets
parent: Tools
nav_order: 51
---

# lark_sheets

Read and write Feishu/Lark Sheets (电子表格) cell values.

## Prerequisites

- **App scope**: the Lark app needs the `sheets:spreadsheet` permission
- **Collaborator**: the bot must be added as a collaborator of the spreadsheet.
  Without this the API answers `91403` / `1254302`.
- **Credentials**: `integrations.lark.app_id` and `app_secret` in your config.
  The tool shares the tenant token cache with the Lark IM integration and the
  `bitable` tool, so one refresh covers all of them.

```lua
require('chat').setup({
  integrations = {
    lark = {
      app_id = 'cli_xxxxxxxxxxxx',
      app_secret = 'xxxxxxxxxxxxxxxx',
    },
  },
})
```

## Usage

```
@lark_sheets action="<action>" [spreadsheet_token="<shtcn...>"] [url="<link>"] [range="Sheet1!A1:D10"]
```

## Actions

| Action         | Method | Required                              | Description                          |
| -------------- | ------ | ------------------------------------- | ------------------------------------ |
| `list_sheets`  | GET    | `spreadsheet_token` or `url`          | List the sheets of a spreadsheet     |
| `read`         | GET    | token or `url`, `range`                | Read a range as a markdown table     |
| `write`        | PUT    | token or `url`, `range`, `values`      | Overwrite a range                    |
| `append`       | POST   | token or `url`, `range`, `values`      | Append rows after the last used row  |
| `batch_update` | POST   | token or `url`, `value_ranges`         | Write several ranges in one request  |
| `create`       | POST   | `title`                                | Create an empty spreadsheet in Drive |

`action` defaults to `list_sheets`.

## Parameters

| Parameter           | Type    | Description                                                       |
| ------------------- | ------- | ----------------------------------------------------------------- |
| `action`            | string  | One of the actions above (default: `list_sheets`)                  |
| `spreadsheet_token` | string  | Spreadsheet token, the `shtcn...` segment of the sheet URL         |
| `url`               | string  | Sheet link (or a wiki link holding one) — alternative to the token |
| `range`             | string  | A1 range like `Sheet1!A1:D10` (required for `read`/`write`/`append`) |
| `values`            | array   | 2-D array of rows, e.g. `[["Name","Age"],["Ann",3]]`               |
| `value_ranges`      | array   | Array of `{ range, values }` objects (`batch_update`)              |
| `title`             | string  | Title of the spreadsheet to create (`create`, required)            |
| `folder_token`      | string  | Folder to create the spreadsheet in (`create`, optional)           |

Exactly one of `spreadsheet_token` and `url` is needed — `url` is the easier
one when you are looking at a link in the browser.

## Ranges

Ranges are `SheetName!A1:D10` style. Everything from the sheet name to the
range is inclusive, so `A1:A1` is a single cell.

- Call `list_sheets` first to learn the exact titles and `sheet_id`s.
- Prefer the `sheet_id` form (`0b1c2d!A1:D10`) when the sheet name contains
  spaces, has been renamed, or is not ASCII — it never goes stale.
- Sheet names are percent-encoded automatically, so `My Sheet!A1:B2` works.

## Reading output

`read` renders the range as a markdown table so the values are directly
usable in a reply:

```
| Name | Age |
| --- | --- |
| Ann | 3 |
| Bob | 4 |

(3 row(s) x 2 column(s), range Sheet1!A1:B2)
```

- The first row is treated as the header.
- Trailing empty cells are dropped by the API; the renderer pads them so the
  table stays rectangular.
- A pipe inside a cell is escaped (`\|`), and newlines collapse to spaces.

## Values

`write` / `append` / `batch_update` take a 2-D array of rows:

```json
[["Name","Age"],["Ann",3],["Bob",4]]
```

- Numbers, booleans and strings are accepted as-is.
- Formulas start with `=` and are evaluated by the spreadsheet.
- Formatted cells (dates, currencies) read back as their displayed text, so a
  read-write round trip may lose the underlying date value. Write a raw number
  if you need to preserve it.

## Where to find tokens

- **`spreadsheet_token`**: the `shtcn...` segment of the sheet URL
  (`https://xxx.feishu.cn/sheets/shtcnXXXX`). It is **not** a `sheet_id` and
  **not** a wiki `node_token`.
- **`url`**: paste the link instead. A `/wiki/wikcn...` link is resolved
  automatically (it costs one extra request) — but only when the wiki page
  actually *holds* a spreadsheet. If it holds a document or a Bitable, the
  call tells you so and stops before touching anything.

## Examples

```
# discover the sheets and their ids
@lark_sheets action="list_sheets" spreadsheet_token="shtcnABC123"

# same thing, pasting the link
@lark_sheets action="list_sheets" url="https://xxx.feishu.cn/sheets/shtcnABC123"

# read a range
@lark_sheets action="read" spreadsheet_token="shtcnABC123" range="Sheet1!A1:D10"

# overwrite a range
@lark_sheets action="write" spreadsheet_token="shtcnABC123" range="Sheet1!A1:B2" values=[["Name","Age"],["Ann",3]]

# append rows below the existing data
@lark_sheets action="append" spreadsheet_token="shtcnABC123" range="Sheet1!A1:B2" values=[["Bob",4]]

# several ranges in one request
@lark_sheets action="batch_update" spreadsheet_token="shtcnABC123" value_ranges=[{"range":"Sheet1!A1:B2","values":[[1,2]]},{"range":"Sheet1!D1:E2","values":[[3,4]]}]

# create a new spreadsheet
@lark_sheets action="create" title="Q1 Report"
```

## Notes

{: .info }
> - Requires `curl` to be installed and available in PATH
> - Request bodies are piped over stdin, so cell values never appear in the
>   process command line
> - Cancelling while the tenant token (or a wiki node) is still being fetched
>   aborts the call without firing the request — a cancelled write never
>   touches your spreadsheet
> - `create` returns the new spreadsheet's token, which is the
>   `spreadsheet_token` for every later call

## Troubleshooting

| Error                          | Cause                                                   |
| ------------------------------ | ------------------------------------------------------- |
| `91403` / `1254302`            | The bot is not a collaborator of the spreadsheet        |
| `1254005`                      | The app is missing the `sheets:spreadsheet` scope       |
| `90215` / `range is invalid`   | The sheet name in the range is wrong — call `list_sheets` and use the exact title or `sheet_id` |
| `Invalid JSON`                 | Network/proxy returned a non-JSON page (check `log_id`) |

