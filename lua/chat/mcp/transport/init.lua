local M = {}

local log = require('chat.log')

-- Transport registry
M.transports = {}

-- Register a transport type
function M.register(type_name, transport_module)
  M.transports[type_name] = transport_module
end

-- Get a transport module
function M.get(type_name)
  return M.transports[type_name]
end

-- Check if transport type exists
function M.exists(type_name)
  return M.transports[type_name] ~= nil
end

return M
