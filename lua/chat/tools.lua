local M = {}

local log = require('chat.log')

---@class ChatToolContext
---@field cwd? string  -- 会话工作目录
---@field session? string  -- 会话ID
---@field user? string  -- 用户信息
---@field callback? function async tool callback

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

function M.available_tools()
  -- 获取 chat.nvim 内置 tools
  local tool_modules = vim.tbl_map(function(t)
    return 'chat.tools.' .. vim.fn.fnamemodify(t, ':t:r')
  end, vim.api.nvim_get_runtime_file('lua/chat/tools/*.lua', true))

  local tools = {}
  for _, t in ipairs(tool_modules) do
    local ok, tool = pcall(require, t)
    if
      ok
      and tool
      and type(tool) == 'table'
      and type(tool.scheme) == 'function'
    then
      local scheme = tool.scheme()
      local errors = M.validate_scheme(scheme)
      if #errors > 0 then
        local name = (scheme['function'] and scheme['function'].name) or t
        log.warn(string.format('Tool scheme validation failed for %s:\n  %s',
          name, table.concat(errors, '\n  ')))
      end
      table.insert(tools, scheme)
    end
  end

  -- 合并 MCP tools（如果 MCP 已启用）
  local ok, mcp_module = pcall(get_mcp)
  if ok and mcp_module then
    local mcp_tools = mcp_module.available_tools()
    if mcp_tools and #mcp_tools > 0 then
      for _, scheme in ipairs(mcp_tools) do
        local errors = M.validate_scheme(scheme)
        if #errors > 0 then
          local name = (scheme['function'] and scheme['function'].name) or 'unknown'
          log.warn(string.format('MCP tool scheme validation failed for %s:\n  %s',
            name, table.concat(errors, '\n  ')))
        end
      end
      vim.list_extend(tools, mcp_tools)
    end
  end

  return tools
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

