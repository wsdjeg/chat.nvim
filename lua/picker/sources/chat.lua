local M = {}

function M.get()
  local sessions = require('chat.sessions').get()
  local items = {}

  for _, session in ipairs(sessions) do
  end

  return items
end

function M.default_action(item)
  require('chat').open({
    session = item.value
  })
end

return M
