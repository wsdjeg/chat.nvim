local M = {}

local config = require('chat.config')
local sessions = require('chat.sessions')
local log = require('chat.log')
local spinners = require('chat.spinners')
local protocol = require('chat.protocol')
local queue = require('chat.queue')

-- Submodules
local result = require('chat.windows.result')
local prompt = require('chat.windows.prompt')
local keymaps = require('chat.windows.keymaps')

-- Session state
local current_session

-- Validate API key before opening
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

-- Close all windows
function M.close()
  result.close()
  prompt.close()
end

-- Open chat windows
function M.open(opt)
  if not validate_api_key() then
    return
  end

  -- Initialize or restore session
  if not current_session then
    current_session = sessions.new()
  end

  -- Handle cwd option
  if opt and opt.cwd then
    if sessions.is_in_progress(current_session) then
      log.notify(
        'session is in progress, can not change cwd.',
        'WarningMsg'
      )
    else
      sessions.change_cwd(current_session, opt.cwd)
    end
  end

  -- Handle session switch or redraw
  if
    (opt and opt.redraw)
    or (opt and opt.session and opt.session ~= current_session)
  then
    current_session = (opt.session or current_session)
    M.render_result_buf()
  end

  -- Calculate window position
  local start_row = math.floor(vim.o.lines * (1 - config.config.height) / 2)
  local start_col = math.floor(vim.o.columns * (1 - config.config.width) / 2)
  local screen_height = math.floor(vim.o.lines * config.config.height)
  local screen_width = math.floor(vim.o.columns * config.config.width)

  -- Create or restore result window
  if not result.is_buf_valid() then
    result.create_buffer(current_session)
    keymaps.setup_result_keymaps(result.get_buf(), {
      close_fn = M.close,
      focus_prompt_fn = prompt.focus,
    })
  end

  if not vim.api.nvim_win_is_valid(result.get_win()) then
    result.open_window(
      result.get_buf(),
      start_row,
      start_col,
      screen_height,
      screen_width
    )
  end

  -- Create or restore prompt window
  if not prompt.is_buf_valid() then
    prompt.create_buffer()
    keymaps.setup_prompt_keymaps(prompt.get_buf(), {
      close_fn = M.close,
      focus_result_fn = function()
        if vim.api.nvim_win_is_valid(result.get_win()) then
          vim.api.nvim_set_current_win(result.get_win())
        end
      end,
      cancel_progress_fn = function()
        sessions.cancel_progress(current_session)
      end,
      send_message_fn = function()
        local content = prompt.get_content()
        if #content == 1 and content[1] == '' then
          return
        end

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
        prompt.clear()

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
      end,

      retry_message_fn = function()
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

  if not prompt.is_valid() then
    prompt.open_window(
      prompt.get_buf(),
      start_col,
      start_row + screen_height - 3,
      screen_width,
      current_session
    )
  else
    if vim.api.nvim_win_get_buf(prompt.get_win()) ~= prompt.get_buf() then
      vim.api.nvim_win_set_buf(prompt.get_win(), prompt.get_buf())
    end
    prompt.focus()
    M.redraw_title()
  end

  -- Start spinner if request in progress
  if sessions.is_in_progress(current_session) then
    spinners.start()
  else
    spinners.stop()
  end

  -- Start background services
  queue.start()
  if config.config.http.api_key ~= '' then
    require('chat.http').start()
  end

  require('chat.integrations').on_message(function(message)
    queue.push(message.session, message.content)
  end)
  require('chat.mcp').connect()
end

-- Get current session ID
function M.current_session()
  return current_session
end

-- Send a message programmatically
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

-- Message handling - forward to result module
function M.on_message(session, message)
  result.on_message(session, current_session, message)
end

function M.on_tool_call_done(session, messages)
  result.on_tool_call_done(session, current_session, messages)
end

function M.on_tool_call_start(session, message)
  result.on_tool_call_start(session, current_session, message)
end

-- Update window titles
function M.redraw_title()
  prompt.redraw_title(current_session)
end

function M.set_result_win_title(text)
  result.set_title(text, current_session)
end

-- Render result buffer content
function M.render_result_buf()
  result.render(current_session)
end

-- Push streaming text to result window
function M.push_text(chunk)
  result.push_text(chunk)
end

return M

