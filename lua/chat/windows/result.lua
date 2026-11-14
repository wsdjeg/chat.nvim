local M = {}

local config = require('chat.config')
local sessions = require('chat.sessions')
local formatter = require('chat.formatter')
local util = require('chat.util')
local usage_util = require('chat.usage')

-- Result window state
local result_win = -1
local result_buf = -1

-- Line-to-message mapping: { [msg_index] = { start_line, end_line } }
-- Updated on every render, used by delete_message_at_cursor
local message_line_map = {}

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

-- Decorative pill caps. Same glyphs the prompt window title uses, so both
-- windows share one visual language.
local TITLE_BADGE_LEFT = '\238\130\182'
local TITLE_BADGE_RIGHT = '\238\130\180'

--- Wrap one label into a pill: left badge + highlighted text + right badge.
--- @param label string text, already padded with the spaces that fill the pill
--- @return table[] title chunks
local function pill(label)
  local badge_hl = config.config.highlights.title_badge
  return {
    { TITLE_BADGE_LEFT, badge_hl },
    { label, config.config.highlights.title },
    { TITLE_BADGE_RIGHT, badge_hl },
  }
end

--- Build the result window title as separate pills.
--- 1. session title (falls back to `text`, e.g. "chat.nvim")
--- 2. cumulative tokens with the prompt↑ / completion↓ split
--- 3. prompt cache hit ratio
--- Pills 2 and 3 only appear once the session has usage, so a fresh session
--- shows a single clean pill. The cache pill is skipped when the provider
--- reported no cache numbers, matching the per-message footer.
--- @param session string Session ID
--- @param text string Fallback label for the first pill
--- @return table[] title chunks for vim.api.nvim_win_set_config
function M.build_title(session, text)
  local chunks = {}
  -- Gap between pills: drawn with the badge highlight so it stays neutral
  local gap = { ' ', config.config.highlights.title_badge }

  local session_title = vim.trim(sessions.get_session_title(session) or '')
  local label = session_title ~= '' and session_title or vim.trim(text or '')
  if label == '' then
    label = 'chat.nvim'
  end
  vim.list_extend(chunks, pill(' ' .. label .. ' '))

  local total, prompt, complete, cached = sessions.get_total_tokens(session)
  if total and total > 0 then
    table.insert(chunks, gap)
    vim.list_extend(
      chunks,
      pill(string.format(
        ' %s (%s↑/%s↓) ',
        util.format_number(total),
        util.format_number(prompt or 0),
        util.format_number(complete or 0)
      ))
    )

    -- Cache hit ratio: same normalization the per-message line uses, so
    -- DeepSeek/Anthropic payloads report a real percentage.
    if cached and cached > 0 then
      table.insert(chunks, gap)
      vim.list_extend(
        chunks,
        pill(string.format(
          ' 💾 %d%% ',
          math.floor(
            usage_util.hit_ratio({
              prompt_tokens = prompt or 0,
              cached_tokens = cached,
            }) * 100
          )
        ))
      )
    end
  end

  return chunks
end

function M.set_title(text, session)
  if vim.api.nvim_win_is_valid(result_win) then
    vim.api.nvim_win_set_config(result_win, {
      title = M.build_title(session, text),
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
    util.buf_set_lines(result_buf, -2, -1, lines)
    M.scroll_to_bottom()
  else
    util.buf_set_lines(result_buf, -2, -1, lines)
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
    util.buf_set_lines(result_buf, -1, -1, { '' })
  end

  util.buf_set_lines(
    result_buf,
    start,
    -1,
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
    util.buf_set_lines(
      result_buf,
      -1,
      -1,
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
    util.buf_set_lines(result_buf, -1, -1, { '' })
  end

  util.buf_set_lines(result_buf, -1, -1, lines)

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
  vim.api.nvim_set_option_value('modifiable', false, { buf = result_buf })
  vim.api.nvim_set_option_value('filetype', 'markdown', { buf = result_buf })
  vim.treesitter.start(result_buf, 'markdown')

  if config.config.render_markdown then
    vim.api.nvim_buf_call(result_buf, function()
      pcall(function()
        vim.cmd('RenderMarkdown buf_enable')
      end)
    end)
  end

  local messages = sessions.get_messages(session)
  if #messages > 0 then
    local lines, line_map =
      formatter.generate_buffer_with_map(messages, session)
    message_line_map = line_map
    util.buf_set_lines(result_buf, 0, -1, lines)
  else
    message_line_map = {}
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
      util.buf_set_lines(result_buf, -1, -1, lines)
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
    -- Initial title: only the first pill, tokens and cache pills are added
    -- later by set_title() once the session reports usage.
    title = pill(' chat.nvim '),
    title_pos = 'center',
  })

  vim.api.nvim_set_option_value(
    'winhighlight',
    config.config.winhighlight,
    { win = result_win }
  )
  vim.fn.matchadd(
    'Comment',
    '^\\[[^]]*\\] [🤖👤❌🔁]',
    10,
    -1,
    { window = result_win }
  )
  vim.api.nvim_set_option_value('wrap', true, { win = result_win })
  vim.api.nvim_set_option_value('linebreak', false, { win = result_win })
  vim.api.nvim_set_option_value('number', false, { win = result_win })
  vim.api.nvim_set_option_value('list', false, { win = result_win })
  vim.api.nvim_set_option_value('signcolumn', 'yes', { win = result_win })

  -- Scroll to bottom on initial open
  M.scroll_to_bottom()

  return result_win
end

function M.render(session)
  if not vim.api.nvim_buf_is_valid(result_buf) then
    return
  end

  local lines, line_map =
    formatter.generate_buffer_with_map(sessions.get_messages(session), session)
  message_line_map = line_map
  util.buf_set_lines(result_buf, 0, -1, lines)

  if sessions.is_in_progress(session) then
    local reasoning_content = sessions.get_progress_reasoning_content(session)
    local message = sessions.get_progress_message(session)
    if message or reasoning_content then
      local lines_progress = { '' }
      for _, l in
        ipairs(formatter.generate_message({
          role = 'assistant',
          content = message,
          reasoning_content = reasoning_content,
        }, session))
      do
        table.insert(lines_progress, l)
      end
      util.buf_set_lines(result_buf, -1, -1, lines_progress)
    end
  end

  -- Scroll to bottom after rendering new session content
  M.scroll_to_bottom()
end

--- Delete the message at the current cursor position in the result window.
--- Looks up the message index from the line-to-message mapping,
--- removes it from the session, and re-renders.
--- @param session string Session ID
--- @return boolean True if a message was deleted
function M.delete_message_at_cursor(session)
  if not vim.api.nvim_win_is_valid(result_win) then
    return false
  end

  local cursor = vim.api.nvim_win_get_cursor(result_win)
  local line = cursor[1]

  -- When streaming is in progress, the last displayed block is the SSE
  -- streaming content, which is not a stored message (not in message_line_map).
  -- Skip it - only allow deleting stored messages above the streaming content.
  if sessions.is_in_progress(session) then
    local last_end = 0
    for _, range in pairs(message_line_map) do
      if range.end_line > last_end then
        last_end = range.end_line
      end
    end
    if line > last_end then
      return false
    end
  end

  -- Find which message this line belongs to
  local msg_index = nil
  for i, range in ipairs(message_line_map) do
    if line >= range.start_line and line <= range.end_line then
      msg_index = i
      break
    end
  end

  if not msg_index then
    return false
  end

  -- Delete from session data
  sessions.delete_message(session, msg_index)
  require('chat.sessions.storage').write_cache(session)

  -- Re-render
  M.render(session)

  return true
end

return M

