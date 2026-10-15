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

  -- Each property definition should have a type field, or an anyOf array
  -- of typed variants (for properties accepting multiple types, e.g.
  -- "string or array of strings").
  if type(params.properties) == 'table' then
    for prop_name, prop_def in pairs(params.properties) do
      if type(prop_def) ~= 'table' then
        table.insert(errors, string.format(
          'parameters.properties.%s must be a table', prop_name))
      elseif prop_def.type then
        -- Single-typed property: nothing else to check here.
      elseif type(prop_def.anyOf) == 'table' and #prop_def.anyOf > 0 then
        -- anyOf: each variant must be a table with a type field
        for i, variant in ipairs(prop_def.anyOf) do
          if type(variant) ~= 'table' or not variant.type then
            table.insert(errors, string.format(
              'parameters.properties.%s.anyOf[%d] must be a table with a "type" field',
              prop_name, i))
          end
        end
      else
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
--- Called when a turn ends with a text-only response (no tool calls), so
--- the next turn starts fresh from lazy loading.
---@param session_id string
function M.clear_activated_tools(session_id)
  activated[session_id] = nil
end

--- Scan session history and collect tool names called in the current turn.
--- A turn starts with a user message and ends when the assistant replies
--- with text only (no tool calls). Tool names are reset at such turn-end
--- messages, so finished turns do not leak their tools into later turns,
--- while tools called within the still-open turn are re-included. This
--- keeps tool activation self-healing across aborts/restarts mid-loop.
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
    if m.role == 'assistant' then
      local tcs = type(m.tool_calls) == 'table' and m.tool_calls or {}
      if #tcs > 0 then
        for _, tc in ipairs(tcs) do
          local n = tc['function'] and tc['function'].name
          if n and n ~= '' then
            names[n] = true
          end
        end
      else
        -- Text-only assistant reply: this turn is finished. Tools used in
        -- earlier turns are not carried into the next one.
        names = {}
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

  -- 2. tools already called in the current turn (self-healing after abort
  --    or restart mid-loop; finished turns do not carry tools over)
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

-- ── Argument normalization ─────────────────────────────────────────────
-- Models routinely violate their JSON schemas in ways that break tools:
--   * numbers as strings ("count": "10"): comparisons raise
--     (attempt to compare number with string) and string.format('%d', v)
--     raises on non-numeric strings
--   * booleans as strings ("force": "false"): Lua truthiness makes
--     "false" truthy, so `if action.force then` force-pushes when the
--     model meant NOT to
--   * bare string for an array param ("file_types": "*.lua")
--   * JSON null decoding to vim.NIL, which is truthy in Lua
-- Normalizing decoded arguments against the tool's own scheme at the
-- entry point fixes every tool at once instead of patching each handler.
--
-- Only dangerous classes are coerced. Non-numeric strings for number
-- params and non-string values for string params pass through untouched:
-- the tool's own validation already reports those with a clear error and
-- the model retries correctly.

-- tool name -> scheme.parameters table (false = no scheme available);
-- schemes are static per module, the cache never needs invalidation
local scheme_params_cache = {}

---@param name string Tool function name
---@return table? params scheme parameters, nil when unavailable
local function get_scheme_params(name)
  local cached = scheme_params_cache[name]
  if cached ~= nil then
    return cached or nil
  end
  local params = nil
  local ok, tool = pcall(require, 'chat.tools.' .. name)
  if ok and tool and type(tool.scheme) == 'function' then
    local ok_s, scheme = pcall(tool.scheme)
    if
      ok_s
      and type(scheme) == 'table'
      and type(scheme['function']) == 'table'
      and type(scheme['function'].parameters) == 'table'
    then
      params = scheme['function'].parameters
    end
  end
  scheme_params_cache[name] = params or false
  return params
end

--- Scalar types accepted by a property definition.
--- Returns nil for anyOf / multi-typed properties: there is no single
--- target type to coerce toward, so values pass through untouched.
---@param def any Property definition from the scheme
---@return table<string, boolean>? types
local function property_types(def)
  if type(def) == 'table' and type(def.type) == 'string' then
    return { [def.type] = true }
  end
  return nil
end

--- Coerce one value toward a declared scalar type.
--- Values that cannot be converted pass through unchanged, so the tool's
--- own validation still reports them with its usual error message.
---@param v any Value from decoded arguments
---@param types table<string, boolean> Declared types
---@return any coerced
local function coerce_value(v, types)
  if types.boolean then
    if type(v) == 'string' then
      local lower = v:lower()
      if lower == 'true' then
        return true
      end
      if lower == 'false' then
        return false
      end
    elseif type(v) == 'number' then
      -- 0 is truthy in Lua but the model means false
      return v ~= 0
    end
  elseif types.number or types.integer then
    if type(v) == 'string' then
      local n = tonumber(v)
      if n ~= nil then
        return n
      end
    end
  elseif types.array then
    -- bare string for an array param: wrap it (plan step_ids,
    -- search_text file_types, ...)
    if type(v) == 'string' then
      return { v }
    end
  end
  return v
end

--- Coerce array items toward the declared items type, dropping JSON nulls.
---@param v any Value from decoded arguments
---@param def table Property definition (type = 'array')
---@return any coerced
local function coerce_items(v, def)
  if type(v) ~= 'table' or type(def.items) ~= 'table' then
    return v
  end
  local types = property_types(def.items)
  if not types then
    return v
  end
  local out = {}
  local changed = false
  for _, item in ipairs(v) do
    if item == vim.NIL then
      changed = true
    else
      local c = coerce_value(item, types)
      changed = changed or c ~= item
      table.insert(out, c)
    end
  end
  if not changed then
    return v
  end
  return out
end

--- Normalize decoded tool arguments against the tool's scheme (see the
--- section comment above). Returns a NEW table, the input is untouched.
--- Arguments not declared in the scheme pass through unchanged; JSON null
--- values are dropped (vim.NIL is truthy in Lua and would otherwise flip
--- `if action.x then` checks).
---@param name string Tool function name
---@param arguments table Decoded tool arguments
---@return table normalized
function M.normalize_arguments(name, arguments)
  if type(arguments) ~= 'table' then
    return arguments
  end
  local params = get_scheme_params(name)
  if not params or type(params.properties) ~= 'table' then
    return arguments
  end
  local out = {}
  for k, v in pairs(arguments) do
    if v ~= vim.NIL then
      local def = params.properties[k]
      local types = property_types(def)
      if types then
        v = coerce_value(v, types)
        if types.array then
          v = coerce_items(v, def)
        end
      end
      out[k] = v
    end
  end
  return out
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
    -- Coerce model mistakes (numbers/booleans as strings, bare strings
    -- for array params, JSON nulls) against the scheme before the tool
    -- sees them.
    arguments = M.normalize_arguments(func, arguments)
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
  if ok and tool and type(tool.info) == 'function' then
    -- Normalize arguments the same way as M.call: info() formats numeric
    -- params with string.format('%d', ...) and would raise on strings,
    -- and boolean flags sent as strings display incorrectly.
    local args_str = tool_call['function'].arguments
    if type(args_str) == 'string' and args_str ~= '' then
      local ok_d, decoded = pcall(vim.json.decode, args_str)
      if ok_d and type(decoded) == 'table' and next(decoded) ~= nil then
        decoded = M.normalize_arguments(name, decoded)
        local ok_e, encoded = pcall(vim.json.encode, decoded)
        if ok_e and type(encoded) == 'string' then
          args_str = encoded
        end
      end
    end
    -- info() only renders UI text: never let it break the rendering
    -- pipeline, fall back to the tool name on failure.
    local ok_i, info = pcall(tool.info, args_str, ctx)
    if ok_i and type(info) == 'string' then
      return info
    end
    if not ok_i then
      log.warn(string.format('tool info() for %s raised: %s', name, tostring(info)))
    end
    return name
  else
    return name
  end
end

return M

