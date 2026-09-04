local M = {}

local log = require('chat.log')
local util = require('chat.util')

---@class ChatToolContext
---@field cwd? string  -- 会话工作目录
---@field session? string  -- 会话ID
---@field user? string  -- 用户信息
---@field callback? function async tool callback

-- session_id -> set of activated tool names (via find_tool)
local activated = {} ---@type table<string, table<string, boolean>>

-- 延迟加载 MCP 模块（避免循环依赖）
local mcp = nil
local function get_mcp()
  if not mcp then
    mcp = require('chat.mcp')
  end
  return mcp
end

--- Validate a tool scheme structure.
--- Returns a list of error messages (empty if valid).
---@param scheme table The tool scheme to validate
---@return string[] errors List of validation error messages
function M.validate_scheme(scheme)
  local errors = {}

  if type(scheme) ~= 'table' then
    return { 'scheme must be a table, got: ' .. type(scheme) }
  end

  -- type must be 'function'
  if scheme.type ~= 'function' then
    table.insert(errors, string.format(
      'type must be "function", got: %s', tostring(scheme.type)))
  end

  -- function table
  local fn = scheme['function']
  if type(fn) ~= 'table' then
    table.insert(errors, '["function"] must be a table')
    return errors
  end

  -- name: non-empty string, valid identifier pattern
  local name = fn.name
  if type(name) ~= 'string' or name == '' then
    table.insert(errors, 'function.name must be a non-empty string')
  elseif not name:match('^[a-zA-Z_][a-zA-Z0-9_]*$') then
    table.insert(errors, string.format(
      'function.name "%s" contains invalid characters (expected ^[a-zA-Z_][a-zA-Z0-9_]*$)', name))
  end

  -- description: non-empty string
  if type(fn.description) ~= 'string' or fn.description == '' then
    table.insert(errors, 'function.description must be a non-empty string')
  end

  -- parameters: table
  local params = fn.parameters
  if type(params) ~= 'table' then
    table.insert(errors, 'function.parameters must be a table')
    return errors
  end

  -- parameters.type should be 'object'
  if params.type and params.type ~= 'object' then
    table.insert(errors, string.format(
      'parameters.type should be "object", got: %s', tostring(params.type)))
  end

  -- properties: should be a table if present
  if params.properties ~= nil and type(params.properties) ~= 'table' then
    table.insert(errors, 'parameters.properties must be a table')
  end

  -- required: array of strings, each must exist in properties
  if params.required ~= nil then
    if type(params.required) ~= 'table' then
      table.insert(errors, 'parameters.required must be an array')
    else
      local props = params.properties or {}
      for _, req in ipairs(params.required) do
        if type(req) ~= 'string' then
          table.insert(errors, 'parameters.required contains non-string entry')
        elseif props[req] == nil then
          table.insert(errors, string.format(
            'parameters.required references unknown property: "%s"', req))
        end
      end
    end
  end

  -- Each property definition should have a type field
  if type(params.properties) == 'table' then
    for prop_name, prop_def in pairs(params.properties) do
      if type(prop_def) ~= 'table' then
        table.insert(errors, string.format(
          'parameters.properties.%s must be a table', prop_name))
      elseif not prop_def.type then
        table.insert(errors, string.format(
          'parameters.properties.%s missing "type" field', prop_name))
      end
    end
  end

  return errors
end

--- Get the first non-empty line of a description text, truncated.
--- Truncation cuts at a UTF-8 character boundary: byte-based sub() would
--- split multi-byte characters (e.g. Chinese) and produce invalid UTF-8
--- that ends up in the find_tool catalog and request bodies
--- (InvalidParameter.NonUTF8Body on strict providers).
---@param text string
---@return string|nil
local function first_line(text)
  if type(text) ~= 'string' or text == '' then
    return nil
  end
  local line = text:match('^[^\r\n]+') or ''
  line = line:gsub('^%s+', ''):gsub('%s+$', '')
  if #line > 120 then
    line = util.utf8_truncate(line, 117) .. '...'
  end
  if line == '' then
    return nil
  end
  return line
end

--- Recursively sanitize all strings in a tool scheme to valid UTF-8.
--- Tool schemes from external sources (MCP servers) may contain invalid
--- UTF-8 bytes (e.g. Windows GBK console output). Sending them raw makes
--- the whole request body fail with NonUTF8Body on some providers.
---@param value any Scheme value (string, number, table, ...)
---@param depth number Current recursion depth (guards against cycles)
---@return any sanitized, boolean had_invalid
local function sanitize_scheme_strings(value, depth)
  if depth > 8 then
    return value, false
  end
  if type(value) == 'string' then
    return util.sanitize_utf8(value)
  end
  if type(value) == 'table' then
    local out = {}
    local changed = false
    local had_invalid = false
    for k, v in pairs(value) do
      local sk = k
      if type(k) == 'string' then
        local k_invalid
        sk, k_invalid = util.sanitize_utf8(k)
        had_invalid = had_invalid or k_invalid
        changed = changed or sk ~= k
      end
      local sv, v_invalid = sanitize_scheme_strings(v, depth + 1)
      had_invalid = had_invalid or v_invalid
      changed = changed or sv ~= v
      out[sk] = sv
    end
    if changed then
      return out, had_invalid
    end
    return value, had_invalid
  end
  return value, false
end

-- Internal export for tests (same convention as providers' _convert_tools).
M._sanitize_scheme_strings = sanitize_scheme_strings

--- Collect built-in tool modules with their schemes (find_tool excluded).
---@return table[] entries { module = table, scheme = table }
local function collect_builtin_tools()
  local tool_modules = vim.tbl_map(function(t)
    return 'chat.tools.' .. vim.fn.fnamemodify(t, ':t:r')
  end, vim.api.nvim_get_runtime_file('lua/chat/tools/*.lua', true))

  local entries = {}
  for _, t in ipairs(tool_modules) do
    local ok, tool = pcall(require, t)
    if
      ok
      and tool
      and type(tool) == 'table'
      and type(tool.scheme) == 'function'
    then
      -- find_tool is excluded: its description embeds the catalog of other
      -- tools, calling its scheme() here would cause infinite recursion.
      if not tool.is_find_tool then
        local scheme = tool.scheme()
        local errors = M.validate_scheme(scheme)
        if #errors > 0 then
          local name = (scheme['function'] and scheme['function'].name) or t
          log.warn(string.format('Tool scheme validation failed for %s:\n  %s',
            name, table.concat(errors, '\n  ')))
        end
        table.insert(entries, { module = tool, scheme = scheme })
      end
    end
  end
  return entries
end

--- Collect MCP tool schemes (if MCP is enabled).
--- Schemes are sanitized to valid UTF-8: MCP servers are external processes
--- whose tool descriptions may contain invalid bytes, and schemes go into
--- both request bodies and the find_tool catalog.
---@return table[]
local function collect_mcp_tools()
  local ok, mcp_module = pcall(get_mcp)
  if not ok or not mcp_module then
    return {}
  end
  local mcp_tools = mcp_module.available_tools()
  if not mcp_tools or #mcp_tools == 0 then
    return {}
  end
  local tools = {}
  for _, scheme in ipairs(mcp_tools) do
    local sanitized, had_invalid = sanitize_scheme_strings(scheme, 0)
    if had_invalid then
      local name = (sanitized['function'] and sanitized['function'].name) or 'unknown'
      log.warn(string.format(
        'MCP tool scheme for %s contained invalid UTF-8 bytes (replaced with U+FFFD)',
        name))
    end
    local errors = M.validate_scheme(sanitized)
    if #errors > 0 then
      local name = (sanitized['function'] and sanitized['function'].name) or 'unknown'
      log.warn(string.format('MCP tool scheme validation failed for %s:\n  %s',
        name, table.concat(errors, '\n  ')))
    end
    table.insert(tools, sanitized)
  end
  return tools
end

function M.available_tools()
  local tools = {}
  for _, e in ipairs(collect_builtin_tools()) do
    table.insert(tools, e.scheme)
  end
  vim.list_extend(tools, collect_mcp_tools())
  return tools
end

--- Get the one-line introduction of a tool.
--- Order: tool module's `introduction()` function, then the first line
--- of the scheme description, then the tool name.
---@param tool table Tool module
---@param scheme table Tool scheme
---@return string
function M.tool_introduction(tool, scheme)
  if tool and type(tool.introduction) == 'function' then
    local ok, intro = pcall(tool.introduction)
    if ok and type(intro) == 'string' and intro:match('%S') then
      return intro
    end
  end
  local desc = scheme and scheme['function'] and scheme['function'].description
  local line = first_line(desc)
  if line then
    return line
  end
  return (scheme and scheme['function'] and scheme['function'].name) or 'unknown tool'
end

--- List all tools (built-in + MCP, excluding find_tool) with one-line introductions.
---@return table[] Array of { name = string, introduction = string }
function M.available_introductions()
  local list = {}
  for _, e in ipairs(collect_builtin_tools()) do
    local name = e.scheme['function'].name
    table.insert(list, {
      name = name,
      introduction = M.tool_introduction(e.module, e.scheme),
    })
  end
  for _, scheme in ipairs(collect_mcp_tools()) do
    local fn = scheme['function']
    table.insert(list, {
      name = fn.name,
      introduction = first_line(fn.description) or fn.name,
    })
  end
  table.sort(list, function(a, b)
    return a.name < b.name
  end)
  return list
end

--- Build the formatted tool catalog lines (name: introduction), sorted.
---@return string[]
function M.catalog_lines()
  local lines = {}
  for _, t in ipairs(M.available_introductions()) do
    table.insert(lines, string.format('- %s: %s', t.name, t.introduction))
  end
  return lines
end

--- Activate a tool for a session: it will be included in subsequent requests.
---@param session_id string
---@param name string Tool name
function M.activate_tool(session_id, name)
  if not session_id or not name then
    return
  end
  activated[session_id] = activated[session_id] or {}
  activated[session_id][name] = true
end

--- Get activated tool names for a session.
---@param session_id string
---@return table<string, boolean>
function M.get_activated_tools(session_id)
  return vim.deepcopy(activated[session_id] or {})
end

--- Clear activated tool names for a session.
---@param session_id string
function M.clear_activated_tools(session_id)
  activated[session_id] = nil
end

--- Scan session history and collect tool names that were already called.
--- This makes tool activation self-healing across session restarts.
---@param session_id string
---@return table<string, boolean>
local function scan_history_tool_names(session_id)
  local names = {}
  if not session_id then
    return names
  end
  local ok, storage = pcall(require, 'chat.sessions.storage')
  if not ok or not storage then
    return names
  end
  local s = storage.sessions and storage.sessions[session_id]
  if not s or type(s.messages) ~= 'table' then
    return names
  end
  for _, m in ipairs(s.messages) do
    if m.role == 'assistant' and type(m.tool_calls) == 'table' then
      for _, tc in ipairs(m.tool_calls) do
        local n = tc['function'] and tc['function'].name
        if n and n ~= '' then
          names[n] = true
        end
      end
    end
  end
  return names
end

--- Get tools to send with a request for a session.
--- In lazy mode: essential tools + tools activated via find_tool (or already
--- called in history) + find_tool. Otherwise all available tools.
---@param session_id string
---@return table
function M.request_tools(session_id)
  local cfg = require('chat.config').config.tools or {}
  if cfg.lazy == false then
    return M.available_tools()
  end

  local all = M.available_tools()
  local by_name = {}
  for _, scheme in ipairs(all) do
    by_name[scheme['function'].name] = scheme
  end

  local selected = {}
  local seen = {}

  -- 1. essential tools first
  for _, name in ipairs(cfg.essential or {}) do
    if by_name[name] and not seen[name] then
      seen[name] = true
      table.insert(selected, by_name[name])
    end
  end

  -- 2. tools already called in session history (self-healing after restart)
  for name in pairs(scan_history_tool_names(session_id)) do
    if by_name[name] and not seen[name] then
      seen[name] = true
      table.insert(selected, by_name[name])
    end
  end

  -- 3. tools activated via find_tool in this session
  for name in pairs(activated[session_id] or {}) do
    if by_name[name] and not seen[name] then
      seen[name] = true
      table.insert(selected, by_name[name])
    end
  end

  -- 4. find_tool itself, always last (excluded from collect_builtin_tools
  --    to avoid recursion via its catalog-embedding description)
  if not seen['find_tool'] then
    local ok, ft = pcall(require, 'chat.tools.find_tool')
    if ok and ft and type(ft.scheme) == 'function' then
      local scheme = ft.scheme()
      -- Sanitize like MCP schemes: the embedded catalog comes from many
      -- sources, keep the invariant that every scheme in a request body
      -- is valid UTF-8.
      local had_invalid
      scheme, had_invalid = sanitize_scheme_strings(scheme, 0)
      if had_invalid then
        log.warn('find_tool scheme contained invalid UTF-8 bytes (replaced with U+FFFD)')
      end
      local errors = M.validate_scheme(scheme)
      if #errors > 0 then
        log.warn(string.format('Tool scheme validation failed for find_tool:\n  %s',
          table.concat(errors, '\n  ')))
      end
      table.insert(selected, scheme)
    end
  end

  return selected
end

---@param ctx ChatToolContext
function M.call(func, arguments, ctx)
  -- 检查是否是 MCP tool (格式: mcp_<server>_<tool>)
  if func:match('^mcp_.+_.+$') then
    local ok, mcp_module = pcall(get_mcp)
    if ok and mcp_module then
      return mcp_module.call_tool(func, arguments, ctx)
    else
      return {
        error = 'MCP module not available.',
      }
    end
  end

  -- 原有的 chat.nvim tool 调用逻辑
  local tool_module = 'chat.tools.' .. func

  local ok, tool = pcall(require, tool_module)
  if ok and tool[func] then
    return tool[func](arguments, ctx)
  end

  return {
    error = 'unknown tool function name.',
  }
end

function M.info(tool_call, ctx)
  -- Guard against nil tool_call
  if not tool_call then
    return 'unknown tool'
  end

  -- Check if function info exists
  if not tool_call['function'] then
    return 'unknown tool'
  end

  -- Check if function name exists
  local name = tool_call['function'].name
  if not name then
    return 'unnamed tool'
  end

  -- 检查是否是 MCP tool
  if name:match('^mcp_.+_.+$') then
    local ok, mcp_module = pcall(get_mcp)
    if ok and mcp_module then
      return mcp_module.tool_info(name, tool_call['function'].arguments)
    end
  end

  -- 原有的 chat.nvim tool 信息逻辑
  local tool_module = 'chat.tools.' .. name

  local ok, tool = pcall(require, tool_module)
  if ok and tool.info then
    return tool.info(tool_call['function'].arguments, ctx)
  else
    return name
  end
end

return M

