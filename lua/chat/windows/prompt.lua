local M = {}

local config = require('chat.config')
local sessions = require('chat.sessions')
local integrations = require('chat.integrations')

-- Prompt window state
local prompt_win = -1
local prompt_buf = -1

--- Build the prompt window title text.
-- Format: `| <title> | <provider> | <model> | <cwd> <integrations>`
-- @param session string session id
-- @return string title text
local function build_title(session)
  local session_integrations = integrations.get_integrations(session) or {}
  local ins = ''
  for _, i in ipairs(session_integrations) do
    ins = ins .. '| ' .. i .. ' '
  end

  local title = sessions.get_session_title(session) or ''
  local title_part = ''
  if title ~= '' then
    title_part = title .. ' | '
  end

  local provider = sessions.get_session_provider(session) or ''
  local model = sessions.get_session_model(session) or ''
  local cwd = sessions.getcwd(session) or ''

  return ' Input '
    .. string.format(
      '| %s%s | %s | %s %s',
      title_part,
      provider,
      model,
      cwd,
      ins
    )
end

function M.get_win()
  return prompt_win
end

function M.get_buf()
  return prompt_buf
end

function M.set_win(win)
  prompt_win = win
end

function M.set_buf(buf)
  prompt_buf = buf
end

function M.is_valid()
  return vim.api.nvim_win_is_valid(prompt_win)
end

function M.is_buf_valid()
  return vim.api.nvim_buf_is_valid(prompt_buf)
end

function M.close()
  if vim.api.nvim_win_is_valid(prompt_win) then
    vim.api.nvim_win_close(prompt_win, true)
    prompt_win = -1
  end
  if vim.api.nvim_buf_is_valid(prompt_buf) then
    prompt_buf = -1
  end
end

function M.build_title(session)
  return build_title(session)
end

function M.redraw_title(session)
  if not vim.api.nvim_win_is_valid(prompt_win) then
    return
  end

  vim.api.nvim_win_set_config(prompt_win, {
    title = {
      { '', config.config.highlights.title_badge },
      { build_title(session), config.config.highlights.title },
      { '', config.config.highlights.title_badge },
    },
    title_pos = 'center',
  })
end

function M.create_buffer()
  prompt_buf = vim.api.nvim_create_buf(false, false)
  vim.api.nvim_set_option_value('buftype', 'nofile', { buf = prompt_buf })
  return prompt_buf
end

function M.open_window(buf, start_col, start_row, screen_width, session)
  prompt_win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor',
    border = config.config.border,
    title = {
      { '', config.config.highlights.title_badge },
      { build_title(session), config.config.highlights.title },
      { '', config.config.highlights.title_badge },
    },
    title_pos = 'center',
    col = start_col,
    row = start_row,
    width = screen_width,
    height = 3,
  })

  vim.api.nvim_set_option_value(
    'winhighlight',
    config.config.winhighlight,
    { win = prompt_win }
  )
  vim.api.nvim_set_option_value('wrap', true, { win = prompt_win })
  vim.api.nvim_set_option_value('linebreak', false, { win = prompt_win })
  vim.api.nvim_set_option_value('number', false, { win = prompt_win })
  vim.api.nvim_set_option_value('list', false, { win = prompt_win })
  vim.api.nvim_set_option_value('signcolumn', 'yes', { win = prompt_win })

  return prompt_win
end

function M.focus()
  if vim.api.nvim_win_is_valid(prompt_win) then
    vim.api.nvim_set_current_win(prompt_win)
  end
end

function M.get_content()
  if not vim.api.nvim_buf_is_valid(prompt_buf) then
    return {}
  end
  return vim.api.nvim_buf_get_lines(prompt_buf, 0, -1, false)
end

function M.clear()
  if vim.api.nvim_buf_is_valid(prompt_buf) then
    vim.api.nvim_buf_set_lines(prompt_buf, 0, -1, false, {})
  end
end

return M

