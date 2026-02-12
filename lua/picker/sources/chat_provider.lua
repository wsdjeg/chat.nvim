local M = {}

local previewer = require('picker.previewer.buffer')
local windows = require('chat.windows')
local sessions = require('chat.sessions')

function M.get()
  return vim.tbl_map(function(t)
    t = vim.fn.fnamemodify(t, ':t:r')
    return {
      value = t,
      str = t,
    }
  end, vim.api.nvim_get_runtime_file('lua/chat/providers/*.lua', true))
end

function M.default_action(item)
  local current_session = windows.current_session()
  if not current_session or
    item.value == sessions.get_session_provider(windows.current_session())
  then
    return
  end
  local ok, provider = pcall(require, 'chat.providers.' .. item.value)
  if ok then
    local available_models = provider.available_models()
    if #available_models > 0 then
      if
        sessions.set_session_provider(windows.current_session(), item.value)
      then
        sessions.set_session_model(
          windows.current_session(),
          available_models[1]
        )
      end
    end
  end
end

M.preview_win = true

function M.preview(item, win, buf)
  local ok, provider = pcall(require, 'chat.providers.' .. item.value)
  if ok then
    previewer.buflines = {
      '## Available models',
      '',
    }
    local available_models = provider.available_models()
    if #available_models > 0 then
      for _, model in ipairs(available_models) do
        table.insert(previewer.buflines, '- ' .. model)
      end
    end
  end
  local line = 1
  previewer.filetype = 'markdown'
  previewer.preview(line, win, buf, true)
end

return M
