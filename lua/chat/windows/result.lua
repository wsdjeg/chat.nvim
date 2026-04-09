local M = {}

local config = require('chat.config')
local sessions = require('chat.sessions')
local formatter = require('chat.formatter')
local util = require('chat.util')

-- Result window state
local result_win = -1
local result_buf = -1

-- Window highlight configuration
local winhighlight = 'NormalFloat:Normal,FloatBorder:WinSeparator'

function M.get_win()
  return result_win
end

function M.get_buf()
  return result_buf
end

function M.set_win(win)
  result_win = win
end

function M.set_buf(buf)
  result_buf = buf
end

function M.is_buf_valid()
  return vim.api.nvim_buf_is_valid(result_buf)
end

function M.set_title(text, session)
  if vim.api.nvim_win_is_valid(result_win) then
    local total, prompt, complete = sessions.get_total_tokens(session)
    local title = text

    if total > 0 then
      title = title
        .. ' | '
        .. string.format(
          'Tokens: %s (%s↑/%s↓)',
          util.format_number(total),
          util.format_number(prompt),
          util.format_number(complete)
        )
    end

    vim.api.nvim_win_set_config(result_win, {
      title = {
        { '', config.config.highlights.title_badge },
        { title, config.config.highlights.title },
        { '', config.config.highlights.title_badge },
      },
      title_pos = 'center',
    })
  end
end

function M.auto_scroll()
  if config.config.auto_scroll then
    if
      vim.api.nvim_buf_is_valid(result_buf)
      and vim.api.nvim_win_is_valid(result_win)
    then
      return vim.api.nvim_win_get_cursor(result_win)[1]
        == vim.api.nvim_buf_line_count(result_buf)
    end
  end
  return false
end

function M.scroll_to_bottom()
  if
    vim.api.nvim_win_is_valid(result_win)
    and vim.api.nvim_buf_is_valid(result_buf)
  then
    vim.api.nvim_win_set_cursor(
      result_win,
      { vim.api.nvim_buf_line_count(result_buf), 0 }
    )
  end
end

function M.push_text(chunk)
  if not vim.api.nvim_buf_is_valid(result_buf) then
    return
  end

  local last_line = vim.api.nvim_buf_get_lines(result_buf, -2, -1, false)[1]
  local lines = { last_line }

  if chunk.is_start then
    local thinking_lines = formatter.generate_message({
      role = 'assistant',
      created = os.time(),
      reasoning_content = '',
    })
    for _, v in ipairs(thinking_lines) do
      table.insert(lines, v)
    end
    if chunk.reasoning_content then
      table.insert(lines, '> ')
    else
      table.insert(lines, '')
    end
  end

  if chunk.reasoning_content then
    local rcs = vim.split(chunk.reasoning_content, '\n')
    lines[#lines] = lines[#lines] .. rcs[1]
    for i = 2, #rcs do
      table.insert(lines, '> ' .. rcs[i])
    end
  elseif chunk.content then
    local cs = vim.split(chunk.content, '\n')
    lines[#lines] = lines[#lines] .. cs[1]
    for i = 2, #cs do
      table.insert(lines, cs[i])
    end
  end

  if M.auto_scroll() then
    vim.api.nvim_buf_set_lines(result_buf, -2, -1, false, lines)
    M.scroll_to_bottom()
  else
    vim.api.nvim_buf_set_lines(result_buf, -2, -1, false, lines)
  end
end

function M.on_message(session, current_session, message)
  if session ~= current_session then
    return
  end

  local need_scroll = M.auto_scroll()
  if not vim.api.nvim_buf_is_valid(result_buf) then
    return
  end

  local line_count = vim.api.nvim_buf_line_count(result_buf)
  local start = -1
  if
    line_count == 1
    and vim.api.nvim_buf_get_lines(result_buf, 0, -1, false)[1] == ''
  then
    start = 0
  end

  if vim.api.nvim_buf_get_lines(result_buf, -2, -1, false)[1] ~= '' then
    vim.api.nvim_buf_set_lines(result_buf, -1, -1, false, { '' })
  end

  vim.api.nvim_buf_set_lines(
    result_buf,
    start,
    -1,
    false,
    formatter.generate_message(message, session)
  )

  if need_scroll then
    M.scroll_to_bottom()
  end
end

function M.on_tool_call_done(session, current_session, messages)
  if session ~= current_session then
    return
  end

  local need_scroll = M.auto_scroll()
  if not vim.api.nvim_buf_is_valid(result_buf) then
    return
  end

  for _, message in ipairs(messages) do
    vim.api.nvim_buf_set_lines(
      result_buf,
      -1,
      -1,
      false,
      formatter.generate_message(message, session)
    )
  end

  if need_scroll then
    M.scroll_to_bottom()
  end
end

function M.on_tool_call_start(session, current_session, message)
  if session ~= current_session then
    return
  end

  if not vim.api.nvim_buf_is_valid(result_buf) then
    return
  end

  local need_scroll = M.auto_scroll()
  local lines = formatter.generate_message(message, session)

  if vim.api.nvim_buf_get_lines(result_buf, -2, -1, false)[1] ~= '' then
    vim.api.nvim_buf_set_lines(result_buf, -1, -1, false, { '' })
  end

  vim.api.nvim_buf_set_lines(result_buf, -1, -1, false, lines)

  if need_scroll then
    M.scroll_to_bottom()
  end
end

function M.close()
  if vim.api.nvim_win_is_valid(result_win) then
    vim.api.nvim_win_close(result_win, true)
    result_win = -1
  end
  if vim.api.nvim_buf_is_valid(result_buf) then
    result_buf = -1
  end
end

function M.create_buffer(session)
  result_buf = vim.api.nvim_create_buf(false, false)
  vim.api.nvim_set_option_value('buftype', 'nofile', { buf = result_buf })
  vim.treesitter.start(result_buf, 'markdown')

  local messages = sessions.get_messages(session)
  if #messages > 0 then
    vim.api.nvim_buf_set_lines(
      result_buf,
      0,
      -1,
      false,
      formatter.generate_buffer(messages, session)
    )
  end

  if sessions.is_in_progress(session) then
    local reasoning_content = sessions.get_progress_reasoning_content(session)
    local message = sessions.get_progress_message(session)
    if message or reasoning_content then
      local lines = { '' }
      for _, l in
        ipairs(formatter.generate_message({
          role = 'assistant',
          content = message,
          reasoning_content = reasoning_content,
        }, session))
      do
        table.insert(lines, l)
      end
      vim.api.nvim_buf_set_lines(result_buf, -1, -1, false, lines)
    end
  end

  return result_buf
end

function M.open_window(buf, start_row, start_col, screen_height, screen_width)
  result_win = vim.api.nvim_open_win(buf, false, {
    relative = 'editor',
    row = start_row,
    col = start_col,
    height = screen_height - 5,
    width = screen_width,
    border = config.config.border,
    title = {
      { '', config.config.highlights.title_badge },
      { 'chat.nvim', config.config.highlights.title },
      { '', config.config.highlights.title_badge },
    },
    title_pos = 'center',
  })

  vim.api.nvim_set_option_value(
    'winhighlight',
    winhighlight,
    { win = result_win }
  )
  vim.fn.matchadd(
    'Comment',
    '^\\[[^]]*\\] [🤖👤❌]',
    10,
    -1,
    { window = result_win }
  )
  vim.api.nvim_set_option_value('wrap', true, { win = result_win })
  vim.api.nvim_set_option_value('linebreak', false, { win = result_win })
  vim.api.nvim_set_option_value('number', true, { win = result_win })
  vim.api.nvim_set_option_value('list', false, { win = result_win })

  return result_win
end

function M.render(session)
  if not vim.api.nvim_buf_is_valid(result_buf) then
    return
  end

  vim.api.nvim_buf_set_lines(
    result_buf,
    0,
    -1,
    false,
    formatter.generate_buffer(
      sessions.get_messages(session),
      session
    )
  )

  if sessions.is_in_progress(session) then
    local reasoning_content = sessions.get_progress_reasoning_content(session)
    local message = sessions.get_progress_message(session)
    if message or reasoning_content then
      local lines = { '' }
      for _, l in
        ipairs(formatter.generate_message({
          role = 'assistant',
          content = message,
          reasoning_content = reasoning_content,
        }, session))
      do
        table.insert(lines, l)
      end
      vim.api.nvim_buf_set_lines(result_buf, -1, -1, false, lines)
    end
  end
end

return M

