local M = {}

local sessions = require('chat.sessions')

local previewer = require('picker.previewer.buffer')

function M.get()
  local items = {}

  local ids = {}

  for id, _ in pairs(sessions.get()) do
    table.insert(ids, id)
  end

  table.sort(ids, function(a, b)
    return a > b
  end)

  for _, id in ipairs(ids) do
    local messages = sessions.get_messages(id)
    if #messages > 1 then
      local str = vim.split(messages[1].content, '\n')[1]
      table.insert(items, {
        str = str,
        value = id,
      })
    end
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
    sessions.get_messages(item.value)
  )
  previewer.filetype = 'markdown'
  previewer.preview(line, win, buf, true)
end

return M
