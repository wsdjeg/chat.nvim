local M = {}

local sessions = require('chat.sessions')
local windows = require('chat.windows')
local formatter = require('chat.formatter')
local chat_bridge = require('chat.bridge')

local previewer = require('picker.previewer.buffer')

--- Highlight ranges of a `[platform] [session] …` header.
---
--- Computed instead of hard-coded: a fixed offset assumed a session id of a
--- fixed length, so a longer id (Lark's `lark-oc_…`) left the last bracket
--- unhighlighted.
--- @param platform string
--- @param session string
--- @return table[] { start, stop, group }
local function header_highlight(platform, session)
  local p_open = 0
  local p_close = #platform + 1
  local s_open = #platform + 3
  local s_close = #platform + #session + 4
  return {
    -- highlight of square brackets
    { p_open, p_open + 1, 'Comment' },
    { p_close, p_close + 1, 'Comment' },
    { s_open, s_open + 1, 'Comment' },
    { s_close, s_close + 1, 'Comment' },
    --- highlight of the platform name
    { p_open + 1, p_close, 'String' },
    --- highlight of the session id
    { s_open + 1, s_close, 'Comment' },
  }
end

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

--- Integration modules, sorted by name for a stable list order.
--- @return string[]
local function integration_names()
  return vim.fn.sort(vim.tbl_filter(function(t)
    return t ~= 'init'
  end, vim.tbl_map(function(t)
    return vim.fn.fnamemodify(t, ':t:r')
  end, vim.api.nvim_get_runtime_file('lua/chat/integrations/*.lua', true))))
end

function M.get()
  local items = {}
  for _, platform in ipairs(integration_names()) do
    local integration = chat_bridge.caps(platform)
    if integration then
      -- Every session the platform can reach, per-chat bindings included.
      -- `session()` alone only reports the platform-level (main chat) binding,
      -- so Lark's p2p containers never showed up here.
      for _, session in ipairs(chat_bridge.bound_sessions(platform)) do
        if sessions.exists(session) then
          local messages = sessions.get_messages(session)
          if #messages > 1 then
            -- Prefer the session title, like the plain session picker does.
            -- Reading only the first message ignored any title set by
            -- `set_session_title()` (or auto-generated), so integrated
            -- sessions never showed one.
            local title = sessions.get_session_title(session)
            local str
            if title and title ~= '' then
              str = title
            else
              str = first_non_empty_line(messages[1].content)
            end

            if str then
              table.insert(items, {
                str = string.format('[%s] [%s] %s', platform, session, str),
                value = session,
                highlight = header_highlight(platform, session),
              })
            end
          end
        end
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

