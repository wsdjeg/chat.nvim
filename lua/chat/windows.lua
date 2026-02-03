local M = {}

local config = require('chat.config')
local sessions = require('chat.sessions')

local winhighlight = 'NormalFloat:Normal,FloatBorder:WinSeparator'
local prompt_win = -1
local prompt_buf = -1
local result_win = -1
local result_buf = -1
local requestObj = {}
requestObj.messages = {}

-- callback function is called on uv callback, we need schedule
requestObj.callback = function(result, error)
  vim.schedule(function()
    local message
    if not result then
      message = {
        string.format('[%s] ❌ Error:', os.date('%H:%M')),
        '',
      }

      local lines =
        vim.split(tostring(error or 'unknown error'), '\n', { plain = true })
      for _, v in ipairs(lines) do
        table.insert(message, v)
      end

      vim.api.nvim_buf_set_lines(result_buf, -4, -1, false, message)
      return
    end
    table.insert(requestObj.messages, result.choices[1].message)
    message = { '[' .. os.date('%H:%M') .. '] 🤖 Bot:', '' }
    local rst = vim.split(result.choices[1].message.content, '\n')
    for _, v in ipairs(rst) do
      table.insert(message, v)
    end
    vim.api.nvim_buf_set_lines(result_buf, -4, -1, false, message)
    sessions.write_cache(requestObj.session)
  end)
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

function M.open(opt)
  if #config.config.api_key == 0 then
    require('notify').notify('api_key is required!', 'WarningMsg')
    return
  end
  if opt and opt.session and opt.session ~= requestObj.session then
    requestObj.session = opt.session
    requestObj.messages = require('chat.sessions').get_messages(opt.session)
    if vim.api.nvim_buf_is_valid(result_buf) then
      if #requestObj.messages > 0 then
        vim.api.nvim_buf_set_lines(
          result_buf,
          0,
          -1,
          false,
          M.generate_buffer(requestObj.messages)
        )
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
      end
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
  end

  if not vim.api.nvim_win_is_valid(result_win) then
    result_win = vim.api.nvim_open_win(result_buf, false, {
      relative = 'editor',
      row = start_row,
      col = start_col,
      height = screen_height - 5,
      width = screen_width,
      border = config.config.border,
    })
    vim.api.nvim_set_option_value(
      'winhighlight',
      winhighlight,
      { win = result_win }
    )
  end

  if not vim.api.nvim_buf_is_valid(prompt_buf) then
    prompt_buf = vim.api.nvim_create_buf(false, false)
    vim.api.nvim_set_option_value('buftype', 'nofile', { buf = prompt_buf })
    vim.api.nvim_buf_set_keymap(prompt_buf, 'n', '<Enter>', '', {
      callback = function()
        local content = vim.api.nvim_buf_get_lines(prompt_buf, 0, -1, false)
        if #content == 1 and content[1] == '' then
          return
        else
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
        requestObj.api_key = config.config.api_key
        local ok, provider =
          pcall(require, 'chat.providers.' .. config.config.provider)
        if ok then
          if #requestObj.messages == 0 then
            requestObj.session, requestObj.messages = sessions.new()
          end
          table.insert(
            requestObj.messages,
            { role = 'user', content = table.concat(content, '\n') }
          )
          provider.request(requestObj)
        else
          requestObj.callback(
            nil,
            'failed to load provider:' .. config.config.provider
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
      end
    })
  end
  if not vim.api.nvim_win_is_valid(prompt_win) then
    prompt_win = vim.api.nvim_open_win(prompt_buf, true, {
      relative = 'editor',
      border = config.config.border,
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
    vim.api.nvim_set_current_win(prompt_win)
  end
end

return M
