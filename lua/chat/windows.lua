local M = {}

local config = require('chat.config')

local winhighlight = 'NormalFloat:Normal,FloatBorder:WinSeparator'
local prompt_win = -1
local prompt_buf = -1
local result_win = -1
local result_buf = -1
local requestObj = {}
requestObj.history = {}
requestObj.callback = function(result)
  table.insert(requestObj.history, result.choices[1].message)
  local message = { '[' .. os.date('%H:%M') .. '] 🤖 Bot:', '' }
  local rst = vim.split(result.choices[1].message.content, '\n')
  for _, v in ipairs(rst) do
    table.insert(message, v)
  end
  vim.api.nvim_buf_set_lines(result_buf, -4, -1, false, message)
end

function M.close()
  if vim.api.nvim_win_is_valid(prompt_win) then
    vim.api.nvim_win_close(prompt_win, true)
  end
  if vim.api.nvim_win_is_valid(result_win) then
    vim.api.nvim_win_close(result_win, true)
  end
end

function M.open()
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
  end

  if not vim.api.nvim_win_is_valid(result_win) then
    result_win = vim.api.nvim_open_win(result_buf, false, {
      relative = 'editor',
      row = start_row,
      col = start_col,
      height = screen_height - 5,
      width = screen_width,
      border = 'rounded',
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
        requestObj.content = table.concat(content)
        require('chat.providers.deepseek').request(requestObj)
      end,
      silent = true,
    })
    vim.api.nvim_buf_set_keymap(prompt_buf, 'n', 'q', '', {
      callback = M.close,
      silent = true,
    })
  end
  if not vim.api.nvim_win_is_valid(prompt_win) then
    prompt_win = vim.api.nvim_open_win(prompt_buf, true, {
      relative = 'editor',
      border = 'rounded',
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
  else
    vim.api.nvim_set_current_win(prompt_win)
  end
end

return M
