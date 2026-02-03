local M = {}
local config = require('chat.config')

function M.get()
  local items = {}
  local ok, provider =
    pcall(require, 'chat.providers.' .. config.config.provider)
  if ok and provider.available_models then
    for _, model in ipairs(provider.available_models()) do
      table.insert(items, {
        str = model,
        value = model,
      })
    end
  end
  return items
end

function M.default_action(item)
  config.config.model = item.value
  require('chat.windows').set_model(item.model)
end

return M
