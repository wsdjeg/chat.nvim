---
layout: default
title: lark_docx
parent: Tools
nav_order: 52
---

# lark_docx

Read and write Feishu/Lark Docs (云文档, `docx`).

## Prerequisites

- **App scope**: the Lark app needs the `docx:document` permission
  (plus `drive:drive` if you want `create` to place documents in a folder)
- **Collaborator**: the bot must be added as a collaborator of the document.
  Without this the API answers `91403` / `1254302`.
- **Credentials**: `integrations.lark.app_id` and `app_secret` in your config.
  The tool shares the tenant token cache with the Lark IM integration,
  `bitable` and `lark_sheets`.

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
@lark_docx action="<action>" [document_id="<doxcn...>"] [url="<link>"] [block_id="<block>"]
```

## Actions

| Action         | Method | Required                        | Description                            |
| -------------- | ------ | ------------------------------- | -------------------------------------- |
| `get`          | GET    | `document_id` or `url`          | Document metadata (title, revision)    |
| `read`         | GET    | `document_id` or `url`          | Flatten the document into markdown     |
| `append`       | POST   | token or `url`, plus `text`/`blocks` | Add blocks at the end              |
| `update_block` | PATCH  | token or `url`, `block_id`, `block` | Replace one block                  |
| `delete_block` | DELETE | token or `url`, `block_id`      | Remove one block and its children      |
| `create`       | POST   | `title`                         | Create an empty document in Drive      |

`action` defaults to `read`.

## Parameters

| Parameter      | Type    | Description                                                     |
| -------------- | ------- | --------------------------------------------------------------- |
| `action`       | string  | One of the actions above (default: `read`)                       |
| `document_id`  | string  | Document id, the `doxcn...` segment of the doc URL               |
| `url`          | string  | Document link (or a wiki link holding one) — alternative to the id |
| `block_id`     | string  | Block for `update_block` / `delete_block`; for `append` it selects the parent block (default: the document root) |
| `text`         | string  | Plain text to append, converted to blocks locally                 |
| `blocks`       | array   | Raw docx block objects to append (advanced)                       |
| `block`        | object  | Replacement block object (`update_block`)                         |
| `index`        | integer | Insertion position among the parent's children (default: `0` = end) |
| `page_size`    | integer | Blocks per page for `read`, max 500 (default: 500)                |
| `page_token`   | string  | Pagination cursor from a previous `read`                          |
| `title`        | string  | Title of the document to create (`create`, required)              |
| `folder_token` | string  | Folder to create the document in (`create`, optional)             |

## Appending content

Two ways in, chosen by which parameter you pass.

### `text` — recommended

Plain text is converted into docx blocks locally, so you never have to build
the nested `elements` structure by hand:

| Line looks like      | Becomes                       |
| -------------------- | ----------------------------- |
| `# Title`            | heading1 (`block_type` 3)     |
| `## Sub`             | heading2 (`block_type` 4)     |
| ... up to `######`   | heading6 (`block_type` 8)     |
| `- item` or `* item` | bullet (`block_type` 12)      |
| `1. item`            | ordered item (`block_type` 13)|
| anything else        | plain text (`block_type` 2)   |
| blank line           | skipped                       |

```
@lark_docx action="append" document_id="doxcnABC" text="# Report\n\n- finding one\n- finding two\n1. next step"
```

Notes:

- Seven or more `#` is not a heading level — the line falls back to plain text.
- `2)` is not a recognised ordered marker; only `N.` is.
- Blank lines are skipped rather than emitted as empty blocks, to keep the
  document tight.
- Nesting is intentionally flattened: docx indent properties differ from
  markdown, and guessing them silently produces wrong-looking documents. Use
  `blocks` when you need real nesting.

### `blocks` — raw control

The array is forwarded untouched as the request body's `children`:

```json
[{"block_type":2,"text":{"elements":[{"text_run":{"content":"hello"}}]}}]
```

| `block_type` | Meaning                    |
| ------------ | -------------------------- |
| 1            | page (document root)       |
| 2            | text                       |
| 3 .. 11      | heading1 .. heading9       |
| 12           | bullet                     |
| 13           | ordered                    |

Every text-ish block wraps its string in `elements` → `text_run` → `content`,
and the payload key mirrors the type (`text`, `heading1`, `bullet`,
`ordered`). A missing `text_run` wrapper is the single most common cause of a
rejected request.

## Reading

`read` rebuilds the block tree from the flat `parent_id` / `children` links and
renders it as markdown with headings and list markers (list children indent
one level). Inline styling, tables and images are flattened to their text.

- When the output ends with `[... document continues; call read again with
  page_token="..."]`, pass that token back for the next page.
- If the page's blocks have no usable tree links (their parent sits on a
  previous page), the API order is used as the fallback.

Each page is at most 500 blocks. Very long documents therefore take several
calls.

## Where to find tokens

- **`document_id`**: the `doxcn...` segment of the doc URL
  (`https://xxx.feishu.cn/docx/doxcnXXXX`). It is **not** a wiki `node_token`.
- **`block_id`**: from `read` output or the doc URL fragment. The document
  root block id **equals** `document_id`, which is what `append` uses when no
  `block_id` is given.
- **`url`**: paste the link instead. A `/wiki/wikcn...` link is resolved
  automatically (one extra request), but only when the wiki page actually
  holds a document.

## Examples

```
# document metadata
@lark_docx action="get" document_id="doxcnABC123"

# read the whole document as markdown
@lark_docx action="read" document_id="doxcnABC123"

# read, pasting the link (wiki links resolve automatically)
@lark_docx action="read" url="https://xxx.feishu.cn/docx/doxcnABC123"

# append markdown-ish text at the end
@lark_docx action="append" document_id="doxcnABC123" text="# Summary\n- point one\n- point two"

# append raw blocks
@lark_docx action="append" document_id="doxcnABC123" blocks=[{"block_type":2,"text":{"elements":[{"text_run":{"content":"hi"}}]}}]

# append under a specific block
@lark_docx action="append" document_id="doxcnABC123" block_id="blkParent" text="nested line"

# replace one block
@lark_docx action="update_block" document_id="doxcnABC123" block_id="blk1" block={"block_type":2,"text":{"elements":[{"text_run":{"content":"new"}}]}}

# remove one block and its children
@lark_docx action="delete_block" document_id="doxcnABC123" block_id="blk1"

# create a new document
@lark_docx action="create" title="Q1 Report"
```

## Notes

{: .info }
> - Requires `curl` to be installed and available in PATH
> - Request bodies are piped over stdin, so document content never appears in
>   the process command line
> - Cancelling while the tenant token (or a wiki node) is still being fetched
>   aborts the call without firing the request — a cancelled append never
>   touches your document
> - `create` returns the new document's `document_id`, which is the
>   `document_id` for every later call
> - `delete_block` removes the block **and all of its children**, and cannot
>   be undone

## Troubleshooting

| Error                        | Cause                                                   |
| ---------------------------- | ------------------------------------------------------- |
| `91403` / `1254302`          | The bot is not a collaborator of the document           |
| `1254005`                    | The app is missing the `docx:document` scope            |
| `1770001` / `invalid block`  | A text block is missing the `text_run` wrapper          |
| `Invalid JSON`               | Network/proxy returned a non-JSON page (check `log_id`) |

