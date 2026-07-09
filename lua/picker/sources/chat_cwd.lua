local M = {}

local sessions = require('chat.sessions')
local windows = require('chat.windows')
local formatter = require('chat.formatter')

local previewer = require('picker.previewer.buffer')

--- Get the first non-empty line from a message content
--- @param content string
--- @return string|nil
local function first_non_empty_line(content)
  for _, line in ipairs(vim.split(content, '\n')) do
    if line ~= '' then
      return line
    end
  end
  return nil
end

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
      local cwd = sessions.getcwd(id) or ''
      local cwd_tail = vim.fn.fnamemodify(cwd, ':t')
      if cwd_tail == '' then
        cwd_tail = '~'
      end

      local str
      local title = sessions.get_session_title(id)
      if not title or title == '' then
        str = first_non_empty_line(messages[1].content)
      else
        str = title
      end

      if str then
        local display = string.format('[%s] %s', cwd_tail, str)
        table.insert(items, {
          str = display,
          value = id,
          highlight = {
            -- highlight square brackets
            { 0, 1, 'Comment' },
            { #cwd_tail + 1, #cwd_tail + 2, 'Comment' },
            -- highlight cwd tail
            { 1, #cwd_tail + 1, 'Directory' },
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
    ['<C-t>'] = function(entry)
      local path = require('chat.sessions').get_cache_path(entry.value)
      if path then
        vim.cmd.tabedit(path)
      else
        require('chat.log').notify(
          'cache file for selected session does not exist'
        )
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

