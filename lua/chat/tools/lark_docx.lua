-- lua/chat/tools/lark_docx.lua
-- Feishu/Lark Docs (云文档 / docx) read and write API.
--
-- One tool with an `action` enum, following bitable.lua and lark_sheets.lua.
--
-- docx blocks are `{ block_type = <int>, text = { elements = [...] } }`
-- structures, which are easy for a model to get subtly wrong: one missing
-- `text_run` wrapper and the request is rejected. So `append` is a two-layer
-- interface:
--   * `blocks`: raw block JSON, forwarded untouched (full control)
--   * `text`: markdown-ish plain text, converted locally into text/heading/
--     bullet/ordered blocks (the common case)
-- Reading works the other way round: blocks are flattened back into markdown
-- so the model does not have to reconstruct the tree from parent_id links.
--
-- Prerequisites (worth mentioning to the user when calls fail):
--   * the app needs the `docx:document` scope
--   * the bot must be added as a collaborator of the document, otherwise the
--     API answers 91403/1254302
--   * `document_id` is the `doxcn...` segment of the doc URL, not a wiki
--     `node_token` (a `/wiki/` link is resolved through integrations/lark/url.lua)
local M = {}

local lark_http = require('chat.integrations.lark.http')
local lark_url = require('chat.integrations.lark.url')

local OPEN_API = 'https://open.feishu.cn/open-apis'

--- Block type integers, as documented by the docx API.
local BLOCK = {
  page = 1,
  text = 2,
  bullet = 12,
  ordered = 13,
}

--- Heading block types are contiguous: heading1 = 3 .. heading9 = 11.
--- The docx API has nine levels, but markdown only has six: reading renders
--- all nine (a document can legitimately contain heading7), while writing
--- stops at six because "#" beyond six is not a heading any more.
local HEADING_BASE = 2
local MAX_DOCX_HEADING = 9
local MAX_MARKDOWN_HEADING = 6

--- action -> { method, path template }
local ROUTES = {
  get = { 'GET', '/docx/v1/documents/%s' },
  read = { 'GET', '/docx/v1/documents/%s/blocks' },
  append = { 'POST', '/docx/v1/documents/%s/blocks/%s/children' },
  update_block = { 'PATCH', '/docx/v1/documents/%s/blocks/%s' },
  delete_block = { 'DELETE', '/docx/v1/documents/%s/blocks/%s' },
  create = { 'POST', '/docx/v1/documents' },
}

--- Required parameters per action (besides `action` itself).
local REQUIRED = {
  get = {},
  read = {},
  append = {},
  update_block = { 'block_id' },
  delete_block = { 'block_id' },
  create = { 'title' },
}

--- Read the plain text out of one block element list.
--- @param elements any
--- @return string
local function elements_text(elements)
  if type(elements) ~= 'table' then
    return ''
  end
  local parts = {}
  for _, element in ipairs(elements) do
    if type(element) == 'table' then
      local run = element.text_run
      if type(run) == 'table' and type(run.content) == 'string' then
        parts[#parts + 1] = run.content
      elseif type(element.link) == 'table' then
        -- { link = { url = ..., } } style links carry no visible text.
        parts[#parts + 1] = element.link.url or ''
      end
    end
  end
  return table.concat(parts)
end

--- Plain text of a block, whichever key holds it.
--- @param block table
--- @return string
local function block_text(block)
  if type(block) ~= 'table' then
    return ''
  end
  -- Which key holds the payload depends on block_type: text has `text`,
  -- heading1 has `heading1`, bullet has `bullet`, ...
  local keys = {
    'text',
    'heading1',
    'heading2',
    'heading3',
    'heading4',
    'heading5',
    'heading6',
    'heading7',
    'heading8',
    'heading9',
    'bullet',
    'ordered',
  }
  for _, key in ipairs(keys) do
    if type(block[key]) == 'table' then
      return elements_text(block[key].elements)
    end
  end
  return ''
end

--- Flatten a block list into markdown, following children order.
--- The API returns a flat array with parent_id/children links, so the tree
--- has to be rebuilt before the document order is known.
--- @param items table[] Flat block array
--- @param root_id string Block id of the document root (= document_id)
--- @return string markdown
local function flatten(items, root_id)
  if type(items) ~= 'table' or #items == 0 then
    return ''
  end

  local by_id = {}
  for _, item in ipairs(items) do
    if type(item) == 'table' and item.block_id then
      by_id[item.block_id] = item
    end
  end

  -- Fall back to document order when the tree links are missing (partial
  -- pages return blocks whose parent is on a previous page).
  local lines = {}
  local visited = {}

  local function render_block(block, depth)
    if type(block) ~= 'table' or visited[block.block_id] then
      return
    end
    visited[block.block_id] = true

    local kind = block.block_type
    local text = block_text(block)
    local indent = string.rep('  ', depth)

    if kind and kind > HEADING_BASE and kind <= HEADING_BASE + MAX_DOCX_HEADING then
      lines[#lines + 1] = string.rep('#', kind - HEADING_BASE) .. ' ' .. text
    elseif kind == BLOCK.bullet then
      lines[#lines + 1] = indent .. '- ' .. text
    elseif kind == BLOCK.ordered then
      lines[#lines + 1] = indent .. '1. ' .. text
    elseif kind == BLOCK.page then
      -- Page blocks only hold the title, which `get` reports.
      if text ~= '' then
        lines[#lines + 1] = '# ' .. text
      end
    else
      lines[#lines + 1] = text
    end

    -- List items indent their children by one level; everything else keeps
    -- the current depth.
    local child_depth = depth
    if kind == BLOCK.bullet or kind == BLOCK.ordered then
      child_depth = depth + 1
    end

    local children = block.children
    if type(children) == 'table' then
      for _, child_id in ipairs(children) do
        local child = by_id[child_id]
        if child then
          render_block(child, child_depth)
        end
      end
    end
  end

  local root = by_id[root_id]
  if root and type(root.children) == 'table' and #root.children > 0 then
    for _, child_id in ipairs(root.children) do
      local child = by_id[child_id]
      if child then
        render_block(child, 0)
      end
    end
  else
    -- No usable tree: emit the blocks in the order the API returned them,
    -- skipping the root page block itself.
    for _, item in ipairs(items) do
      if type(item) == 'table' and item.block_id ~= root_id then
        render_block(item, 0)
      end
    end
  end

  -- Collapse runs of blank lines that empty text blocks leave behind.
  local out = {}
  local blank = false
  for _, line in ipairs(lines) do
    if line == '' then
      if not blank and #out > 0 then
        out[#out + 1] = line
      end
      blank = true
    else
      out[#out + 1] = line
      blank = false
    end
  end
  return table.concat(out, '\n')
end

--- Build one text-style block from a plain line.
--- @param text string Line content
--- @param block_type integer docx block type
--- @return table block
local function make_block(text, block_type)
  local payload = { elements = { { text_run = { content = text } } } }
  local key = 'text'
  if block_type >= 3 and block_type <= HEADING_BASE + MAX_DOCX_HEADING then
    key = 'heading' .. tostring(block_type - HEADING_BASE)
  elseif block_type == BLOCK.bullet then
    key = 'bullet'
  elseif block_type == BLOCK.ordered then
    key = 'ordered'
  end

  local block = { block_type = block_type }
  block[key] = payload
  return block
end

--- Convert markdown-ish plain text into docx blocks.
--- Supported: `# `..`#### ` headings, `- `/`* ` bullets, `1. ` ordered items,
--- and plain lines. Deeply nested lists are intentionally flattened: the
--- docx indent properties differ from markdown, and guessing them silently
--- produces wrong-looking documents.
--- @param text string
--- @return table[] blocks
local function text_to_blocks(text)
  local blocks = {}
  for _, line in ipairs(vim.split(text, '\n', { plain = true })) do
    local trimmed = vim.trim(line)
    if trimmed == '' then
      -- Blank lines are layout in markdown but real empty blocks in docx;
      -- skipping them keeps the document tight.
      goto continue
    end

    local hashes, rest = trimmed:match('^(#+)%s+(.*)$')
    if hashes and #hashes <= MAX_MARKDOWN_HEADING then
      blocks[#blocks + 1] = make_block(rest, HEADING_BASE + #hashes)
    else
      local bullet = trimmed:match('^[-*]%s+(.*)$')
      if bullet then
        blocks[#blocks + 1] = make_block(bullet, BLOCK.bullet)
      else
        local ordered = trimmed:match('^%d+%.%s+(.*)$')
        if ordered then
          blocks[#blocks + 1] = make_block(ordered, BLOCK.ordered)
        else
          blocks[#blocks + 1] = make_block(trimmed, BLOCK.text)
        end
      end
    end

    ::continue::
  end
  return blocks
end

--- Validate that `blocks` is a non-empty array of objects.
--- @param blocks any
--- @return string|nil err
local function check_blocks(blocks)
  if type(blocks) ~= 'table' or #blocks == 0 then
    return 'blocks must be a non-empty array of block objects.'
  end
  for i, block in ipairs(blocks) do
    if type(block) ~= 'table' then
      return string.format('blocks[%d] must be an object, got: %s', i, type(block))
    end
    if type(block.block_type) ~= 'number' then
      return string.format(
        'blocks[%d].block_type is required (integer, e.g. 2 for text).',
        i
      )
    end
  end
  return nil
end

--- Build the request body for an action; nil when the action has none.
--- @param action table Tool arguments
--- @param name string Action name
--- @return table|nil body
--- @return string|nil err
local function build_body(action, name)
  if name == 'create' then
    local body = { title = action.title }
    if action.folder_token and action.folder_token ~= '' then
      body.folder_token = action.folder_token
    end
    return body
  end

  if name == 'append' then
    if type(action.blocks) == 'table' and #action.blocks > 0 then
      local err = check_blocks(action.blocks)
      if err then
        return nil, err
      end
      return { children = action.blocks, index = action.index or 0 }
    end

    if type(action.text) == 'string' then
      local blocks = text_to_blocks(action.text)
      if #blocks == 0 then
        return nil, 'text contains no content to append.'
      end
      return { children = blocks, index = action.index or 0 }
    end

    return nil, 'Provide either blocks (raw block JSON) or text (plain text '
      .. 'with # headings, - bullets and 1. ordered items) for the append '
      .. 'action.'
  end

  if name == 'update_block' then
    if type(action.block) ~= 'table' or next(action.block) == nil then
      return nil, 'block is required for the update_block action '
        .. '(the replacement block object, e.g. '
        .. '{ block_type = 2, text = { elements = [...] } }).'
    end
    return action.block
  end

  return nil
end

--- Compose the request URL.
--- @param action table Tool arguments
--- @param name string Action name
--- @param doc_id string Document id resolved earlier
--- @return string url
local function build_url(action, name, doc_id)
  local route = ROUTES[name]
  local path
  if name == 'append' then
    -- The root block id equals the document id, so a missing block_id means
    -- "append at the end of the document".
    local parent = action.block_id
    if type(parent) ~= 'string' or parent == '' then
      parent = doc_id
    end
    path = string.format(route[2], doc_id, parent)
  elseif name == 'update_block' or name == 'delete_block' then
    path = string.format(route[2], doc_id, action.block_id)
  elseif name == 'create' then
    path = route[2]
  else
    path = string.format(route[2], doc_id)
  end

  local url = OPEN_API .. path
  if name == 'read' then
    local query = {}
    if action.page_token and action.page_token ~= '' then
      query[#query + 1] = 'page_token=' .. action.page_token
    end
    query[#query + 1] = 'page_size=' .. tostring(action.page_size or 500)
    url = url .. '?' .. table.concat(query, '&')
  end
  return url
end

--- Resolve the document id for an action.
--- @param action table Tool arguments
--- @return table result { doc_id = string|nil, wiki_node = string|nil, err = string|nil }
local function resolve_doc(action)
  local id = action.document_id
  if type(id) == 'string' and id ~= '' then
    return { doc_id = id }
  end

  if type(action.url) ~= 'string' or action.url == '' then
    return {
      err = 'document_id (or url) is required. It is the "doxcn..." segment '
        .. 'of the document link.',
    }
  end

  local parsed = lark_url.parse(action.url)
  if not parsed then
    return {
      err = 'Could not recognise a Feishu/Lark link in url. Expected a '
        .. 'https://xxx.feishu.cn/docx/doxcn... link (or a /wiki/ link '
        .. 'pointing at a document).',
    }
  end

  if parsed.type == 'docx' then
    return { doc_id = parsed.token }
  end

  if parsed.type == 'wiki' then
    return { wiki_node = parsed.token }
  end

  return {
    err = string.format(
      'url points at %s, not a cloud document.',
      lark_url.label(parsed.type)
    ),
  }
end

--- @param action ChatToolsLarkDocxAction
--- @param ctx ChatToolContext
function M.lark_docx(action, ctx)
  action = action or {}
  local name = action.action or 'read'

  if not ROUTES[name] then
    return {
      error = string.format(
        'Unknown action: %s. Must be one of: %s.',
        tostring(name),
        table.concat(vim.tbl_keys(ROUTES), ', ')
      ),
    }
  end

  for _, field in ipairs(REQUIRED[name]) do
    local value = action[field]
    if type(value) ~= 'string' or value == '' then
      return {
        error = string.format('%s is required for the %s action.', field, name),
      }
    end
  end

  local body, body_err = build_body(action, name)
  if body_err then
    return { error = body_err }
  end

  -- `create` makes a document, so it has no document id to resolve.
  local target = { doc_id = '' }
  if name ~= 'create' then
    target = resolve_doc(action)
    if target.err then
      return { error = target.err }
    end
  end

  local opts = {
    url = build_url(action, name, target.doc_id),
    method = ROUTES[name][1],
    body = body,
    label = 'lark_docx',
    api_name = 'Docx API',
    ctx = ctx,
  }

  if name == 'read' then
    opts.render = function(data)
      local items = data.items
      local markdown = flatten(items, target.doc_id)
      if markdown == '' then
        markdown = '(empty document)'
      end
      if data.has_more then
        markdown = markdown
          .. string.format(
            '\n\n[... document continues; call read again with page_token="%s"]',
            tostring(data.page_token or '')
          )
      end
      return markdown
    end
  elseif name == 'get' then
    opts.render = function(data)
      local doc = data.document or data
      return string.format(
        'title: %s\ndocument_id: %s\nrevision: %s',
        tostring(doc.title or '?'),
        tostring(doc.document_id or target.doc_id),
        tostring(doc.revision_id or '?')
      )
    end
  elseif name == 'append' then
    opts.render = function(data)
      local children = data.children
      return string.format(
        'appended %d block(s) to %s',
        type(children) == 'table' and #children or 0,
        target.doc_id
      )
    end
  elseif name == 'create' then
    opts.render = function(data)
      local doc = data.document or data
      return string.format(
        'created document "%s"\ndocument_id: %s',
        tostring(doc.title or action.title),
        tostring(doc.document_id or '?')
      )
    end
  end

  if target.wiki_node then
    opts.pre = function(token, done)
      lark_url.resolve_wiki(target.wiki_node, token, function(resolved, err)
        if err then
          done(err)
          return
        end
        if resolved.type ~= 'docx' then
          done(string.format(
            'That wiki page holds %s, not a cloud document.',
            lark_url.label(resolved.type)
          ))
          return
        end
        -- The render closures captured `target` by reference, so filling in
        -- the resolved id here is what makes their output correct.
        target.doc_id = resolved.token
        opts.url = build_url(action, name, resolved.token)
        done()
      end)
    end
  end

  return lark_http.request(opts)
end

function M.scheme()
  return {
    type = 'function',
    ['function'] = {
      name = 'lark_docx',
      description = [[
Read and write Feishu/Lark Docs (云文档, docx).

ACTIONS:
- get: document metadata (title, revision) (needs document_id or url)
- read: flatten the document into markdown (needs document_id or url; optional page_token)
- append: add blocks at the end (needs document_id or url, plus blocks or text)
- update_block: replace one block (needs document_id or url, block_id, block)
- delete_block: remove one block and its children (needs document_id or url, block_id)
- create: create an empty document in Drive (needs title, optional folder_token)

APPENDING CONTENT, two ways:
- text (preferred): plain text converted locally into docx blocks.
  "# Title" -> heading1, "## Sub" -> heading2 (up to ######),
  "- item" or "* item" -> bullet, "1. item" -> ordered item,
  any other line -> a plain text block. Blank lines are skipped.
  Example: text="# Report\n\n- finding one\n- finding two\n1. next step"
- blocks (raw): the request body's `children` array is forwarded untouched.
  Required shape: [{"block_type":2,"text":{"elements":[
      {"text_run":{"content":"hello"}}]}}]
  block_type: 1=page, 2=text, 3..11=heading1..heading9, 12=bullet, 13=ordered.
  Every text-ish block wraps its string in elements/text_run, and the payload
  key mirrors the type (text / heading1 / bullet / ordered).

READING: read returns markdown with headings and list markers already
reconstructed from the block tree. Long documents paginate — when the output
ends with "document continues", call read again with that page_token.
Inline styles (bold, links, tables, images) are flattened to their text: use
get on a specific block if you need the raw structure.

WHERE TO FIND TOKENS:
- document_id: the "doxcn..." segment of the doc URL
  (https://xxx.feishu.cn/docx/doxcnXXXX). NOT a wiki node_token.
- block_id: from read output or the doc URL fragment. The document root block
  id equals document_id, which is what append uses by default.
- url: paste the link instead of digging out the token. A /wiki/ link is
  resolved automatically (one extra request), but only when the wiki page
  actually holds a document.

TROUBLESHOOTING:
- 91403 / 1254302: the bot is not a collaborator of the document
- 1254005: missing docx:document scope on the app
- 1770001 / "invalid block": a text block is missing the text_run wrapper
]],
      parameters = {
        type = 'object',
        properties = {
          action = {
            type = 'string',
            enum = {
              'get',
              'read',
              'append',
              'update_block',
              'delete_block',
              'create',
            },
            description = 'Action to perform (default: "read")',
          },
          url = {
            type = 'string',
            description = 'Document link (https://xxx.feishu.cn/docx/doxcn...) or a wiki link holding one; alternative to document_id',
          },
          document_id = {
            type = 'string',
            description = 'Document id, the "doxcn..." segment of the doc URL (required unless url is given)',
          },
          block_id = {
            type = 'string',
            description = 'Block id for update_block/delete_block; for append it selects the parent block (default: the document root)',
          },
          text = {
            type = 'string',
            description = 'Plain text to append, converted to blocks locally ("# heading", "- bullet", "1. ordered")',
          },
          blocks = {
            type = 'array',
            items = { type = 'object' },
            description = 'Raw docx block objects to append, e.g. [{ block_type = 2, text = { elements = [{ text_run = { content = "hi" } }] } }]',
          },
          block = {
            type = 'object',
            description = 'Replacement block object for update_block',
          },
          index = {
            type = 'integer',
            description = 'Insertion position among the parent block children (default: 0 = append at the end)',
          },
          page_size = {
            type = 'integer',
            description = 'Blocks per page for read, maximum 500 (optional)',
          },
          page_token = {
            type = 'string',
            description = 'Pagination cursor from a previous read (optional)',
          },
          title = {
            type = 'string',
            description = 'Title of the document to create (required for create)',
          },
          folder_token = {
            type = 'string',
            description = 'Folder token to create the document in (optional for create; defaults to the app root)',
          },
        },
        required = {},
      },
    },
  }
end

function M.info(action, _)
  local arguments = action
  if type(action) == 'string' then
    local ok, decoded = pcall(vim.json.decode, action)
    if not ok then
      return 'lark_docx'
    end
    arguments = decoded
  end
  arguments = arguments or {}

  local parts = { 'lark_docx', arguments.action or 'read' }
  if arguments.document_id then
    parts[#parts + 1] = 'doc=' .. arguments.document_id
  elseif arguments.url then
    parts[#parts + 1] = 'url=' .. arguments.url
  end
  if arguments.block_id then
    parts[#parts + 1] = 'block=' .. arguments.block_id
  end
  if arguments.title then
    parts[#parts + 1] = 'title=' .. arguments.title
  end
  return table.concat(parts, ' ')
end

-- Internal exports for tests.
M._ROUTES = ROUTES
M._flatten = flatten
M._text_to_blocks = text_to_blocks

return M

