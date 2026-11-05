-- lua/chat/tools/bitable.lua
-- Feishu/Lark Bitable (多维表格) records and fields API.
--
-- One tool with an `action` enum instead of eleven tools: the Bitable API is
-- shaped uniformly (apps/{app_token}/tables/{table_id}/records|fields/...), so
-- a single schema keeps the tool list small and lets the model pick the
-- action from context. `enum` on `action` is used instead of oneOf, because
-- many models handle oneOf poorly (see get_weather.lua for the same note).
--
-- Prerequisites (worth mentioning to the user when calls fail):
--   * the app needs the `bitable:app` scope
--   * the bot must be added as a collaborator of the Bitable (or of the
--     containing knowledge space), otherwise the API answers 91403/1254302
--   * `app_token` is the `bascn...` segment of the base URL, not `table_id`
--     (`tbl...`) and not a wiki `node_token`
--   * there is no discovery action: the Bitable API has no list-apps endpoint,
--     and the drive / wiki traversal actions (`list_files`, `list_spaces`)
--     are not implemented. `app_token` has to come from the caller.
local M = {}

local curl = require('chat.curl')
local job = require('job')
local auth = require('chat.lark.auth')

local API_BASE = 'https://open.feishu.cn/open-apis/bitable/v1/apps'

-- Handles handed to the session for requests that first need a token.
-- Negative ids mirror how MCP tools report asynchronous work: the session
-- framework accepts either a `jobid` or an `mcp_tool_call_id` as the async
-- handle, and `cancel_progress` treats negative ids as non-job handles.
-- Starting well below MCP's own counter (-1, -2, ...) keeps the two spaces
-- disjoint without sharing an allocator.
local HANDLE_BASE = -1000000
local next_handle = HANDLE_BASE
local pending_handles = {}

--- action -> { method, path template, needs body }
--- The third `%s` is filled from `field_id` or `record_id`, whichever the
--- action uses; templates with two placeholders ignore the extra argument.
local ROUTES = {
  list_tables = { 'GET', '/%s/tables' },
  list_fields = { 'GET', '/%s/tables/%s/fields' },
  create_field = { 'POST', '/%s/tables/%s/fields' },
  update_field = { 'PUT', '/%s/tables/%s/fields/%s' },
  delete_field = { 'DELETE', '/%s/tables/%s/fields/%s' },
  search = { 'POST', '/%s/tables/%s/records/search' },
  get = { 'GET', '/%s/tables/%s/records/%s' },
  create = { 'POST', '/%s/tables/%s/records' },
  update = { 'PUT', '/%s/tables/%s/records/%s' },
  delete = { 'DELETE', '/%s/tables/%s/records/%s' },
  batch_create = { 'POST', '/%s/tables/%s/records/batch_create' },
  batch_update = { 'POST', '/%s/tables/%s/records/batch_update' },
}

--- Required parameters per action (besides `action` itself).
local REQUIRED = {
  list_tables = { 'app_token' },
  list_fields = { 'app_token', 'table_id' },
  create_field = { 'app_token', 'table_id' },
  update_field = { 'app_token', 'table_id', 'field_id' },
  delete_field = { 'app_token', 'table_id', 'field_id' },
  search = { 'app_token', 'table_id' },
  get = { 'app_token', 'table_id', 'record_id' },
  create = { 'app_token', 'table_id' },
  update = { 'app_token', 'table_id', 'record_id' },
  delete = { 'app_token', 'table_id', 'record_id' },
  batch_create = { 'app_token', 'table_id' },
  batch_update = { 'app_token', 'table_id' },
}

--- Actions that read from `fields` (single record) or `records` (batch).
local WRITE_ACTIONS = {
  create = 'fields',
  update = 'fields',
  batch_create = 'records',
  batch_update = 'records',
}

--- Actions whose body is a single field definition object.
local FIELD_ACTIONS = {
  create_field = true,
  update_field = true,
}

--- Build the request body for an action; nil when the action has none.
--- @param action table Tool arguments
--- @param name string Action name
--- @return table|nil body
--- @return string|nil err
local function build_body(action, name)
  if name == 'search' then
    -- Raw search body (filters, sort, field_names, ...). Defaults to an
    -- empty object so `search` without a body lists every record.
    local body = action.body
    if body == nil or body == vim.NIL then
      return {}
    end
    if type(body) ~= 'table' then
      return nil, 'body must be an object for the search action.'
    end
    return body
  end

  if FIELD_ACTIONS[name] then
    -- The field endpoints take the definition at the top level
    -- ({ field_name, type, property }), not wrapped in a `fields` key.
    local field = action.field
    if field == nil or field == vim.NIL then
      return nil, 'field is required for the ' .. name .. ' action.'
    end
    if type(field) ~= 'table' or next(field) == nil then
      return nil, 'field must be a non-empty object '
        .. '({ field_name = "...", type = <int>, property = {...} }).'
    end
    if name == 'create_field' then
      if type(field.field_name) ~= 'string' or field.field_name == '' then
        return nil, 'field.field_name is required for the create_field action.'
      end
      if type(field.type) ~= 'number' then
        return nil, 'field.type is required for the create_field action '
          .. '(integer field type, see list_fields output).'
      end
    end
    return field
  end

  local key = WRITE_ACTIONS[name]
  if not key then
    return nil
  end

  if key == 'fields' then
    local fields = action.fields
    if fields == nil or fields == vim.NIL then
      return nil, 'fields is required for the ' .. name .. ' action.'
    end
    if type(fields) ~= 'table' then
      return nil, 'fields must be an object mapping field name/id to value.'
    end
    return { fields = fields }
  end

  local records = action.records
  if records == nil or records == vim.NIL then
    return nil, 'records is required for the ' .. name .. ' action.'
  end
  if type(records) ~= 'table' or #records == 0 then
    return nil, 'records must be a non-empty array of { fields = {...} } objects.'
  end
  return { records = records }
end

--- Compose the endpoint URL for an action.
--- @param action table Tool arguments
--- @param name string Action name
--- @return string url
local function build_url(action, name)
  local route = ROUTES[name]
  local path = string.format(
    route[2],
    action.app_token,
    action.table_id or '',
    action.field_id or action.record_id or ''
  )

  local query = {}
  if action.page_token and action.page_token ~= '' then
    query[#query + 1] = 'page_token=' .. action.page_token
  end
  if action.page_size then
    query[#query + 1] = 'page_size=' .. tostring(action.page_size)
  end

  local url = API_BASE .. path
  if #query > 0 then
    url = url .. '?' .. table.concat(query, '&')
  end
  return url
end

--- Turn a Bitable response into a tool result.
--- @param ctx ChatToolContext
--- @param handle table handle fields to echo back (jobid or mcp_tool_call_id)
--- @param url string Requested URL
--- @param code integer Process exit code
--- @param signal integer Process exit signal
--- @param stdout string[]
--- @param stderr string[]
local function deliver(ctx, handle, url, code, signal, stdout, stderr)
  if signal ~= 0 then
    ctx.callback(vim.tbl_extend('force', handle, {
      error = string.format('bitable cancelled by user (signal: %d)', signal),
    }))
    return
  end

  local raw = table.concat(stdout, '\n')
  local error_output = table.concat(stderr, '\n')

  if code ~= 0 then
    local detail = error_output ~= '' and error_output or raw
    local msg = string.format(
      'Failed to call Bitable API (exit code: %d).\nURL: %s\n\nError output: %s',
      code,
      url,
      detail ~= '' and detail or '(no output)'
    )
    local hint = curl.get_error_message(code)
    if hint then
      msg = msg .. '\n\nTroubleshooting: ' .. hint
    end
    ctx.callback(vim.tbl_extend('force', handle, { error = msg }))
    return
  end

  local ok, res = pcall(vim.json.decode, raw)
  if not ok or type(res) ~= 'table' then
    ctx.callback(vim.tbl_extend('force', handle, {
      error = 'Invalid JSON from Bitable API: ' .. raw:sub(1, 500),
    }))
    return
  end

  if res.code and res.code ~= 0 then
    local log_id = res.error and res.error.log_id or '-'
    ctx.callback(vim.tbl_extend('force', handle, {
      error = string.format(
        'Feishu API error %s: %s (log_id: %s)',
        tostring(res.code),
        res.msg or 'unknown',
        log_id
      ),
    }))
    return
  end

  ctx.callback(vim.tbl_extend('force', handle, {
    content = vim.json.encode(res.data ~= nil and res.data or res),
  }))
end

--- Start the Bitable request for an already authenticated token.
--- @param action table Tool arguments
--- @param name string Action name
--- @param body table|nil Request body
--- @param token string tenant_access_token
--- @param ctx ChatToolContext
--- @param handle table handle fields to echo back
--- @return integer|nil jobid
local function start_request(action, name, body, token, ctx, handle)
  local url = build_url(action, name)
  local method = ROUTES[name][1]

  local cmd = curl.build_request({
    url = url,
    method = method,
    headers = {
      'Authorization: Bearer ' .. token,
      'Content-Type: application/json',
    },
    -- Body travels over stdin so record values never get embedded in the
    -- command line (argv is visible to other processes via ps).
    stdin_body = body ~= nil,
  })

  local stdout = {}
  local stderr = {}

  local jobid = job.start(cmd, {
    on_stdout = function(_, data)
      vim.list_extend(stdout, data)
    end,
    on_stderr = function(_, data)
      vim.list_extend(stderr, data)
    end,
    on_exit = function(_, code, signal)
      deliver(ctx, handle, url, code, signal, stdout, stderr)
    end,
  })

  if not jobid or jobid <= 0 then
    return nil, url
  end

  if body ~= nil then
    job.send(jobid, vim.json.encode(body))
    job.send(jobid, nil)
  end

  return jobid
end

---@class ChatToolsBitableAction
---@field action? string One of the ROUTES keys (default: "list_tables")
---@field app_token string Bitable app token (bascn...)
---@field table_id? string Table id (tbl...)
---@field record_id? string Record id (rec...)
---@field field_id? string Field id (fld...)
---@field field? table Field definition { field_name, type, property }
---@field fields? table Record fields, keyed by field name or field id
---@field records? table[] Array of { fields = {...} } for batch actions
---@field body? table Raw search request body
---@field page_size? integer Page size (max 500)
---@field page_token? string Pagination cursor

---@param action ChatToolsBitableAction
---@param ctx ChatToolContext
function M.bitable(action, ctx)
  action = action or {}
  local name = action.action or 'list_tables'

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

  if not curl.is_available() then
    return {
      error = 'curl is not installed or not in PATH. Please install curl first.',
    }
  end

  -- Fast path: the token is cached, so the request can start right away and
  -- the caller gets a real jobid (cancel kills the actual curl process).
  local token = auth.cached_token()
  if token then
    -- The exit callback captures this table by reference, so assigning
    -- `handle.jobid` after job.start() is visible when the callback fires.
    local handle = {}
    local jobid, url = start_request(action, name, body, token, ctx, handle)
    if not jobid then
      return {
        error = 'Failed to start curl process for '
          .. (url or 'the Bitable request')
          .. '. Please verify curl is installed and executable.',
      }
    end
    handle.jobid = jobid
    return { jobid = jobid }
  end

  -- Cold token: the token request is asynchronous, but the session needs a
  -- handle synchronously. Report a negative handle (same contract as MCP)
  -- and start the real request as soon as the token arrives.
  next_handle = next_handle - 1
  local handle_id = next_handle
  pending_handles[handle_id] = true

  -- cancel_progress invokes this when the user cancels while the token
  -- request is still in flight. Clearing the flag makes the token callback
  -- abort: firing the request anyway would silently write to (or delete
  -- from) the user's table after they cancelled.
  local async = require('chat.sessions.async')
  async.register_cancel_handler(handle_id, function()
    if not pending_handles[handle_id] then
      return false
    end
    pending_handles[handle_id] = nil
    return true
  end)

  local handle = { mcp_tool_call_id = handle_id }

  auth.fetch_token(function(new_token, err)
    local alive = pending_handles[handle_id]
    pending_handles[handle_id] = nil
    async.unregister_cancel_handler(handle_id)
    if not alive then
      -- Cancelled while waiting for the token: drop the result silently.
      return
    end
    if not new_token then
      ctx.callback(vim.tbl_extend('force', handle, {
        error = err or 'failed to obtain tenant_access_token',
      }))
      return
    end

    local jobid, url = start_request(action, name, body, new_token, ctx, handle)
    if not jobid then
      ctx.callback(vim.tbl_extend('force', handle, {
        error = 'Failed to start curl process for '
          .. (url or 'the Bitable request')
          .. '. Please verify curl is installed and executable.',
      }))
    end
  end)

  return handle
end

function M.scheme()
  return {
    type = 'function',
    ['function'] = {
      name = 'bitable',
      description = [[
Read and write Feishu/Lark Bitable (多维表格) records and fields.

ENDPOINT SHAPE: apps/{app_token}/tables/{table_id}/records|fields

ACTIONS:
- list_tables: list the tables of a Bitable (needs app_token)
- list_fields: list the fields of a table (needs app_token, table_id)
- create_field: add a field, i.e. a column/header (needs app_token, table_id, field)
- update_field: rename or retype a field (needs app_token, table_id, field_id, field)
- delete_field: remove a field and all its data (needs app_token, table_id, field_id)
- search: query records (needs app_token, table_id; optional body)
- get: read one record (needs app_token, table_id, record_id)
- create: add one record (needs app_token, table_id, fields)
- update: modify one record (needs app_token, table_id, record_id, fields)
- delete: remove one record (needs app_token, table_id, record_id)
- batch_create: add many records (needs app_token, table_id, records)
- batch_update: modify many records (needs app_token, table_id, records)

DISCOVERY: this tool cannot enumerate Bitables. There is no list-apps endpoint
in the Bitable API, and the drive/wiki traversal actions (list_files,
list_spaces) are NOT implemented. app_token must be supplied by the caller —
never invent one. If the caller has not given a `bascn...` token, ask for the
base URL instead of guessing.

WHERE TO FIND IDS:
- app_token: the `bascn...` segment of the base URL
  (https://xxx.feishu.cn/base/bascnXXXX). NOT table_id, NOT a wiki node_token.
  A wiki URL (`/wiki/wikcnXXXX`) carries a node_token, which does not work
  here: ask the user for the `bascn...` link (More -> Copy link) instead.
- table_id: the `tbl...` segment, from list_tables or the table URL.
- record_id: the `rec...` id, from search or get.
- field_id: the `fld...` id, from list_fields (field_name works only for
  record values, not for update_field/delete_field).

FIELD DEFINITION (`field`, used by create_field/update_field):
  {"field_name":"状态","type":3,"property":{"options":[{"name":"Todo"}]}}
- type is the integer field type; take it from list_fields of a similar table
  (1=text, 2=number, 3=single select, 4=multi select, 5=datetime, 7=checkbox,
  11=person, 15=url, 17=attachment, 18=link to another table, 1001=created
  time, ...). Creating a link field also needs property.table_id.
- Feishu requires BOTH field_name and type when updating a field: to rename
  only, first call list_fields and echo the existing type back.
- Changing the type of a populated field can fail or discard values; the API
  refuses some conversions outright.

FIELD VALUES (strictly typed — a wrong type silently drops the record):
- text: "abc" or [{"type":"text","text":"abc"}]
- number: 3
- date/datetime: milliseconds timestamp (NOT seconds)
- person: [{"id":"ou_xxx"}]
- multi-select: ["a","b"]; single select: "a"
- link to another table: [{"record_ids":["rec_xxx"]}]
Prefer field ids over names when fields were renamed; list_fields returns both.

SEARCH BODY: raw request body, e.g.
  {"filter":{"conjunction":"and","conditions":[
     {"field_name":"Status","operator":"is","value":["Done"]}]},
   "sort":[{"field_name":"Created","desc":true}],
   "field_names":["Name","Status"]}
Omit body to list records. page_size max 500 — loop with page_token for
bigger tables.

TROUBLESHOOTING:
- 91403 / 1254302: the bot is not a collaborator of the Bitable
- 1254005: missing bitable:app scope on the app
]],
      parameters = {
        type = 'object',
        properties = {
          action = {
            type = 'string',
            enum = {
              'list_tables',
              'list_fields',
              'create_field',
              'update_field',
              'delete_field',
              'search',
              'get',
              'create',
              'update',
              'delete',
              'batch_create',
              'batch_update',
            },
            description = 'Action to perform (default: "list_tables")',
          },
          app_token = {
            type = 'string',
            description = 'Bitable app token, the "bascn..." segment of the base URL (required for every action)',
          },
          table_id = {
            type = 'string',
            description = 'Table id ("tbl..."), required for every action except list_tables',
          },
          record_id = {
            type = 'string',
            description = 'Record id ("rec..."), required for get/update/delete',
          },
          field_id = {
            type = 'string',
            description = 'Field id ("fld..."), required for update_field/delete_field; get it from list_fields',
          },
          field = {
            type = 'object',
            description = 'Field definition { field_name, type, property } (required for create_field/update_field)',
          },
          fields = {
            type = 'object',
            description = 'Record fields keyed by field name or field id (required for create/update)',
          },
          records = {
            type = 'array',
            items = { type = 'object' },
            description = 'Array of { fields = {...} } objects (required for batch_create/batch_update)',
          },
          body = {
            type = 'object',
            description = 'Raw search request body: filter/sort/field_names (optional for search)',
          },
          page_size = {
            type = 'integer',
            description = 'Page size, maximum 500 (optional)',
          },
          page_token = {
            type = 'string',
            description = 'Pagination cursor from a previous page (optional)',
          },
        },
        required = { 'app_token' },
      },
    },
  }
end

function M.info(action, _)
  local arguments = action
  if type(action) == 'string' then
    local ok, decoded = pcall(vim.json.decode, action)
    if not ok then
      return 'bitable'
    end
    arguments = decoded
  end
  arguments = arguments or {}

  local parts = { 'bitable', arguments.action or 'list_tables' }
  if arguments.app_token then
    parts[#parts + 1] = 'app=' .. arguments.app_token
  end
  if arguments.table_id then
    parts[#parts + 1] = 'table=' .. arguments.table_id
  end
  if arguments.record_id then
    parts[#parts + 1] = 'record=' .. arguments.record_id
  end
  if arguments.field_id then
    parts[#parts + 1] = 'field=' .. arguments.field_id
  end
  return table.concat(parts, ' ')
end

-- Internal export for tests.
M._ROUTES = ROUTES

return M

