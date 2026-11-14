local M = {}

local config = require('chat.config')
local sessions = require('chat.sessions')
local integrations = require('chat.integrations')
local title = require('chat.windows.title')

-- Placeholder shown when the prompt buffer is empty. It is rendered as
-- virtual text only, so it never leaks into get_content().
M.placeholder = '输入消息...'

-- Plain placeholder highlight: used in Insert mode, where the prompt window
-- has no CursorLine to blend with.
local COMMENT_HL = 'Comment'

-- Prompt window state
local prompt_win = -1
local prompt_buf = -1
local placeholder_ns = vim.api.nvim_create_namespace('chat.nvim.prompt')

--- Pick the placeholder highlight group for the current editor state.
--- - Insert mode: plain Comment, because CursorLine is not drawn there.
--- - Normal mode with 'cursorline': dedicated group whose foreground matches
---   Comment and whose background matches CursorLine, so the placeholder does
---   not punch a hole into the cursor line.
--- - Normal mode without 'cursorline': plain Comment.
--- @return string highlight group name
function M.placeholder_hl()
  if vim.api.nvim_get_mode().mode:sub(1, 1) == 'i' then
    return COMMENT_HL
  end
  if
    vim.api.nvim_win_is_valid(prompt_win)
    and vim.api.nvim_get_option_value('cursorline', { win = prompt_win })
  then
    return config.config.highlights.placeholder or COMMENT_HL
  end
  return COMMENT_HL
end

--- Get the namespace used by the placeholder extmark (mainly for tests).
--- @return number
function M.get_placeholder_ns()
  return placeholder_ns
end

--- Build the labels shown as pills in the prompt window title.
-- The session title is intentionally left out: it is already shown in the
-- result window title, and both windows are stacked vertically, so repeating
-- it only eats horizontal space.
--
-- Three pills, same visual language as the result window:
--   1. `<provider> | <model>` (falls back to `chat.nvim`)
--   2. `<cwd>`
--   3. `<integration> | <integration>...`
--
-- Labels are padded with the spaces that fill the pill; blank ones are
-- skipped by `title.build`, so a session without integrations or cwd shows
-- fewer pills instead of empty badges.
-- @param session string session id
-- @return string|nil provider/model pill label
-- @return string|nil cwd pill label
-- @return string|nil integrations pill label
local function pill_labels(session)
  local head = {}
  local provider = sessions.get_session_provider(session) or ''
  if provider ~= '' then
    table.insert(head, provider)
  end
  local model = sessions.get_session_model(session) or ''
  if model ~= '' then
    table.insert(head, model)
  end
  if #head == 0 then
    table.insert(head, 'chat.nvim')
  end

  local cwd = vim.trim(sessions.getcwd(session) or '')

  local integration_labels = {}
  for _, i in ipairs(integrations.get_integrations(session) or {}) do
    table.insert(integration_labels, i)
  end

  return ' ' .. table.concat(head, ' | ') .. ' ',
    cwd ~= '' and (' ' .. cwd .. ' ') or nil,
    #integration_labels > 0
        and (' ' .. table.concat(integration_labels, ' | ') .. ' ')
      or nil
end

--- Build the plain title text, pills joined by ` | `.
--- Kept for callers/tests that only need the words, not the pill layout.
--- @param session string session id
--- @return string title text
function M.build_title(session)
  local provider, cwd, integration_label = pill_labels(session)
  local parts = { vim.trim(provider or '') }
  if cwd then
    table.insert(parts, vim.trim(cwd))
  end
  if integration_label then
    table.insert(parts, vim.trim(integration_label))
  end
  return table.concat(parts, ' | ')
end

--- Build the full title chunk list (three pills joined by border connectors).
--- @param session string session id
--- @return table[]
function M.build_title_chunks(session)
  return title.build(pill_labels(session))
end

--- Check whether the prompt buffer holds no user text.
--- @return boolean
local function is_empty()
  if not vim.api.nvim_buf_is_valid(prompt_buf) then
    return false
  end
  local lines = vim.api.nvim_buf_get_lines(prompt_buf, 0, -1, false)
  if #lines > 1 then
    return false
  end
  return lines[1] == ''
end

--- Draw or clear the placeholder virtual text.
function M.render_placeholder()
  if not vim.api.nvim_buf_is_valid(prompt_buf) then
    return
  end

  pcall(vim.api.nvim_buf_clear_namespace, prompt_buf, placeholder_ns, 0, -1)

  if not is_empty() then
    return
  end

  pcall(vim.api.nvim_buf_set_extmark, prompt_buf, placeholder_ns, 0, 0, {
    virt_text = { { M.placeholder, M.placeholder_hl() } },
    virt_text_pos = 'overlay',
  })
end

--- Refresh the placeholder whenever the prompt content, the mode, or the
--- 'cursorline' setting changes.
--- @param buf number buffer handle
local function attach_placeholder_autocmds(buf)
  local group = vim.api.nvim_create_augroup(
    'chat_nvim_prompt_' .. tostring(buf),
    { clear = true }
  )
  vim.api.nvim_create_autocmd({
    'TextChanged',
    'TextChangedI',
    'TextChangedP',
    'ModeChanged',
    'InsertEnter',
    'InsertLeave',
    'BufEnter',
    'WinEnter',
    'OptionSet',
  }, {
    group = group,
    buffer = buf,
    callback = function()
      M.render_placeholder()
    end,
  })
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

function M.redraw_title(session)
  if not vim.api.nvim_win_is_valid(prompt_win) then
    return
  end

  vim.api.nvim_win_set_config(prompt_win, {
    title = M.build_title_chunks(session),
    title_pos = 'center',
  })
end

function M.create_buffer()
  prompt_buf = vim.api.nvim_create_buf(false, false)
  vim.api.nvim_set_option_value('buftype', 'nofile', { buf = prompt_buf })
  attach_placeholder_autocmds(prompt_buf)
  M.render_placeholder()
  return prompt_buf
end

function M.open_window(buf, start_col, start_row, screen_width, session)
  prompt_win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor',
    border = config.config.border,
    title = M.build_title_chunks(session),
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

  M.render_placeholder()

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
    M.render_placeholder()
  end
end

return M

