local M = {}

local windows = require('chat.windows')
local sessions = require('chat.sessions')
local providers = require('chat.providers')

function M.get()
  local items = {}
  local current_session = windows.current_session()
  if current_session then
    local name = sessions.get_session_provider(current_session)
    for _, model in ipairs(providers.available_models(name)) do
      table.insert(items, {
        str = model,
        value = model,
      })
    end
  end
  return items
end

function M.default_action(item)
  sessions.set_session_model(windows.current_session(), item.value)
end

return M

