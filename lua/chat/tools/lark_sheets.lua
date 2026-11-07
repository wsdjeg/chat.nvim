-- lua/chat/tools/lark_sheets.lua
-- Feishu/Lark Sheets (电子表格) read/write API.
--
-- One tool with an `action` enum, following bitable.lua: the Sheets endpoints
-- are shaped uniformly (spreadsheets/{token}/values...), so a single schema
-- keeps the tool list small and lets the model pick the action from context.
-- `enum` is used instead of oneOf because many models handle oneOf poorly
-- (see get_weather.lua for the same note).
--
-- Two API versions are in play, which is not a mistake:
--   * v3 for metadata and spreadsheet creation (sheets/query, spreadsheets)
--   * v2 for cell values (values, values_append, values_batch_update)
-- The v3 values endpoints are still settling, while v2 is the documented,
-- stable one for reading and writing ranges.
--
-- Prerequisites (worth mentioning to the user when calls fail):
--   * the app needs the `sheets:spreadsheet` scope
--   * the bot must be added as a collaborator of the spreadsheet, otherwise
--     the API answers 91403/1254302
--   * `spreadsheet_token` is the `shtcn...` segment of the sheet URL, not a
--     wiki `node_token` (a `/wiki/` link is resolved automatically through
--     integrations/lark/url.lua when passed as `url`)
local M = {}

local lark_http = require('chat.integrations.lark.http')
local lark_url = require('chat.integrations.lark.url')

local OPEN_API = 'https://open.feishu.cn/open-apis'

--- action -> { method, path template }
--- `%s` placeholders are filled from spreadsheet_token then range, whichever
--- the action uses.
local ROUTES = {
  list_sheets = { 'GET', '/sheets/v3/spreadsheets/%s/sheets/query' },
  read = { 'GET', '/sheets/v2/spreadsheets/%s/values/%s' },
  write = { 'PUT', '/sheets/v2/spreadsheets/%s/values' },
  append = { 'POST', '/sheets/v2/spreadsheets/%s/values_append' },
  batch_update = { 'POST', '/sheets/v2/spreadsheets/%s/values_batch_update' },
  create = { 'POST', '/sheets/v3/spreadsheets' },
}

--- Required parameters per action (besides `action` itself).
--- `spreadsheet_token` may be supplied through `url` instead, which is why it
--- is not listed literally: the check happens after URL resolution.
local REQUIRED = {
  list_sheets = {},
  read = { 'range' },
  write = { 'range' },
  append = { 'range' },
  batch_update = {},
  create = { 'title' },
}

--- Actions that take a range and a 2-D array of values.
local VALUE_ACTIONS = {
  read = true,
  write = true,
  append = true,
}

--- Render a cell value as plain text.
--- Sheets may return numbers, booleans, strings, or rich text segments.
--- @param cell any
--- @return string
local function cell_text(cell)
  if cell == nil or cell == vim.NIL then
    return ''
  end
  if type(cell) == 'string' then
    return cell
  end
  if type(cell) == 'number' or type(cell) == 'boolean' then
    return tostring(cell)
  end
  if type(cell) == 'table' then
    -- Rich text: { type = "text", text = "..." } or { text = "..." }
    if type(cell.text) == 'string' then
      return cell.text
    end
    if type(cell.link) == 'string' then
      return cell.link
    end
  end
  return ''
end

--- Normalize the rows of a values response into a plain 2-D array.
--- @param data table Response `data` for a read action
--- @return table rows
local function value_rows(data)
  local vr = data.valueRange or data.value_range
  if type(vr) ~= 'table' then
    -- Some endpoints return { values = ... } at the top level.
    vr = data
  end
  local rows = vr.values
  if type(rows) ~= 'table' then
    return {}
  end
  return rows
end

--- Render a 2-D array as a markdown table.
--- A table of text is far easier for the model to reason about than the raw
--- nested JSON, and the column letters are what write/append ranges need.
--- @param rows table 2-D array of cell values
--- @param range? string Source range, echoed as a caption
--- @return string
local function to_markdown(rows, range)
  if type(rows) ~= 'table' or #rows == 0 then
    return '(empty range' .. (range and (': ' .. range) or '') .. ')'
  end

  -- Widest row decides the column count: trailing empty cells are omitted
  -- by the API, which would otherwise cut the table short.
  local columns = 0
  for _, row in ipairs(rows) do
    if type(row) == 'table' and #row > columns then
      columns = #row
    end
  end
  if columns == 0 then
    return '(empty range' .. (range and (': ' .. range) or '') .. ')'
  end

  local function render_row(row)
    local cells = {}
    for i = 1, columns do
      local text = cell_text(row and row[i])
      cells[i] = text:gsub('|', '\\|'):gsub('\n', ' ')
    end
    return '| ' .. table.concat(cells, ' | ') .. ' |'
  end

  local out = {}
  -- The first row is the header: it is what a spreadsheet range usually
  -- holds, and markdown tables need one.
  out[#out + 1] = render_row(rows[1])
  local separator = {}
  for i = 1, columns do
    separator[i] = '---'
  end
  out[#out + 1] = '| ' .. table.concat(separator, ' | ') .. ' |'
  for i = 2, #rows do
    out[#out + 1] = render_row(rows[i])
  end

  local caption = string.format(
    '(%d row(s) x %d column(s)%s)',
    #rows,
    columns,
    range and (', range ' .. range) or ''
  )
  out[#out + 1] = ''
  out[#out + 1] = caption
  return table.concat(out, '\n')
end

--- Validate that `values` is a non-empty 2-D array.
--- @param values any
--- @return string|nil err
local function check_values(values)
  if type(values) ~= 'table' or #values == 0 then
    return 'values must be a non-empty 2-D array '
      .. '(rows of cells, e.g. [["Name","Age"],["Ann",3]])'
  end
  for i, row in ipairs(values) do
    if type(row) ~= 'table' then
      return string.format(
        'values[%d] must be an array of cells, got: %s',
        i,
        type(row)
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

  if name == 'write' or name == 'append' then
    local err = check_values(action.values)
    if err then
      return nil, err
    end
    return { valueRange = { range = action.range, values = action.values } }
  end

  if name == 'batch_update' then
    local ranges = action.value_ranges
    if type(ranges) ~= 'table' or #ranges == 0 then
      return nil, 'value_ranges must be a non-empty array of '
        .. '{ range = "Sheet1!A1:B2", values = [[...]] } objects.'
    end
    local out = {}
    for i, entry in ipairs(ranges) do
      if type(entry) ~= 'table' then
        return nil, string.format('value_ranges[%d] must be an object.', i)
      end
      if type(entry.range) ~= 'string' or entry.range == '' then
        return nil, string.format('value_ranges[%d].range is required.', i)
      end
      local err = check_values(entry.values)
      if err then
        return nil, string.format('value_ranges[%d]: %s', i, err)
      end
      out[i] = { range = entry.range, values = entry.values }
    end
    return { valueRanges = out }
  end

  return nil
end

--- Compose the request URL.
--- Percent-encode a range for use inside a URL path.
--- Sheet names are free-form (spaces, CJK, "&"), so the range cannot be
--- interpolated raw: "My Sheet!A1:B2" would break the request line.
--- @param range string
--- @return string
local function encode_range(range)
  return (
    tostring(range):gsub('[^%w%-%._~!:$]', function(ch)
      return string.format('%%%02X', ch:byte())
    end)
  )
end

--- @param action table Tool arguments
--- @param name string Action name
--- @param token string Spreadsheet token resolved earlier
--- @return string url
local function build_url(action, name, token)
  local route = ROUTES[name]
  local path
  if name == 'read' then
    path = string.format(route[2], token, encode_range(action.range))
  elseif name == 'create' then
    path = route[2]
  else
    path = string.format(route[2], token)
  end
  return OPEN_API .. path
end

---@class ChatToolsLarkSheetsAction
---@field action? string One of the ROUTES keys (default: "list_sheets")
---@field url? string Spreadsheet link (or bare token); alternative to spreadsheet_token
---@field spreadsheet_token? string Spreadsheet token (shtcn...)
---@field range? string Range like "Sheet1!A1:D10" or "<sheet_id>!A1:D10"
---@field values? table 2-D array of cell values
---@field value_ranges? table[] Array of { range, values } for batch_update
---@field title? string Title for the create action
---@field folder_token? string Folder for the create action (optional)

--- Resolve the spreadsheet token for an action.
--- Accepts `spreadsheet_token`, or a `url` pointing at a sheet (or at a wiki
--- node containing one). A wiki link needs a request to resolve, so it is
--- reported separately as `wiki_node`.
--- @param action table Tool arguments
--- @return table result { token = string|nil, wiki_node = string|nil, err = string|nil }
local function resolve_token(action)
  local token = action.spreadsheet_token
  if type(token) == 'string' and token ~= '' then
    return { token = token }
  end

  if type(action.url) ~= 'string' or action.url == '' then
    return {
      err = 'spreadsheet_token (or url) is required. It is the "shtcn..." '
        .. 'segment of the sheet link.',
    }
  end

  local parsed = lark_url.parse(action.url)
  if not parsed then
    return {
      err = 'Could not recognise a Feishu/Lark link in url. Expected a '
        .. 'https://xxx.feishu.cn/sheets/shtcn... link (or a /wiki/ link '
        .. 'pointing at a sheet).',
    }
  end

  if parsed.type == 'sheets' then
    return { token = parsed.token }
  end

  if parsed.type == 'wiki' then
    return { wiki_node = parsed.token }
  end

  return {
    err = string.format(
      'url points at %s, not a spreadsheet.',
      lark_url.label(parsed.type)
    ),
  }
end

--- @param action ChatToolsLarkSheetsAction
--- @param ctx ChatToolContext
function M.lark_sheets(action, ctx)
  action = action or {}
  local name = action.action or 'list_sheets'

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

  -- `create` has no spreadsheet token yet: it makes one.
  local target = { token = '' }
  if name ~= 'create' then
    target = resolve_token(action)
    if target.err then
      return { error = target.err }
    end
  end

  local opts = {
    url = build_url(action, name, target.token),
    method = ROUTES[name][1],
    body = body,
    label = 'lark_sheets',
    api_name = 'Sheets API',
    ctx = ctx,
  }

  if name == 'read' then
    opts.render = function(data)
      return to_markdown(value_rows(data), action.range)
    end
  elseif name == 'list_sheets' then
    opts.render = function(data)
      local sheets = data.sheets
      if type(sheets) ~= 'table' or #sheets == 0 then
        return 'No sheets found.'
      end
      local out = {}
      for _, sheet in ipairs(sheets) do
        out[#out + 1] = string.format(
          '- %s (sheet_id: %s, %s row(s) x %s column(s))',
          sheet.title or 'untitled',
          sheet.sheet_id or '?',
          tostring(sheet.grid_properties and sheet.grid_properties.row_count or '?'),
          tostring(sheet.grid_properties and sheet.grid_properties.column_count or '?')
        )
      end
      return table.concat(out, '\n')
    end
  end

  -- A wiki link has to be exchanged for the real obj_token first: the call
  -- always goes down the synthetic-handle path in that case.
  if target.wiki_node then
    opts.pre = function(token, done)
      lark_url.resolve_wiki(target.wiki_node, token, function(resolved, err)
        if err then
          done(err)
          return
        end
        if resolved.type ~= 'sheets' then
          done(string.format(
            'That wiki page holds %s, not a spreadsheet.',
            lark_url.label(resolved.type)
          ))
          return
        end
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
      name = 'lark_sheets',
      -- [=[ ... ]=] rather than [[ ... ]]: the description itself contains
      -- "]]" in the example values array, which would close a level-1 string.
      description = [=[
Read and write Feishu/Lark Sheets (电子表格) cell values.

RANGES are "Sheet1!A1:D10" style: sheet name or sheet_id, then an A1 range.
- Use list_sheets first to learn the sheet titles and sheet_ids.
- Ranges are inclusive; "A1:A1" is a single cell.
- Prefer the sheet_id form (e.g. "0b1c2d!A1:D10") when sheet names contain
  spaces or get renamed.

ACTIONS:
- list_sheets: list the sheets of a spreadsheet (needs spreadsheet_token or url)
- read: read a range (needs spreadsheet_token or url, range)
- write: overwrite a range (needs spreadsheet_token or url, range, values)
- append: append rows after the last used row (needs token or url, range, values)
- batch_update: write several ranges in one request (needs token or url, value_ranges)
- create: create an empty spreadsheet in Drive (needs title, optional folder_token)

VALUES are a 2-D array of rows: [["Name","Age"],["Ann",3]].
- Numbers, booleans, and strings are accepted as-is.
- Formulas start with "=" and are evaluated by the spreadsheet.
- Formatted cells (dates, currencies) read back as their displayed text.

WHERE TO FIND TOKENS:
- spreadsheet_token: the "shtcn..." segment of the sheet URL
  (https://xxx.feishu.cn/sheets/shtcnXXXX). NOT a sheet_id and NOT a wiki
  node_token.
- url: paste the link instead of digging out the token. A /wiki/ link is
  resolved automatically (it costs one extra request), but only when the wiki
  page actually holds a spreadsheet.

TROUBLESHOOTING:
- 91403 / 1254302: the bot is not a collaborator of the spreadsheet
- 1254005: missing sheets:spreadsheet scope on the app
- 90215 / "range is invalid": the sheet name in the range is wrong; call
  list_sheets and use the exact title or the sheet_id
]=],
      parameters = {
        type = 'object',
        properties = {
          action = {
            type = 'string',
            enum = {
              'list_sheets',
              'read',
              'write',
              'append',
              'batch_update',
              'create',
            },
            description = 'Action to perform (default: "list_sheets")',
          },
          url = {
            type = 'string',
            description = 'Spreadsheet link (https://xxx.feishu.cn/sheets/shtcn...) or a wiki link holding one; alternative to spreadsheet_token',
          },
          spreadsheet_token = {
            type = 'string',
            description = 'Spreadsheet token, the "shtcn..." segment of the sheet URL (required unless url is given)',
          },
          range = {
            type = 'string',
            description = 'A1 range like "Sheet1!A1:D10" (required for read/write/append)',
          },
          values = {
            type = 'array',
            items = { type = 'array', items = {} },
            description = '2-D array of rows for write/append, e.g. [["Name","Age"],["Ann",3]]',
          },
          value_ranges = {
            type = 'array',
            items = { type = 'object' },
            description = 'Array of { range = "Sheet1!A1:B2", values = [[...]] } objects for batch_update',
          },
          title = {
            type = 'string',
            description = 'Title of the spreadsheet to create (required for create)',
          },
          folder_token = {
            type = 'string',
            description = 'Folder token to create the spreadsheet in (optional for create; defaults to the app root)',
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
      return 'lark_sheets'
    end
    arguments = decoded
  end
  arguments = arguments or {}

  local parts = { 'lark_sheets', arguments.action or 'list_sheets' }
  if arguments.spreadsheet_token then
    parts[#parts + 1] = 'sheet=' .. arguments.spreadsheet_token
  elseif arguments.url then
    parts[#parts + 1] = 'url=' .. arguments.url
  end
  if arguments.range then
    parts[#parts + 1] = 'range=' .. arguments.range
  end
  if arguments.title then
    parts[#parts + 1] = 'title=' .. arguments.title
  end
  return table.concat(parts, ' ')
end

-- Internal exports for tests.
M._ROUTES = ROUTES
M._to_markdown = to_markdown
M._value_rows = value_rows

return M

