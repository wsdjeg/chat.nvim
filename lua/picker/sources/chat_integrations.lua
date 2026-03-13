local M = {}

local sessions = require('chat.sessions')
local windows = require('chat.windows')
local formatter = require('chat.formatter')

local previewer = require('picker.previewer.buffer')

function M.get()
  local items = {}
  local integrations = vim.tbl_filter(
    function(t)
      return t ~= 'init'
    end,
    vim.tbl_map(function(t)
      return vim.fn.fnamemodify(t, ':t:r')
    end, vim.api.nvim_get_runtime_file(
      'lua/chat/integrations/*.lua',
      true
    ))
  )
  for _, v in ipairs(integrations) do
    local bridge = require('chat.integrations.' .. v)
    local session = bridge.current_session()
    if session and sessions.exists(session) then
      local messages = sessions.get_messages(session)
      if #messages > 1 then
        local str = vim.split(messages[1].content, '\n')[1]
        table.insert(items, {
          str = string.format(
            '[%s] [%s] %s',
            v,
            bridge.current_session(),
            str
          ),
          value = bridge.current_session(),
          highlight = {
            -- highlight of square brackets
            { 0, 1, 'Comment' },
            { #v + 1, #v + 2, 'Comment' },
            { #v + 3, #v + 4, 'Comment' },
            { #v + 23, #v + 24, 'Comment' },
            --- highlight of bridge name
            { 1, #v + 1, 'String' },
            --- highlight of session ID
            { 1 + #v + 3, 1 + #v + 24, 'Comment' },
          },
        })
      end
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
  previewer.buflines =
    formatter.generate_buffer(sessions.get_messages(item.value), item.value)
  previewer.filetype = 'markdown'
  previewer.preview(line, win, buf, true)
end

return M
