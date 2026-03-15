local M = {}

---@class ChatToolContext
---@field cwd? string  -- 会话工作目录
---@field session? string  -- 会话ID
---@field user? string  -- 用户信息

-- 延迟加载 MCP 模块（避免循环依赖）
local mcp = nil
local function get_mcp()
  if not mcp then
    mcp = require('chat.mcp')
  end
  return mcp
end

function M.available_tools()
  -- 获取 chat.nvim 内置 tools
  local tool_modules = vim.tbl_map(function(t)
    return 'chat.tools.' .. vim.fn.fnamemodify(t, ':t:r')
  end, vim.api.nvim_get_runtime_file('lua/chat/tools/*.lua', true))

  local tools = {}
  for _, t in ipairs(tool_modules) do
    local ok, tool = pcall(require, t)
    if ok then
      table.insert(tools, tool.scheme())
    end
  end

  -- 合并 MCP tools（如果 MCP 已启用）
  local ok, mcp_module = pcall(get_mcp)
  if ok and mcp_module then
    local mcp_tools = mcp_module.available_tools()
    if mcp_tools and #mcp_tools > 0 then
      vim.list_extend(tools, mcp_tools)
    end
  end

  return tools
end

---@param ctx ChatToolContext
function M.call(func, arguments, ctx)
  -- 检查是否是 MCP tool (格式: mcp_<server>_<tool>)
  if func:match('^mcp_[^_]+_.+$') then
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
  -- 检查是否是 MCP tool
  if tool_call['function'].name:match('^mcp_[^_]+_.+$') then
    local ok, mcp_module = pcall(get_mcp)
    if ok and mcp_module then
      return mcp_module.tool_info(
        tool_call['function'].name,
        tool_call['function'].arguments
      )
    end
  end

  -- 原有的 chat.nvim tool 信息逻辑
  local tool_module = 'chat.tools.' .. tool_call['function'].name

  local ok, tool = pcall(require, tool_module)
  if ok and tool.info then
    return tool.info(tool_call['function'].arguments, ctx)
  else
    return tool_call['function'].name
  end
end

return M
