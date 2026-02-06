local M = {}



function M.available_tools()
  local tools = {}
  table.insert(tools, require('chat.tools.read_file').scheme())
  return tools
end

function M.call(func, arguments)

  if func == 'read_file' then
    return require('chat.tools.read_file').read_file(arguments)
  end

  return {
    error = 'unknown tool function name.'
  }

end

return M
