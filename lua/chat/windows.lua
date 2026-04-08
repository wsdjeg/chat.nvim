local M = {}

local config = require('chat.config')
local sessions = require('chat.sessions')
local log = require('chat.log')
local formatter = require('chat.formatter')
local spinners = require('chat.spinners')
local protocol = require('chat.protocol')
local queue = require('chat.queue')
local integrations = require('chat.integrations')
local util = require('chat.util')

local current_session

local winhighlight = 'NormalFloat:Normal,FloatBorder:WinSeparator'
local prompt_win = -1
local prompt_buf = -1
local result_win = -1
local result_buf = -1

function M.set_result_win_title(text)
  if vim.api.nvim_win_is_valid(result_win) then
    local total, prompt, complete = sessions.get_total_tokens(current_session)

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

local function auto_scroll()
  if config.config.auto_scroll then
    if
      vim.api.nvim_buf_is_valid(result_buf)
      and vim.api.nvim_win_is_valid(result_win)
    then
      return vim.api.nvim_win_get_cursor(result_win)[1]
        == vim.api.nvim_buf_line_count(result_buf)
    end
  end
end

local function scroll_window()
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

-- Helper functions
local function validate_api_key()
  if
    (
      type(config.config.api_key) == 'table'
      and vim.tbl_isempty(config.config.api_key)
    )
    or (
      type(config.config.api_key) == 'string'
      and #config.config.api_key == 0
    )
  then
    log.notify('api_key is required!', 'WarningMsg')
    return false
  end
  return true
end

function M.push_text(chunk)
  if vim.api.nvim_buf_is_valid(result_buf) then
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
    if auto_scroll() then
      vim.api.nvim_buf_set_lines(result_buf, -2, -1, false, lines)
      scroll_window()
    else
      vim.api.nvim_buf_set_lines(result_buf, -2, -1, false, lines)
    end
  end
end

function M.on_message(session, message)
  if session == current_session then
    local need_scroll = auto_scroll()
    if vim.api.nvim_buf_is_valid(result_buf) then
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
    end
    if need_scroll then
      scroll_window()
    end
  end
end

function M.on_tool_call_done(session, messages)
  if session == current_session then
    local need_scroll = auto_scroll()
    for _, message in ipairs(messages) do
      if vim.api.nvim_buf_is_valid(result_buf) then
        vim.api.nvim_buf_set_lines(
          result_buf,
          -1,
          -1,
          false,
          formatter.generate_message(message, session)
        )
      end
    end
    if need_scroll then
      scroll_window()
    end
  end
end

function M.on_tool_call_start(session, message)
  if session == current_session then
    if vim.api.nvim_buf_is_valid(result_buf) then
      local need_scroll = auto_scroll()
      local lines = formatter.generate_message(message, session)

      if vim.api.nvim_buf_get_lines(result_buf, -2, -1, false)[1] ~= '' then
        vim.api.nvim_buf_set_lines(result_buf, -1, -1, false, { '' })
      end
      vim.api.nvim_buf_set_lines(result_buf, -1, -1, false, lines)

      if need_scroll then
        scroll_window()
      end
    end
  end
end

function M.close()
  if vim.api.nvim_win_is_valid(prompt_win) then
    vim.api.nvim_win_close(prompt_win, true)
  end
  if vim.api.nvim_win_is_valid(result_win) then
    vim.api.nvim_win_close(result_win, true)
  end
end

function M.redraw_title()
  if vim.api.nvim_win_is_valid(prompt_win) then
    local session_integrations =
      integrations.get_integrations(current_session)
    local ins = ''
    for _, i in ipairs(session_integrations) do
      ins = ins .. '| ' .. i .. ' '
    end
    vim.api.nvim_win_set_config(prompt_win, {
      title = {
        { '', config.config.highlights.title_badge },
        {
          ' Input ' .. string.format(
            '| %s %s | %s %s',
            sessions.get_session_provider(current_session),
            sessions.get_session_model(current_session),
            sessions.getcwd(current_session),
            ins
          ),
          config.config.highlights.title,
        },
        { '', config.config.highlights.title_badge },
      },
      title_pos = 'center',
    })
  end
end

function M.open(opt)
  if not validate_api_key() then
    return
  end
  if not current_session then
    current_session = sessions.new()
  end
  if opt and opt.cwd then
    if sessions.is_in_progress(current_session) then
      require('chat.log').notify(
        'session is in progress, can not change cwd.',
        'WarningMsg'
      )
    else
      sessions.change_cwd(current_session, opt.cwd)
    end
  end
  if
    (opt and opt.redraw)
    or (opt and opt.session and opt.session ~= current_session)
  then
    current_session = (opt.session or current_session)
    M.render_result_buf()
  end
  local start_row = math.floor(vim.o.lines * (1 - config.config.height) / 2)
  local start_col = math.floor(vim.o.columns * (1 - config.config.width) / 2)
  local screen_height = math.floor(vim.o.lines * config.config.height)
  local screen_width = math.floor(vim.o.columns * config.config.width)
  if not vim.api.nvim_buf_is_valid(result_buf) then
    result_buf = vim.api.nvim_create_buf(false, false)
    vim.api.nvim_set_option_value('buftype', 'nofile', { buf = result_buf })
    vim.treesitter.start(result_buf, 'markdown')
    vim.api.nvim_buf_set_keymap(result_buf, 'n', 'q', '', {
      callback = M.close,
      silent = true,
    })
    vim.api.nvim_buf_set_keymap(result_buf, 'n', '<C-o>', '<Nop>', {})
    vim.api.nvim_buf_set_keymap(result_buf, 'n', '<Tab>', '', {
      callback = function()
        if vim.api.nvim_win_is_valid(prompt_win) then
          vim.api.nvim_set_current_win(prompt_win)
        end
      end,
    })
    local messages = sessions.get_messages(current_session)
    if #messages > 0 then
      vim.api.nvim_buf_set_lines(
        result_buf,
        0,
        -1,
        false,
        formatter.generate_buffer(messages, current_session)
      )
    end
    if sessions.is_in_progress(current_session) then
      local reasoning_content =
        sessions.get_progress_reasoning_content(current_session)
      local message = sessions.get_progress_message(current_session)
      if message or reasoning_content then
        local lines = { '' }
        for _, l in
          ipairs(formatter.generate_message({
            role = 'assistant',
            content = message,
            reasoning_content = reasoning_content,
          }, current_session))
        do
          table.insert(lines, l)
        end
        vim.api.nvim_buf_set_lines(result_buf, -1, -1, false, lines)
      end
    end
  end

  if not vim.api.nvim_win_is_valid(result_win) then
    result_win = vim.api.nvim_open_win(result_buf, false, {
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
  end

  if not vim.api.nvim_buf_is_valid(prompt_buf) then
    prompt_buf = vim.api.nvim_create_buf(false, false)
    vim.api.nvim_set_option_value('buftype', 'nofile', { buf = prompt_buf })
    vim.api.nvim_buf_set_keymap(prompt_buf, 'n', '<C-o>', '<Nop>', {})
    if vim.fn.exists(':Picker') == 2 then
      vim.api.nvim_buf_set_keymap(
        prompt_buf,
        'n',
        '<leader>fr',
        '<cmd>Picker chat<Cr>',
        { noremap = true, silent = true }
      )
      vim.api.nvim_buf_set_keymap(
        prompt_buf,
        'n',
        '<leader>fp',
        '<cmd>Picker chat_provider<Cr>',
        { noremap = true, silent = true }
      )
      vim.api.nvim_buf_set_keymap(
        prompt_buf,
        'n',
        '<leader>fm',
        '<cmd>Picker chat_model<Cr>',
        { noremap = true, silent = true }
      )
    end
    vim.api.nvim_buf_set_keymap(
      prompt_buf,
      'n',
      '<C-n>',
      '<cmd>Chat new<Cr>',
      { silent = true }
    )
    --- 回车这操作是进行发送请求，需要判断
    --- 当前session，有没有正在进行的请求未完成？
    vim.api.nvim_buf_set_keymap(prompt_buf, 'n', '<Enter>', '', {
      callback = function()
        local content = vim.api.nvim_buf_get_lines(prompt_buf, 0, -1, false)
        if #content == 1 and content[1] == '' then
          return
        else
          if sessions.is_in_progress(current_session) then
            log.notify(
              { 'Request in progress.', 'Press Ctrl-C to cancel.' },
              'WarningMsg'
            )
            return
          end
          local message = {
            role = 'user',
            content = table.concat(content, '\n'),
            created = os.time(),
          }
          sessions.append_message(current_session, message)
          M.on_message(current_session, message)
          vim.api.nvim_buf_set_lines(prompt_buf, 0, -1, false, {})
          local jobid = protocol.request({
            session = current_session,
            messages = sessions.get_request_messages(current_session),
          })
          if jobid and jobid > 0 then
            spinners.start()
            log.info('curl request jobid is ' .. jobid)
          else
            log.error('Failed to start request: jobid is nil or invalid')
          end
        end
      end,
      silent = true,
    })
    vim.api.nvim_buf_set_keymap(prompt_buf, 'n', 'q', '', {
      callback = M.close,
      silent = true,
    })
    vim.api.nvim_buf_set_keymap(prompt_buf, 'n', '<Tab>', '', {
      callback = function()
        if vim.api.nvim_win_is_valid(result_win) then
          vim.api.nvim_set_current_win(result_win)
        end
      end,
    })
    vim.api.nvim_buf_set_keymap(prompt_buf, 'n', '<C-c>', '', {
      callback = function()
        require('chat.sessions').cancel_progress(current_session)
      end,
    })
    vim.api.nvim_buf_set_keymap(
      prompt_buf,
      'n',
      '<M-h>',
      '<cmd>Chat prev<Cr>',
      { silent = true }
    )
    vim.api.nvim_buf_set_keymap(
      prompt_buf,
      'n',
      '<M-l>',
      '<cmd>Chat next<Cr>',
      { silent = true }
    )
    vim.api.nvim_buf_set_keymap(prompt_buf, 'n', 'r', '', {
      callback = function()
        if sessions.is_in_progress(current_session) then
          log.notify('Request is in progress.')
          return
        end
        local messages = sessions.get_request_messages(current_session)
        if #messages > 0 and messages[#messages].role ~= 'assistant' then
          local jobid = protocol.request({
            session = current_session,
            messages = messages,
          })
          if jobid > 0 then
            spinners.start()
          end
          log.info('curl request jobid is ' .. jobid)
        end
      end,
    })
  end
  if not vim.api.nvim_win_is_valid(prompt_win) then
    local session_integrations =
      integrations.get_integrations(current_session)
    local ins = ''
    for _, i in ipairs(session_integrations) do
      ins = ins .. '| ' .. i .. ' '
    end
    prompt_win = vim.api.nvim_open_win(prompt_buf, true, {
      relative = 'editor',
      border = config.config.border,
      title = {
        { '', config.config.highlights.title_badge },
        {
          ' Input ' .. string.format(
            '| %s %s | %s %s',
            sessions.get_session_provider(current_session),
            sessions.get_session_model(current_session),
            sessions.getcwd(current_session),
            ins
          ),
          config.config.highlights.title,
        },
        { '', config.config.highlights.title_badge },
      },
      title_pos = 'center',
      col = start_col,
      row = start_row + screen_height - 3,
      width = screen_width,
      height = 3,
    })
    vim.api.nvim_set_option_value(
      'winhighlight',
      winhighlight,
      { win = prompt_win }
    )
    vim.api.nvim_set_option_value('wrap', true, { win = prompt_win })
    vim.api.nvim_set_option_value('linebreak', false, { win = prompt_win })
    vim.api.nvim_set_option_value('number', true, { win = prompt_win })
    vim.api.nvim_set_option_value('list', false, { win = prompt_win })
  else
    if vim.api.nvim_win_get_buf(prompt_win) ~= prompt_buf then
      vim.api.nvim_win_set_buf(prompt_win, prompt_buf)
    end
    vim.api.nvim_set_current_win(prompt_win)
    M.redraw_title()
  end
  if sessions.is_in_progress(current_session) then
    spinners.start()
  else
    spinners.stop()
  end
  queue.start()
  if config.config.http.api_key ~= '' then
    require('chat.http').start()
  end

  require('chat.integrations').on_message(function(message)
    queue.push(message.session, message.content)
  end)
  require('chat.mcp').connect()
end

function M.current_session()
  return current_session
end

function M.send_message(session, content)
  if not content or not sessions.exists(session) then
    return
  end
  sessions.clear_cancelled(session)
  local msg = {
    role = 'user',
    content = content,
    created = os.time(),
  }
  sessions.append_message(session, msg)
  M.on_message(session, msg)
  local jobid = protocol.request({
    session = session,
    messages = sessions.get_request_messages(session),
  })
  if jobid > 0 and session == current_session then
    spinners.start()
  end
  log.info('curl request jobid is ' .. jobid)
end

function M.render_result_buf()
  if vim.api.nvim_buf_is_valid(result_buf) then
    vim.api.nvim_buf_set_lines(
      result_buf,
      0,
      -1,
      false,
      formatter.generate_buffer(
        require('chat.sessions').get_messages(current_session),
        current_session
      )
    )
    if sessions.is_in_progress(current_session) then
      local reasoning_content =
        sessions.get_progress_reasoning_content(current_session)
      local message = sessions.get_progress_message(current_session)
      if message or reasoning_content then
        local lines = { '' }
        for _, l in
          ipairs(formatter.generate_message({
            role = 'assistant',
            content = message,
            reasoning_content = reasoning_content,
          }, current_session))
        do
          table.insert(lines, l)
        end
        vim.api.nvim_buf_set_lines(result_buf, -1, -1, false, lines)
      end
    end
  end
end

return M
