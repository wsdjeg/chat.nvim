local M = {}

local config = require('chat.config')
local sessions = require('chat.sessions')
local log = require('chat.log')

local winhighlight = 'NormalFloat:Normal,FloatBorder:WinSeparator'
local prompt_win = -1
local prompt_buf = -1
local result_win = -1
local result_buf = -1
local requestObj = {}

function requestObj.on_stream(chunk)
  if vim.api.nvim_buf_is_valid(result_buf) then
    if chunk.content then
      local last_line =
        vim.api.nvim_buf_get_lines(result_buf, -2, -1, false)[1]
      local lines = vim.split(chunk.content, '\n')
      lines[1] = last_line .. lines[1]
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
      if last_line == '' then
        last_line = '> '
      end
      local lines = vim.split(chunk.reasoning_content, '\n')
      lines[1] = last_line .. lines[1]
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

local function on_api_error(session, error) end
-- local function handle_api_error(error_obj, session, requestObj, id)
--   local error_msg = error_obj.message or "Unknown error"
--   local error_code = error_obj.code or error_obj.type or "unknown"
--
--   vim.notify("API Error (" .. error_code .. "): " .. error_msg, vim.log.levels.ERROR)
--
--   if session == requestObj.session then
--     requestObj.on_error({
--       message = error_msg,
--       code = error_code,
--       type = error_obj.type,
--       param = error_obj.param
--     })
--   end
--   sessions.clear_progress_session(id)
-- end

-- on_stdout 被每一个 request job 的 stdout 回调，
-- 根据 ID 判断是哪一个 request，并且更新当前 session
-- 的窗口内容。
function requestObj.on_stdout(id, data)
  vim.schedule(function()
    local session = sessions.get_progress_session(id)
    for _, line in ipairs(data) do
      log.info(line)
      if line == 'data: [DONE]' then
        if session == requestObj.session then
          requestObj.on_complete(sessions.get_progress_usage(id))
        end
      elseif vim.startswith(line, 'data: ') then
        local text = string.sub(line, 7)
        local ok, chuck = pcall(vim.json.decode, text)
        if not ok then
          -- log error
        elseif
          chuck.choices
          and #chuck.choices > 0
          and chuck.choices[1].delta.tool_calls
        then
          log.info('handle tool_calls chunk')
          for _, tool_call in ipairs(chuck.choices[1].delta.tool_calls) do
            sessions.on_progress_tool_call(id, tool_call)
          end
        elseif
          chuck.choices
          and #chuck.choices > 0
          and chuck.choices[1].finish_reason == 'tool_calls'
        then
          log.info('handle tool_calls finish_reason')
          sessions.on_progress_tool_call_done(id)
        elseif
          chuck.choices
          and #chuck.choices > 0
          and chuck.choices[1].delta.reasoning_content ~= vim.NIL
        then
          local content = chuck.choices[1].delta.reasoning_content
          if content and content ~= vim.NIL then
            if session == requestObj.session then
              requestObj.on_stream({
                reasoning_content = content,
              })
            end
            sessions.on_progress_reasoning_content(id, content)
          end
        elseif
          chuck.choices
          and #chuck.choices > 0
          and chuck.choices[1].delta.content ~= ''
        then
          local content = chuck.choices[1].delta.content
          if content and content ~= vim.NIL then
            if session == requestObj.session then
              requestObj.on_stream({
                content = content,
              })
            end
            sessions.on_progress(id, content)
          end
        end
        if chuck.usage and chuck.usage ~= vim.NIL then
          log.info('handle usage')
          sessions.set_progress_usage(id, chuck.usage)
        end
      elseif vim.startswith(line, '{"error":') then
        local ok, chuck = pcall(vim.json.decode, line)
        if ok and chuck.error then
          local error_msg = chuck.error.message or 'Unknown error'
          local error_code = chuck.error.code or chuck.type or 'unknown'
          if session == requestObj.session then
            local message = {
              '',
              string.format(
                '[%s] ❌ : API Error (%s): %s',
                os.date('%H:%M'),
                error_code,
                error_msg
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
    end
  end)
end
function M.on_tool_call_done(session, func)
  if session == requestObj.session then
    local message = {
      '',
      string.format(
        '[%s] ] 🤖 Bot:  tool_call done: %s',
        os.date('%H:%M'),
        func
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
    local ok, provider =
      pcall(require, 'chat.providers.' .. config.config.provider)
    if ok then
      provider.request(requestObj)
    end
  end
end
function M.on_tool_call_start(session, func)
  if session == requestObj.session then
    local message = {
      '',
      string.format(
        '[%s] ] 🤖 Bot:  tool_call start: %s',
        os.date('%H:%M'),
        func
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

function M.on_tool_call_error(session, err)
  if session == requestObj.session then
    local message = {
      '',
      string.format('[%s] ❌ : Tool Error: %s', os.date('%H:%M'), err),
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
  if requestObj.session == session then
    if signal == 2 then
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
  sessions.on_progress_done(id, code, signal)
end

function M.test(text)
  requestObj.on_stream({
    content = text,
  })
end

function requestObj.on_complete(usage)
  local complete_str = '------ ✅ 已完成 ------'
  if usage then
    -- ```json
    -- {
    --   "id": "chatcmpl-xxx",
    --   "object": "chat.completion",
    --   "created": 1234567890,
    --   "model": "deepseek-chat",
    --   "choices": [...],
    --   "usage": {
    --     "prompt_tokens": 100,      // 输入token数
    --     "completion_tokens": 200,  // 输出token数
    --     "total_tokens": 300        // 总token数
    --   }
    -- }
    -- ```
    complete_str = complete_str
      .. string.format(
        ' token usage: Input %d, Output %d, Total %d',
        usage.prompt_tokens,
        usage.completion_tokens,
        usage.total_tokens
      )
  end
  local message = {
    '',
    '[' .. os.date('%H:%M') .. '] 🤖 Bot: ' .. complete_str,
    '',
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

function M.close()
  if vim.api.nvim_win_is_valid(prompt_win) then
    vim.api.nvim_win_close(prompt_win, true)
  end
  if vim.api.nvim_win_is_valid(result_win) then
    vim.api.nvim_win_close(result_win, true)
  end
end

function M.generate_message(message, time)
  if message.role == 'assistant' then
    local msg = { '[' .. os.date('%H:%M', time) .. '] 🤖 Bot:', '' }
    for _, line in ipairs(vim.split(message.content, '\n')) do
      table.insert(msg, line)
    end
    return msg
  elseif message.role == 'user' then
    local content = vim.split(message.content, '\n')
    local msg =
      { '[' .. os.date('%H:%M', time) .. '] 👤 You:' .. content[1] }
    if #content > 1 then
      for i = 2, #content do
        table.insert(msg, content[i])
      end
    end
    table.insert(msg, '')
    return msg
  end
end

function M.generate_buffer(messages)
  local lines = {}
  for _, m in ipairs(messages) do
    for _, l in ipairs(M.generate_message(m)) do
      table.insert(lines, l)
    end
  end
  return lines
end

function M.set_model(model)
  if vim.api.nvim_win_is_valid(prompt_win) then
    vim.api.nvim_win_set_config(prompt_win, {
      title = ' Input ' .. string.format(
        '( %s %s)',
        config.config.provider,
        config.config.model
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
  if not requestObj.session then
    requestObj.session, requestObj.messages = sessions.new()
  end
  if opt and opt.session and opt.session ~= requestObj.session then
    requestObj.session = opt.session
    requestObj.messages = require('chat.sessions').get_messages(opt.session)
    if vim.api.nvim_buf_is_valid(result_buf) then
      vim.api.nvim_buf_set_lines(
        result_buf,
        0,
        -1,
        false,
        M.generate_buffer(requestObj.messages)
      )
      if sessions.is_in_progress(requestObj.session) then
        local message = sessions.get_progress_message(requestObj.session)
        if message then
          local lines = { '' }
          for _, l in
            ipairs(
              M.generate_message({ role = 'assistant', content = message })
            )
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
    vim.api.nvim_buf_set_keymap(result_buf, 'n', '<Tab>', '', {
      callback = function()
        vim.api.nvim_set_current_win(prompt_win)
      end,
    })
    if #requestObj.messages > 0 then
      vim.api.nvim_buf_set_lines(
        result_buf,
        0,
        -1,
        false,
        M.generate_buffer(requestObj.messages)
      )
    end
    if sessions.is_in_progress(requestObj.session) then
      local message = sessions.get_progress_message(requestObj.session)
      if message then
        local lines = { '' }
        for _, l in
          ipairs(
            M.generate_message({ role = 'assistant', content = message })
          )
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
    vim.api.nvim_set_option_value('wrap', true, { win = result_win })
  end

  if not vim.api.nvim_buf_is_valid(prompt_buf) then
    prompt_buf = vim.api.nvim_create_buf(false, false)
    vim.api.nvim_set_option_value('buftype', 'nofile', { buf = prompt_buf })
    --- 回车这操作是进行发送请求，需要判断
    --- 当前session，有没有正在进行的请求未完成？
    vim.api.nvim_buf_set_keymap(prompt_buf, 'n', '<Enter>', '', {
      callback = function()
        local content = vim.api.nvim_buf_get_lines(prompt_buf, 0, -1, false)
        if #content == 1 and content[1] == '' then
          return
        else
          if sessions.is_in_progress(requestObj.session) then
            log.notify(
              { 'Request in progress.', 'Press Ctrl-C to cancel.' },
              'WarningMsg'
            )
            return
          end
          local message =
            { '[' .. os.date('%H:%M') .. '] 👤 You:' .. content[1] }
          if #content > 1 then
            for i = 2, #content do
              table.insert(message, content[i])
            end
          end
          table.insert(message, '')
          table.insert(
            message,
            '[' .. os.date('%H:%M') .. '] 🤖 Bot: thinking ...'
          )
          table.insert(message, '')
          table.insert(message, '')
          vim.api.nvim_buf_set_lines(result_buf, -1, -1, false, message)
          vim.api.nvim_win_set_cursor(
            result_win,
            { vim.api.nvim_buf_line_count(result_buf), 0 }
          )
          vim.api.nvim_buf_set_lines(prompt_buf, 0, -1, false, {})
        end
        if type(config.config.api_key) == 'string' then
          requestObj.api_key = config.config.api_key
        elseif type(config.config.api_key) == 'table' then
          requestObj.api_key = config.config.api_key[config.config.provider]
        end
        local ok, provider =
          pcall(require, 'chat.providers.' .. config.config.provider)
        if ok then
          table.insert(
            requestObj.messages,
            { role = 'user', content = table.concat(content, '\n') }
          )
          requestObj.model = config.config.model
          provider.request(requestObj)
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
        require('chat.sessions').cancel_progress(requestObj.session)
      end,
    })
    vim.api.nvim_buf_set_keymap(prompt_buf, 'n', 'r', '', {
      callback = function()
        if sessions.is_in_progress(requestObj.session) then
          log.notify('Request is in progress.')
          return
        end
        local ok, provider =
          pcall(require, 'chat.providers.' .. config.config.provider)
        if ok then
          if
            #requestObj.messages > 0
            and requestObj.messages[#requestObj.messages].role == 'user'
          then
            local message = {}
            table.insert(message, '')
            table.insert(
              message,
              '[' .. os.date('%H:%M') .. '] 🤖 Bot: thinking ...'
            )
            table.insert(message, '')
            table.insert(message, '')
            vim.api.nvim_buf_set_lines(result_buf, -1, -1, false, message)
            requestObj.model = config.config.model
            provider.request(requestObj)
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
        '( %s %s)',
        config.config.provider,
        config.config.model
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
  end
end

return M
