local M = {}

local config = require('chat.config')
local sessions = require('chat.sessions')
local tools = require('chat.tools')
local log = require('chat.log')

local current_session

local winhighlight = 'NormalFloat:Normal,FloatBorder:WinSeparator'
local prompt_win = -1
local prompt_buf = -1
local result_win = -1
local result_buf = -1
local requestObj = {}

-- 此函数只会被当前 session 的数据流调用。
-- 设定一个变量，分割 content and reasoning_content
local is_thinking = false
function requestObj.on_stream(chunk)
  if vim.api.nvim_buf_is_valid(result_buf) then
    if chunk.content then
      local last_line =
        vim.api.nvim_buf_get_lines(result_buf, -2, -1, false)[1]
      local lines = vim.split(chunk.content, '\n')
      if is_thinking then
        table.insert(lines, 1, '')
        table.insert(lines, 1, last_line)
        is_thinking = false
      else
        lines[1] = last_line .. lines[1]
      end
      vim.api.nvim_buf_set_lines(result_buf, -2, -1, false, lines)
      if vim.api.nvim_win_is_valid(result_win) then
        vim.api.nvim_win_set_cursor(
          result_win,
          { vim.api.nvim_buf_line_count(result_buf), 0 }
        )
      end
    elseif chunk.reasoning_content then
      local last_line =
        vim.api.nvim_buf_get_lines(result_buf, -2, -1, false)[1]
      local lines = vim.split(chunk.reasoning_content, '\n')
      if not is_thinking then
        local thinking_lines = M.generate_message({
          role = 'assistant',
          created = os.time(),
          reasoning_content = '',
        })
        table.insert(thinking_lines, 1, last_line)
        table.insert(thinking_lines, '')
        vim.api.nvim_buf_set_lines(result_buf, -2, -1, false, thinking_lines)
        lines[1] = '> ' .. lines[1]
        is_thinking = true
      else
        lines[1] = last_line .. lines[1]
      end
      for i = 2, #lines do
        lines[i] = '> ' .. lines[i]
      end
      vim.api.nvim_buf_set_lines(result_buf, -2, -1, false, lines)
      if vim.api.nvim_win_is_valid(result_win) then
        vim.api.nvim_win_set_cursor(
          result_win,
          { vim.api.nvim_buf_line_count(result_buf), 0 }
        )
      end
    end
  end
end

-- on_stdout 被每一个 request job 的 stdout 回调，
-- 根据 ID 判断是哪一个 request，并且更新当前 session
-- 的窗口内容。
function requestObj.on_stdout(id, data)
  vim.schedule(function()
    local session = sessions.get_progress_session(id)
    for _, line in ipairs(data) do
      if #line > 0 then
        log.info(line)
      end
      if line == 'data: [DONE]' then
        log.info('handle date DONE')
        if sessions == current_session then
          is_thinking = false
        end
        sessions.on_progress_done(id)
        requestObj.on_complete(session, id)
      elseif vim.startswith(line, 'data: ') then
        local text = string.sub(line, 7)
        local ok, chunk = pcall(vim.json.decode, text)
        if not ok then
          -- log error
        elseif
          chunk.choices
          and #chunk.choices > 0
          and chunk.choices[1].delta.tool_calls
        then
          log.info('handle tool_calls chunk')
          for _, tool_call in ipairs(chunk.choices[1].delta.tool_calls) do
            sessions.on_progress_tool_call(id, tool_call)
          end
        elseif
          chunk.choices
          and #chunk.choices > 0
          and chunk.choices[1].delta.reasoning_content
          and chunk.choices[1].delta.reasoning_content ~= vim.NIL
          and #chunk.choices[1].delta.reasoning_content > 0
        then
          log.info('handle reasoning_content')
          local content = chunk.choices[1].delta.reasoning_content
          if content and content ~= vim.NIL then
            if session == current_session then
              requestObj.on_stream({
                reasoning_content = content,
              })
            end
            sessions.on_progress_reasoning_content(id, content)
          end
        elseif
          chunk.choices
          and #chunk.choices > 0
          and chunk.choices[1].delta.content
          and chunk.choices[1].delta.content ~= vim.NIL
          and #chunk.choices[1].delta.content > 0
        then
          log.info('handle content')
          local content = chunk.choices[1].delta.content
          if content and content ~= vim.NIL then
            if session == current_session then
              requestObj.on_stream({
                content = content,
              })
            end
            sessions.on_progress(id, content)
          end
        end
        if chunk.usage and chunk.usage ~= vim.NIL then
          log.info('handle usage')
          sessions.set_progress_usage(id, chunk.usage)
        end
      elseif vim.startswith(line, '{"error":') then
        local ok, chunk = pcall(vim.json.decode, line)
        if ok and chunk.error then
          local error_msg = chunk.error.message or 'Unknown error'
          local error_code = chunk.error.code or chunk.type or 'unknown'
          local message = {
            error = string.format(
              'API Error (%s): %s',
              error_code,
              error_msg
            ),
            created = os.time(),
          }
          sessions.append_message(session, message)
          if session == current_session then
            if vim.api.nvim_buf_is_valid(result_buf) then
              vim.api.nvim_buf_set_lines(
                result_buf,
                -1,
                -1,
                false,
                M.generate_message(message, session)
              )
            end
            if vim.api.nvim_win_is_valid(result_win) then
              vim.api.nvim_win_set_cursor(
                result_win,
                { vim.api.nvim_buf_line_count(result_buf), 0 }
              )
            end
          end
        end
      end
    end
  end)
end
function M.on_tool_call_done(session, messages)
  if session == current_session then
    for _, message in ipairs(messages) do
      if vim.api.nvim_buf_is_valid(result_buf) then
        vim.api.nvim_buf_set_lines(
          result_buf,
          -1,
          -1,
          false,
          M.generate_message(message, session)
        )
      end
    end
    if vim.api.nvim_win_is_valid(result_win) then
      vim.api.nvim_win_set_cursor(
        result_win,
        { vim.api.nvim_buf_line_count(result_buf), 0 }
      )
    end
  end
  local ok, provider = pcall(
    require,
    'chat.providers.' .. sessions.get_session_provider(session)
  )
  if ok then
    provider.request({
      on_stdout = requestObj.on_stdout,
      on_stderr = requestObj.on_stderr,
      on_exit = requestObj.on_exit,
      session = session,
      messages = sessions.get_request_messages(session),
    })
  end
end

-- [08:42] 👤 You: test @read_file .stylua.toml
-- [08:42] 🤖 Bot: 🔧 Executing tool: read_file .stylua.toml...
-- [08:42] 🤖 Bot: ✅ Tool execution complete: read_file .stylua.toml (0.2s)
-- [08:42] 🤖 Bot: File content: ...

function M.on_tool_call_start(session, message)
  if session == current_session then
    local lines = M.generate_message(message, session)
    table.insert(lines, 1, '')
    if vim.api.nvim_buf_is_valid(result_buf) then
      vim.api.nvim_buf_set_lines(result_buf, -1, -1, false, lines)
    end
    if vim.api.nvim_win_is_valid(result_win) then
      vim.api.nvim_win_set_cursor(
        result_win,
        { vim.api.nvim_buf_line_count(result_buf), 0 }
      )
    end
  end
end

function requestObj.on_stderr(id, data)
  vim.schedule(function()
    for _, line in ipairs(data) do
      log.info(line)
    end
  end)
end

function requestObj.on_exit(id, code, signal)
  vim.schedule(function()
    log.info(string.format('job exit code %d signal %d', code, signal))
  end)
  local session = sessions.get_progress_session(id)
  sessions.on_progress_exit(id, code, signal)
  if current_session == session then
    if signal == 2 then
      is_thinking = false
      local message = {
        '',
        string.format(
          '[%s] ❌ : Request cancelled by user. Press r to retry.',
          os.date('%H:%M')
        ),
        '',
      }
      if vim.api.nvim_buf_is_valid(result_buf) then
        vim.api.nvim_buf_set_lines(result_buf, -1, -1, false, message)
      end
      if vim.api.nvim_win_is_valid(result_win) then
        vim.api.nvim_win_set_cursor(
          result_win,
          { vim.api.nvim_buf_line_count(result_buf), 0 }
        )
      end
    end
  end
end

function M.test(text)
  requestObj.on_stream({
    content = text,
  })
end

-- [08:42] 🤖 Bot: ✅ Completed • Time: 0.5s • Tokens: 701 (384↑/84↓)
-- Time 以后再加

function requestObj.on_complete(session, id)
  local usage = sessions.get_progress_usage(id)

  local message = {
    on_complete = true,
    usage = usage,
    created = os.time(),
  }

  sessions.append_message(session, message)

  if current_session == session then
    is_thinking = false
    if vim.api.nvim_buf_get_lines(result_buf, -2, -1, false)[1] ~= '' then
      vim.api.nvim_buf_set_lines(result_buf, -1, -1, false, { '' })
    end
    if vim.api.nvim_buf_is_valid(result_buf) then
      vim.api.nvim_buf_set_lines(
        result_buf,
        -1,
        -1,
        false,
        M.generate_message(message, session)
      )
    end
    if vim.api.nvim_win_is_valid(result_win) then
      vim.api.nvim_win_set_cursor(
        result_win,
        { vim.api.nvim_buf_line_count(result_buf), 0 }
      )
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

function M.generate_message(message, session)
  if message.role == 'assistant' and message.tool_calls then
    local msg = {}
    if message.reasoning_content then
      table.insert(
        msg,
        '['
          .. os.date(config.config.strftime, message.created)
          .. '] 🤖 Bot:'
          .. ((message.reasoning_content and ' thinking ...') or '')
      )
      table.insert(msg, '')
    end
    if message.reasoning_content then
      for _, line in ipairs(vim.split(message.reasoning_content, '\n')) do
        table.insert(msg, '> ' .. line)
      end
      table.insert(msg, '')
    end
    for i = 1, #message.tool_calls do
      table.insert(
        msg,
        string.format(
          '[%s] 🤖 Bot: 🔧 Executing tool: %s',
          os.date(config.config.strftime, message.created),
          tools.info(
            message.tool_calls[i],
            { cwd = sessions.getcwd(session) }
          )
        )
      )
      table.insert(msg, '')
    end

    return msg
  elseif message.role == 'assistant' then
    local msg = {
      '['
        .. os.date(config.config.strftime, message.created)
        .. '] 🤖 Bot:'
        .. ((message.reasoning_content and ' thinking ...') or ''),
      '',
    }
    if message.reasoning_content and #message.reasoning_content > 0 then
      for _, line in ipairs(vim.split(message.reasoning_content, '\n')) do
        table.insert(msg, '> ' .. line)
      end
      table.insert(msg, '')
    end
    if message.content then
      for _, line in ipairs(vim.split(message.content, '\n')) do
        table.insert(msg, line)
      end
      table.insert(msg, '')
    end
    return msg
  elseif message.role == 'user' then
    local content = vim.split(message.content, '\n')
    local msg = {
      '['
        .. os.date(config.config.strftime, message.created)
        .. '] 👤 You: '
        .. content[1],
    }
    if #content > 1 then
      for i = 2, #content do
        table.insert(msg, content[i])
      end
    end
    table.insert(msg, '')
    return msg
  elseif message.role == 'tool' then
    if message.tool_call_state and message.tool_call_state.error then
      local msg = vim.split(
        string.format(
          '[%s] ❌ : Tool Error: %s',
          os.date(config.config.strftime, message.created),
          message.tool_call_state.error
        ),
        '\n'
      )
      table.insert(msg, '')
      return msg
    else
      return {
        string.format(
          '[%s] 🤖 Bot: ✅ Tool execution complete: %s',
          os.date(config.config.strftime, message.created),
          (message.tool_call_state and message.tool_call_state.name) or ''
        ),
        '',
      }
    end
  elseif message.content and message.role ~= 'tool' then
    return vim.split(message.content, '\n')
  elseif message.on_complete then
    local complete_str = ' ✅ Completed'
    if message.usage then
      complete_str = complete_str
        .. string.format(
          ' • Tokens: %d (%d↑/%d↓)',
          message.usage.total_tokens,
          message.usage.prompt_tokens,
          message.usage.completion_tokens
        )
    end
    return {
      '['
        .. os.date(config.config.strftime, message.created)
        .. '] 🤖 Bot:'
        .. complete_str,
      '',
    }
  elseif message.error then
    return {
      '',
      string.format(
        '[%s] ❌ : %s',
        os.date(config.config.strftime, message.created),
        message.error
      ),
      '',
    }
  else
    return {}
  end
end

function M.generate_buffer(messages, session)
  local lines = {}
  for _, m in ipairs(messages) do
    for _, l in ipairs(M.generate_message(m, session)) do
      table.insert(lines, l)
    end
  end
  return lines
end

function M.redraw_title()
  if vim.api.nvim_win_is_valid(prompt_win) then
    vim.api.nvim_win_set_config(prompt_win, {
      title = ' Input ' .. string.format(
        '| %s %s | %s ',
        sessions.get_session_provider(current_session),
        sessions.get_session_model(current_session),
        sessions.getcwd(current_session)
      ),
    })
  end
end

function M.open(opt)
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
    if vim.api.nvim_buf_is_valid(result_buf) then
      vim.api.nvim_buf_set_lines(
        result_buf,
        0,
        -1,
        false,
        M.generate_buffer(
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
            ipairs(M.generate_message({
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
    vim.api.nvim_buf_set_keymap(prompt_buf, 'n', '<C-o>', '<Nop>', {})
    vim.api.nvim_buf_set_keymap(result_buf, 'n', '<Tab>', '', {
      callback = function()
        vim.api.nvim_set_current_win(prompt_win)
      end,
    })
    local messages = sessions.get_messages(current_session)
    if #messages > 0 then
      vim.api.nvim_buf_set_lines(
        result_buf,
        0,
        -1,
        false,
        M.generate_buffer(messages, current_session)
      )
    end
    if sessions.is_in_progress(current_session) then
      local reasoning_content =
        sessions.get_progress_reasoning_content(current_session)
      local message = sessions.get_progress_message(current_session)
      if message or reasoning_content then
        local lines = { '' }
        for _, l in
          ipairs(M.generate_message({
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
      title = ' chat.nvim ',
      title_pos = 'center',
    })
    vim.api.nvim_set_option_value(
      'winhighlight',
      winhighlight,
      { win = result_win }
    )
    vim.fn.matchadd(
      'Comment',
      '^\\[[^]]*\\] [🤖👤]',
      10,
      -1,
      { window = result_win }
    )
    vim.api.nvim_set_option_value('wrap', true, { win = result_win })
  end

  if not vim.api.nvim_buf_is_valid(prompt_buf) then
    prompt_buf = vim.api.nvim_create_buf(false, false)
    vim.api.nvim_set_option_value('buftype', 'nofile', { buf = prompt_buf })
    vim.api.nvim_buf_set_keymap(prompt_buf, 'n', '<C-o>', '<Nop>', {})
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
            '['
              .. os.date(config.config.strftime)
              .. '] 👤 You:'
              .. content[1],
          }
          if #content > 1 then
            for i = 2, #content do
              table.insert(message, content[i])
            end
          end
          table.insert(message, '')
          if vim.api.nvim_buf_line_count(result_buf) == 1 then
            vim.api.nvim_buf_set_lines(result_buf, 0, -1, false, message)
          else
            vim.api.nvim_buf_set_lines(result_buf, -1, -1, false, message)
          end
          vim.api.nvim_win_set_cursor(
            result_win,
            { vim.api.nvim_buf_line_count(result_buf), 0 }
          )
          vim.api.nvim_buf_set_lines(prompt_buf, 0, -1, false, {})
        end
        local ok, provider = pcall(
          require,
          'chat.providers.' .. sessions.get_session_provider(current_session)
        )
        if ok then
          sessions.append_message(current_session, {
            role = 'user',
            content = table.concat(content, '\n'),
            created = os.time(),
          })
          requestObj.model = config.config.model
          local jobid = provider.request({
            on_stdout = requestObj.on_stdout,
            on_stderr = requestObj.on_stderr,
            on_exit = requestObj.on_exit,
            session = current_session,
            messages = sessions.get_request_messages(current_session),
          })
          log.info('curl request jobid is ' .. jobid)
        else
          log.notify(
            'failed to load provider:' .. config.config.provider,
            'WarningMsg'
          )
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
        vim.api.nvim_set_current_win(result_win)
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
        local ok, provider = pcall(
          require,
          'chat.providers.' .. sessions.get_session_provider(current_session)
        )
        if ok then
          local messages = sessions.get_request_messages(current_session)
          if #messages > 0 and messages[#messages].role ~= 'assistant' then
            local message = {}
            table.insert(message, '')
            table.insert(
              message,
              '['
                .. os.date(config.config.strftime)
                .. '] 🤖 Bot: thinking ...'
            )
            table.insert(message, '')
            table.insert(message, '')
            vim.api.nvim_buf_set_lines(result_buf, -1, -1, false, message)
            requestObj.model = config.config.model
            provider.request({
              on_stdout = requestObj.on_stdout,
              on_stderr = requestObj.on_stderr,
              on_exit = requestObj.on_exit,
              session = current_session,
              messages = messages,
            })
          end
        else
          log.notify(
            'failed to load provider:' .. config.config.provider,
            'WarningMsg'
          )
        end
      end,
    })
  end
  if not vim.api.nvim_win_is_valid(prompt_win) then
    prompt_win = vim.api.nvim_open_win(prompt_buf, true, {
      relative = 'editor',
      border = config.config.border,
      title = ' Input ' .. string.format(
        '| %s %s | %s ',
        sessions.get_session_provider(current_session),
        sessions.get_session_model(current_session),
        sessions.getcwd(current_session)
      ),
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
  else
    if vim.api.nvim_win_get_buf(prompt_win) ~= prompt_buf then
      vim.api.nvim_win_set_buf(prompt_win, prompt_buf)
    end
    vim.api.nvim_set_current_win(prompt_win)
    M.redraw_title()
  end
end

function M.current_session()
  return current_session
end

return M
