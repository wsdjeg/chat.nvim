local M = {}

function M.available_tools()
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
  return tools
end

function M.call(func, arguments)
  if func == 'read_file' then
    return require('chat.tools.read_file').read_file(arguments)
  end

  local tool_module = 'chat.tools.' .. func

  local ok, tool = pcall(require, tool_module)
  if ok and tool[func] then
    return tool[func](arguments)
  end

  return {
    error = 'unknown tool function name.',
  }
end

function M.info(tool_call)
  local tool_module = 'chat.tools.' .. tool_call['function'].name

  local ok, tool = pcall(require, tool_module)
  if ok and tool.info then
    return tool.info(tool_call['function'].arguments)
  else
    return tool_call['function'].name
  end
end

return M
