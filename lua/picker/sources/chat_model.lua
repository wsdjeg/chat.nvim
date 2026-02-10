local M = {}

local windows = require('chat.windows')
local sessions = require('chat.sessions')

function M.get()
  local items = {}
  local current_session = windows.current_session()
  if current_session then
    local ok, provider =
      pcall(require, 'chat.providers.' .. sessions.get_session_provider(current_session))
    if ok and provider.available_models then
      for _, model in ipairs(provider.available_models()) do
        table.insert(items, {
          str = model,
          value = model,
        })
      end
    end
  end
  return items
end

function M.default_action(item)
  sessions.set_session_model(windows.current_session(), item.value)
end

return M
