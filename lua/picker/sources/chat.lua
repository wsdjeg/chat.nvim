local M = {}

local previewer = require('picker.previewer.buffer')

function M.get()
  local sessions = require('chat.sessions').get()
  local items = {}

  for id, session in pairs(sessions) do
    local str = vim.split(session[1].content, '\n')[1]
    table.insert(items, {
      str = str,
      value = id,
    })
  end

  return items
end

function M.actions()
  return {
    ['<C-d>'] = function(entry)
      require('chat.sessions').delete(entry.value)
    end,
  }
end

function M.default_action(item)
  require('chat').open({
    session = item.value,
  })
end
M.preview_win = true

function M.preview(item, win, buf)
  local line = 1
  previewer.buflines = require('chat.windows').generate_buffer(
    require('chat.sessions').get_messages(item.value)
  )
  previewer.filetype = 'markdown'
  previewer.preview(line, win, buf, true)
end

return M
