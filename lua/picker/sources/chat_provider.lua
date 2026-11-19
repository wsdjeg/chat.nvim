local M = {}

local previewer = require('picker.previewer.buffer')
local windows = require('chat.windows')
local sessions = require('chat.sessions')
local providers = require('chat.providers')

function M.get()
  return vim.tbl_map(function(name)
    return {
      value = name,
      str = name,
    }
  end, providers.list())
end

function M.default_action(item)
  local current_session = windows.current_session()
  if
    not current_session
    or item.value == sessions.get_session_provider(current_session)
  then
    return
  end

  -- available_models() may still be loading (dynamic providers fetch in the
  -- background), so the model list can legitimately be empty on the first
  -- call. Switch the provider anyway - refusing to would leave the picker
  -- doing nothing at all - and tell the user the model still needs a pick.
  local models = providers.available_models(item.value)
  if
    not sessions.set_session_provider(current_session, item.value)
  then
    return
  end
  if #models > 0 then
    sessions.set_session_model(current_session, models[1])
  else
    require('chat.log').notify(
      'Models is loading for ' .. item.value .. ', use Picker chat_model',
      'WarningMsg'
    )
  end
end

M.preview_win = true

function M.preview(item, win, buf)
  previewer.buflines = {
    '## Available models',
    '',
  }
  for _, model in ipairs(providers.available_models(item.value)) do
    table.insert(previewer.buflines, '- ' .. model)
  end
  previewer.filetype = 'markdown'
  previewer.preview(1, win, buf, true)
end

return M

