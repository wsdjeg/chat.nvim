local M = {}

local sessions = require('chat.sessions')
local windows = require('chat.windows')

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
      if entry.value == windows.current_session() then
        require('chat').open({
          session = require('chat.sessions').delete(entry.value),
        })
      else
        require('chat.sessions').delete(entry.value)
      end
    end,
    ['<C-o>'] = function(entry)
      local config = require('chat.config')
      local url = string.format(
        'http://%s:%d/session?id=%s',
        config.config.http.host,
        config.config.http.port,
        entry.value
      )

      -- Open in browser
      if vim.fn.has('win32') == 1 then
        vim.fn.system('start "" "' .. url .. '"')
      elseif vim.fn.has('mac') == 1 then
        vim.fn.system('open "' .. url .. '"')
      else
        vim.fn.system('xdg-open "' .. url .. '"')
      end

      require('chat.log').notify('Opening preview: ' .. url)
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
    sessions.get_messages(item.value),
    item.value
  )
  previewer.filetype = 'markdown'
  previewer.preview(line, win, buf, true)
end

return M
