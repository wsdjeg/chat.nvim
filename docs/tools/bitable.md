---
layout: default
title: bitable
parent: Tools
nav_order: 50
---

# bitable

Read and write Feishu/Lark Bitable (多维表格) records.

## Prerequisites

- **App scope**: the Lark app needs the `bitable:app` permission
- **Collaborator**: the bot must be added as a collaborator of the Bitable (or
  of the containing knowledge space). Without this the API answers
  `91403` / `1254302`.
- **Credentials**: `integrations.lark.app_id` and `app_secret` in your config.
  The tool shares the tenant token cache with the Lark IM integration.

The tool reports back either the response `data` (JSON) or a readable error
including the Feishu `log_id`.

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
@bitable action="<action>" app_token="<bascn...>" [table_id="<tbl...>"] [record_id="<rec...>"]
```

## Actions

| Action         | Method | Required                                  | Description                    |
| -------------- | ------ | ----------------------------------------- | ------------------------------ |
| `list_tables`  | GET    | `app_token`                               | List the tables of a Bitable   |
| `list_fields`  | GET    | `app_token`, `table_id`                   | List the fields of a table     |
| `search`       | POST   | `app_token`, `table_id`                   | Query records (see `body`)     |
| `get`          | GET    | `app_token`, `table_id`, `record_id`      | Read a single record           |
| `create`       | POST   | `app_token`, `table_id`, `fields`         | Add one record                 |
| `update`       | PUT    | `app_token`, `table_id`, `record_id`, `fields` | Modify one record         |
| `delete`       | DELETE | `app_token`, `table_id`, `record_id`      | Remove one record              |
| `batch_create` | POST   | `app_token`, `table_id`, `records`        | Add many records               |
| `batch_update` | POST   | `app_token`, `table_id`, `records`        | Modify many records            |

`action` defaults to `list_tables`.

## Parameters

| Parameter    | Type    | Description                                                        |
| ------------ | ------- | ------------------------------------------------------------------ |
| `action`     | string  | One of the actions above (default: `list_tables`)                  |
| `app_token`  | string  | Bitable app token, the `bascn...` segment of the base URL (required) |
| `table_id`   | string  | Table id (`tbl...`), required for every action except `list_tables` |
| `record_id`  | string  | Record id (`rec...`), required for `get` / `update` / `delete`     |
| `fields`     | object  | Record fields keyed by field name or field id (`create` / `update`) |
| `records`    | array   | Array of `{ fields = {...} }` objects (`batch_*`)                  |
| `body`       | object  | Raw search body: `filter` / `sort` / `field_names`                 |
| `page_size`  | integer | Page size, maximum 500                                             |
| `page_token` | string  | Pagination cursor from a previous page                             |

## Finding the IDs

- **`app_token`**: the `bascn...` segment of the base URL
  (`https://xxx.feishu.cn/base/bascnXXXX`). It is **not** `table_id` and **not**
  a wiki `node_token` — for a Bitable inside a wiki, resolve the node first.
- **`table_id`**: the `tbl...` segment, from `list_tables` or the table URL.
- **`record_id`**: the `rec...` id, from `search` or `get`.

## Field values

Values are strictly typed — a wrong type silently drops the record:

| Field type       | Value shape                                  |
| ---------------- | -------------------------------------------- |
| Text             | `"abc"` or `[{"type":"text","text":"abc"}]`  |
| Number           | `3`                                          |
| Date / datetime  | milliseconds timestamp (**not** seconds)     |
| Person           | `[{"id":"ou_xxx"}]`                          |
| Multi-select     | `["a","b"]`                                  |
| Single select    | `"a"`                                        |
| Link to table    | `[{"record_ids":["rec_xxx"]}]`                |

Prefer field **ids** over names when fields were renamed; `list_fields`
returns both.

## Examples

```
# discover tables
@bitable action="list_tables" app_token="bascnABC123"

# inspect field definitions before writing
@bitable action="list_fields" app_token="bascnABC123" table_id="tbl1"

# list records (no filter)
@bitable action="search" app_token="bascnABC123" table_id="tbl1"

# filtered + sorted query
@bitable action="search" app_token="bascnABC123" table_id="tbl1" body={"filter":{"conjunction":"and","conditions":[{"field_name":"Status","operator":"is","value":["Done"]}]},"sort":[{"field_name":"Created","desc":true}],"field_names":["Name","Status"]}

# create one record
@bitable action="create" app_token="bascnABC123" table_id="tbl1" fields={"Name":"hello","Count":3}

# update one record
@bitable action="update" app_token="bascnABC123" table_id="tbl1" record_id="rec1" fields={"Count":4}

# batch create
@bitable action="batch_create" app_token="bascnABC123" table_id="tbl1" records=[{"fields":{"Name":"a"}},{"fields":{"Name":"b"}}]
```

## Pagination

`page_size` is capped at 500. For larger tables, loop with `page_token`:

```
@bitable action="search" app_token="bascnABC123" table_id="tbl1" page_size=500
@bitable action="search" app_token="bascnABC123" table_id="tbl1" page_size=500 page_token="<next>"
```

## Notes

{: .info }
> - Requires `curl` to be installed and available in PATH
> - Record bodies are piped over stdin, so values never appear in the process
>   command line
> - Cancelling while the tenant token is still being fetched aborts the call
>   without firing the request — a cancelled write never touches your table
> - The tenant token is cached and shared with the Lark IM integration; a
>   single refresh covers both
> - Reading and writing both need the bot to be a collaborator of the Bitable

## Troubleshooting

| Error              | Cause                                                    |
| ------------------ | -------------------------------------------------------- |
| `91403` / `1254302`| The bot is not a collaborator of the Bitable              |
| `1254005`          | The app is missing the `bitable:app` scope               |
| `Invalid JSON`     | Network/proxy returned a non-JSON page (check `log_id`)  |

