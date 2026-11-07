-- lua/chat/lark/url.lua
-- Parse the links Feishu/Lark users actually paste, and resolve wiki nodes.
--
-- A pasted link is the norm ("here is the sheet"), while the raw tokens the
-- Open API wants (shtcn..., doxcn..., bascn...) are buried inside it. Parsing
-- them here keeps every tool's parameter story the same: a `url` parameter
-- next to the explicit token parameter.
--
-- Wiki links are the awkward case: a `/wiki/wikcnXXXX` link carries a
-- node_token, which no document API accepts. The node has to be exchanged
-- for its obj_token through /wiki/v2/spaces/get_node first, which costs one
-- request and therefore runs asynchronously.
local M = {}

local curl = require('chat.curl')
local job = require('job')

local WIKI_NODE_URL = 'https://open.feishu.cn/open-apis/wiki/v2/spaces/get_node'

-- Ordered on purpose: `pairs` would make the parse order arbitrary.
local RESOURCES = {
  { type = 'docx', pattern = '/docx/(%w+)' },
  { type = 'sheets', pattern = '/sheets/(%w+)' },
  { type = 'base', pattern = '/base/(%w+)' },
  { type = 'wiki', pattern = '/wiki/(%w+)' },
}

-- Bare tokens carry their own prefix, so a token without a URL is enough.
local PREFIXES = {
  { prefix = 'doxcn', type = 'docx' },
  { prefix = 'shtcn', type = 'sheets' },
  { prefix = 'bascn', type = 'base' },
  { prefix = 'wikcn', type = 'wiki' },
}

-- obj_type -> the resource name this plugin uses. `sheet` is singular on
-- purpose: that is what the wiki API returns for spreadsheets.
local OBJ_TYPES = {
  docx = 'docx',
  sheet = 'sheets',
  bitable = 'base',
}

--- Parse a link or a bare token.
---@param input string URL or token
---@return table|nil target { type, token, raw }
function M.parse(input)
  if type(input) ~= 'string' then
    return nil
  end

  local text = vim.trim(input)
  if text == '' then
    return nil
  end

  if text:match('^https?://') then
    -- Query strings (?sheet=..., ?table=...) never carry the token, so a
    -- plain pattern match on the path segment is enough.
    for _, entry in ipairs(RESOURCES) do
      local token = text:match(entry.pattern)
      if token and token ~= '' then
        return { type = entry.type, token = token, raw = text }
      end
    end
    return nil
  end

  for _, entry in ipairs(PREFIXES) do
    if text:sub(1, #entry.prefix) == entry.prefix then
      return { type = entry.type, token = text, raw = text }
    end
  end

  return nil
end

--- Describe what a target is, for error messages.
---@param target_type string
---@return string
function M.label(target_type)
  local labels = {
    docx = 'a cloud document (docx)',
    sheets = 'a spreadsheet (sheets)',
    base = 'a Bitable (base)',
    wiki = 'a wiki node',
  }
  return labels[target_type] or ('a ' .. tostring(target_type) .. ' resource')
end

--- Exchange a wiki node token for the object behind it.
---@param node_token string wiki node_token (wikcn...)
---@param token string tenant_access_token
---@param callback fun(target: table|nil, err: string|nil)
---        target = { type, token, title? } where type is docx/sheets/base
---@return integer|nil jobid
function M.resolve_wiki(node_token, token, callback)
  local done = false
  local function finish(target, err)
    if done then
      return
    end
    done = true
    callback(target, err)
  end

  local url = WIKI_NODE_URL .. '?token=' .. node_token

  local cmd = curl.build_request({
    url = url,
    method = 'GET',
    headers = {
      'Authorization: Bearer ' .. token,
      'Content-Type: application/json',
    },
    -- Keep curl's diagnostics on stderr instead of silencing them.
    show_error = true,
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
      if signal ~= 0 then
        finish(nil, string.format('wiki node request cancelled (signal: %d)', signal))
        return
      end

      local raw = table.concat(stdout, '\n')
      local err_output = table.concat(stderr, '\n')

      if code ~= 0 then
        local hint = curl.get_error_message(code)
        local msg = string.format(
          'Failed to resolve wiki node (exit code: %d).\nURL: %s',
          code,
          url
        )
        if hint then
          msg = msg .. '\n\nTroubleshooting: ' .. hint
        end
        local detail = err_output ~= '' and err_output or raw
        if detail ~= '' then
          msg = msg .. '\nResponse: ' .. detail
        end
        finish(nil, msg)
        return
      end

      local ok, res = pcall(vim.json.decode, raw)
      if not ok or type(res) ~= 'table' then
        finish(nil, 'Invalid JSON from wiki node API: ' .. raw:sub(1, 500))
        return
      end

      if res.code and res.code ~= 0 then
        local log_id = res.error and res.error.log_id or '-'
        finish(
          nil,
          string.format(
            'Feishu API error %s: %s (log_id: %s)',
            tostring(res.code),
            res.msg or 'unknown',
            log_id
          )
        )
        return
      end

      local node = res.data and res.data.node
      if type(node) ~= 'table' or not node.obj_token then
        finish(nil, 'wiki node response has no obj_token: ' .. raw:sub(1, 500))
        return
      end

      local kind = OBJ_TYPES[node.obj_type]
      if not kind then
        finish(
          nil,
          string.format(
            'wiki node points to an unsupported object type: %s',
            tostring(node.obj_type)
          )
        )
        return
      end

      finish({
        type = kind,
        token = node.obj_token,
        title = node.title,
        wiki = node_token,
      })
    end,
  })

  if not jobid or jobid <= 0 then
    finish(nil, 'failed to start wiki node request')
    return nil
  end

  return jobid
end

return M

