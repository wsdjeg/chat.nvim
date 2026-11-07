-- lua/chat/lark/http.lua
-- Shared request runner for the Lark/Feishu Open API tools (sheets, docx).
--
-- Three concerns are identical for every token-gated Lark tool:
--
--   1. the tenant_access_token may be cached, so the request can start at
--      once and the caller gets a real jobid; or it may be cold, in which
--      case the token request is asynchronous and the tool has to hand the
--      session a synthetic negative handle plus a cancel handler.
--   2. the JSON body travels over stdin, so record/document values never end
--      up in argv (visible to other processes via ps).
--   3. the { code, msg, error.log_id, data } envelope must be mapped onto the
--      same tool result shape.
--
-- bitable.lua predates this module and keeps its own handle range
-- (-1000000..); handles allocated here start at -2000000, so the two tools
-- can never hand the same id to the session (the session keys cancel
-- handlers by id).
local M = {}

local curl = require('chat.curl')
local job = require('job')
local auth = require('chat.lark.auth')

local HANDLE_BASE = -2000000
local next_handle = HANDLE_BASE
local pending_handles = {}

local CURL_ERROR = 'curl is not installed or not in PATH. Please install curl first.'

---@param url string
---@return string
local function start_error(url)
  return 'Failed to start curl process for '
    .. url
    .. '. Please verify curl is installed and executable.'
end

--- Map a finished request onto a tool callback result.
---@param opts ChatLarkHttpRequest
---@param handle table Handle fields echoed back to the session
---@param code integer Process exit code
---@param signal integer Process exit signal
---@param stdout string[]
---@param stderr string[]
local function deliver(opts, handle, code, signal, stdout, stderr)
  local ctx = opts.ctx
  local api_name = opts.api_name or 'Feishu API'

  if signal ~= 0 then
    ctx.callback(vim.tbl_extend('force', handle, {
      error = string.format(
        '%s cancelled by user (signal: %d)',
        opts.label or 'request',
        signal
      ),
    }))
    return
  end

  local raw = table.concat(stdout, '\n')
  local error_output = table.concat(stderr, '\n')

  if code ~= 0 then
    local detail = error_output ~= '' and error_output or raw
    local msg = string.format(
      'Failed to call %s (exit code: %d).\nURL: %s\n\nError output: %s',
      api_name,
      code,
      opts.url,
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
      error = 'Invalid JSON from ' .. api_name .. ': ' .. raw:sub(1, 500),
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

  local data = res.data ~= nil and res.data or res
  local content
  if opts.render then
    local ok_r, rendered = pcall(opts.render, data, res)
    if ok_r and type(rendered) == 'string' then
      content = rendered
    else
      content = vim.json.encode(data)
    end
  else
    content = vim.json.encode(data)
  end

  ctx.callback(vim.tbl_extend('force', handle, { content = content }))
end

--- Start the curl job for an authenticated token.
---@param opts ChatLarkHttpRequest
---@param token string tenant_access_token
---@param handle table Handle fields echoed back to the session
---@return integer|nil jobid
local function start(opts, token, handle)
  local has_body = opts.body ~= nil

  local cmd = curl.build_request({
    url = opts.url,
    method = opts.method or 'GET',
    headers = {
      'Authorization: Bearer ' .. token,
      'Content-Type: application/json',
    },
    stdin_body = has_body,
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
      deliver(opts, handle, code, signal, stdout, stderr)
    end,
  })

  if not jobid or jobid <= 0 then
    return nil
  end

  if has_body then
    job.send(jobid, vim.json.encode(opts.body))
    job.send(jobid, nil)
  end

  return jobid
end

---@class ChatLarkHttpRequest
---@field url string Full request URL; `pre` may rewrite it before the start
---@field method? string HTTP method (default: GET)
---@field body? table JSON body, sent over stdin
---@field label string Tool name used in error messages ("lark_sheets")
---@field api_name? string Human readable API name ("Sheets API")
---@field ctx ChatToolContext
---@field render? fun(data: table, res: table): string Custom success mapping
---@field pre? fun(token: string, done: fun(err?: string))
---        Runs before the request starts and may rewrite `url`/`body`.
---        Used to resolve wiki links into a concrete object token.
---        When set, the call always takes the synthetic-handle path: the
---        final jobid is not known synchronously, so the session cannot be
---        given one up front.

--- Run a token-gated Open API request.
---@param opts ChatLarkHttpRequest
---@return table Tool result: { jobid }, { mcp_tool_call_id } or { error }
function M.request(opts)
  if not curl.is_available() then
    return { error = CURL_ERROR }
  end

  -- Fast path: cached token and no pre-step, so the request starts right
  -- away and the caller gets a real jobid (cancel kills the actual curl).
  local token = auth.cached_token()
  if token and not opts.pre then
    -- The exit callback captures this table by reference, so assigning
    -- `handle.jobid` after job.start() is visible when the callback fires.
    local handle = {}
    local jobid = start(opts, token, handle)
    if not jobid then
      return { error = start_error(opts.url) }
    end
    handle.jobid = jobid
    return { jobid = jobid }
  end

  -- Cold token (or a pre-step): report a negative handle (same contract as
  -- MCP) and start the request once the token and pre-step are done.
  next_handle = next_handle - 1
  local handle_id = next_handle
  pending_handles[handle_id] = true

  -- cancel_progress invokes this when the user cancels while the token
  -- request (or the wiki resolution) is still in flight. Clearing the flag
  -- makes the continuation abort: firing the request anyway would silently
  -- write to the user's document after they cancelled.
  local async = require('chat.sessions.async')
  async.register_cancel_handler(handle_id, function()
    if not pending_handles[handle_id] then
      return false
    end
    pending_handles[handle_id] = nil
    return true
  end)

  local handle = { mcp_tool_call_id = handle_id }

  local function release()
    local alive = pending_handles[handle_id]
    pending_handles[handle_id] = nil
    async.unregister_cancel_handler(handle_id)
    return alive
  end

  local function fail(err)
    if not release() then
      -- Cancelled in the meantime: drop the result silently.
      return
    end
    opts.ctx.callback(vim.tbl_extend('force', handle, { error = err }))
  end

  -- The token is passed in explicitly rather than re-read from the cache:
  -- a failing request that reset the cache would otherwise leave `launch()`
  -- with nil and crash on 'Bearer ' .. nil.
  local function launch(token)
    if not release() then
      return
    end
    local jobid = start(opts, token, handle)
    if not jobid then
      opts.ctx.callback(vim.tbl_extend('force', handle, {
        error = start_error(opts.url),
      }))
    end
  end

  auth.ensure_token(function(new_token, token_err)
    if not new_token then
      fail(token_err or 'failed to obtain tenant_access_token')
      return
    end
    if not opts.pre then
      launch(new_token)
      return
    end
    opts.pre(new_token, function(pre_err)
      if pre_err then
        fail(pre_err)
        return
      end
      launch(new_token)
    end)
  end)

  return handle
end

--- Drop pending handles and reset the id allocator (internal export for
--- tests, so one spec's cold-token call cannot leak into the next).
function M._reset()
  next_handle = HANDLE_BASE
  pending_handles = {}
end

return M

