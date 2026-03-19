local M = {}

local config = require('chat.config')
local log = require('chat.log')
local job = require('job')

local json = vim.json
local uv = vim.uv

--------------------------------------------------
-- constants
--------------------------------------------------
local STATE_FILE = vim.fn.stdpath('data') .. '/chat-telegram-state.json'
local API_BASE = 'https://api.telegram.org/bot'

--------------------------------------------------
-- state
--------------------------------------------------
local state = {
  timer = nil,
  last_update_id = nil,
  bot_username = nil,
  callback = nil,
  is_running = false,
  is_fetching = false,
  processed_ids = {},
  max_processed_cache = 100,
  poll_interval = 3000,
  session = nil,
}

--------------------------------------------------
-- Save/Load state
--------------------------------------------------
local function save_state()
  local data = {
    last_update_id = state.last_update_id,
    bot_username = state.bot_username,
    processed_ids = {},
    session = state.session,
  }

  local count = 0
  for id, _ in pairs(state.processed_ids) do
    count = count + 1
    if count <= state.max_processed_cache then
      data.processed_ids[id] = true
    end
  end

  local ok, encoded = pcall(json.encode, data)
  if not ok then
    log.error('[Telegram] Failed to encode state')
    return false
  end

  local dir = vim.fn.fnamemodify(STATE_FILE, ':h')
  if vim.fn.isdirectory(dir) == 0 then
    vim.fn.mkdir(dir, 'p')
  end

  local file, err = io.open(STATE_FILE, 'w')
  if not file then
    log.error('[Telegram] Failed to save state: ' .. (err or 'unknown'))
    return false
  end

  file:write(encoded)
  file:close()
  return true
end

local function load_state()
  local file = io.open(STATE_FILE, 'r')
  if not file then
    return false
  end

  local content = file:read('*a')
  file:close()

  if not content or content == '' then
    return false
  end

  local ok, data = pcall(json.decode, content)
  if not ok or not data then
    return false
  end

  state.last_update_id = data.last_update_id
  state.bot_username = data.bot_username
  state.processed_ids = data.processed_ids or {}
  state.session = data.session

  log.debug('[Telegram] State loaded')
  return true
end

--------------------------------------------------
-- API request helper
--------------------------------------------------
local function api_request(method, data, callback)
  local bot_token = config.config.integrations
    and config.config.integrations.telegram
    and config.config.integrations.telegram.bot_token

  if not bot_token then
    log.error('[Telegram] bot_token not configured')
    return nil
  end

  local cmd = {
    'curl',
    '-s',
    '-X',
    'POST',
    API_BASE .. bot_token .. '/' .. method,
    '-H',
    'Content-Type: application/json',
  }

  if data then
    table.insert(cmd, '-d')
    table.insert(cmd, json.encode(data))
  end

  local jobid = job.start(cmd, {
    on_stdout = function(_, lines)
      if callback then
        local output = table.concat(lines, '\n')
        if output and output ~= '' then
          local ok, result = pcall(json.decode, output)
          if ok and result then
            callback(result)
          else
            log.error('[Telegram] Failed to decode: ' .. output)
          end
        end
      end
    end,
    on_stderr = function(_, lines)
      for _, line in ipairs(lines) do
        if line and line ~= '' then
          log.error('[Telegram] ' .. line)
        end
      end
    end,
  })

  return jobid
end

--------------------------------------------------
-- Get bot info
--------------------------------------------------
local function get_bot_info()
  if state.bot_username then
    return
  end

  api_request('getMe', nil, function(result)
    if result.ok and result.result then
      state.bot_username = result.result.username
      save_state()
      log.info('[Telegram] Bot: @' .. state.bot_username)
    else
      log.error('[Telegram] Failed to get bot info: ' .. vim.inspect(result))
    end
  end)
end

--------------------------------------------------
-- Fetch updates
--------------------------------------------------
local function fetch_updates()
  if state.is_fetching then
    return
  end

  state.is_fetching = true

  local timeout = uv.new_timer()
  timeout:start(5000, 0, function()
    if state.is_fetching then
      log.warn('[Telegram] Request timeout')
      state.is_fetching = false
    end
  end)

  local params = {
    timeout = 10,
    allowed_updates = { 'message' },
  }

  if state.last_update_id then
    params.offset = state.last_update_id + 1
  end

  api_request('getUpdates', params, function(result)
    timeout:stop()
    timeout:close()
    state.is_fetching = false

    if not result.ok or not result.result or #result.result == 0 then
      return
    end

    local highest_id = state.last_update_id

    for _, update in ipairs(result.result) do
      -- Track highest update_id
      if not highest_id or update.update_id > highest_id then
        highest_id = update.update_id
      end

      -- Skip already processed
      if state.processed_ids[update.update_id] then
        goto continue
      end

      state.processed_ids[update.update_id] = true

      local msg = update.message
      if not msg or not msg.text then
        goto continue
      end

      -- Skip bot messages
      if msg.from and msg.from.is_bot then
        goto continue
      end

      -- Check if message mentions bot or is a reply to bot
      local is_mentioned = false
      local content = msg.text

      if state.bot_username then
        -- Check for @username mention
        if content:match('@' .. state.bot_username) then
          is_mentioned = true
          content = content
            :gsub('@' .. state.bot_username, '')
            :gsub('^%s+', '')
            :gsub('%s+$', '')
        end

        -- Check for reply to bot
        if msg.reply_to_message and msg.reply_to_message.from then
          if msg.reply_to_message.from.username == state.bot_username then
            is_mentioned = true
          end
        end
      end

      -- Check if private chat (always respond)
      local chat_type = msg.chat and msg.chat.type or ''
      if chat_type == 'private' then
        is_mentioned = true
      end

      if not is_mentioned then
        goto continue
      end

      if content == '' then
        goto continue
      end

      -- Callback
      if state.callback then
        vim.schedule(function()
          state.callback({
            author = msg.from
              and (msg.from.first_name or msg.from.username or 'Unknown'),
            content = content,
            chat_id = msg.chat.id,
            message_id = msg.message_id,
          })
        end)
      end

      ::continue::
    end

    -- Update last_update_id
    if highest_id and highest_id ~= state.last_update_id then
      state.last_update_id = highest_id
    end

    -- Cleanup old processed_ids
    local id_count = 0
    local oldest_ids = {}
    for id in pairs(state.processed_ids) do
      id_count = id_count + 1
      if id_count > state.max_processed_cache then
        table.insert(oldest_ids, id)
      end
    end
    for _, id in ipairs(oldest_ids) do
      state.processed_ids[id] = nil
    end

    save_state()
  end)
end

--------------------------------------------------
-- Connect
--------------------------------------------------
function M.connect(callback)
  local telegram_config = config.config.integrations
    and config.config.integrations.telegram

  if not telegram_config or not telegram_config.bot_token then
    log.error('[Telegram] bot_token not configured')
    return
  end

  if state.is_running then
    return
  end

  state.callback = callback
  state.is_running = true

  load_state()
  log.info('[Telegram] Starting polling...')

  -- Get bot info
  get_bot_info()

  -- Start timer
  state.timer = uv.new_timer()
  state.timer:start(
    0,
    state.poll_interval,
    vim.schedule_wrap(function()
      if state.is_running then
        fetch_updates()
      end
    end)
  )

  log.info('[Telegram] Polling started')
end

--------------------------------------------------
-- Disconnect
--------------------------------------------------
function M.disconnect()
  if state.timer then
    state.timer:stop()
    state.timer = nil
  end

  state.is_running = false
  state.is_fetching = false
  state.callback = nil
  save_state()
  log.info('[Telegram] Polling stopped')
end

--------------------------------------------------
-- Send message
--------------------------------------------------
local message_queue = {}
local send_message_jobid = -1

local function send_message(content)
  local chat_id = config.config.integrations
    and config.config.integrations.telegram
    and config.config.integrations.telegram.chat_id
  local bot_token = config.config.integrations
    and config.config.integrations.telegram
    and config.config.integrations.telegram.bot_token

  if not chat_id or not bot_token then
    log.error('[Telegram] chat_id or bot_token not configured')
    return nil
  end

  if send_message_jobid > 0 then
    return
  end

  send_message_jobid = job.start({
    'curl',
    '-s',
    '-X',
    'POST',
    API_BASE .. bot_token .. '/sendMessage',
    '-H',
    'Content-Type: application/json',
    '-d',
    '@-',
  }, {
    on_stdout = function(_, data)
      for _, v in ipairs(data) do
        log.debug(v)
      end
    end,
    on_stderr = function(_, data)
      for _, v in ipairs(data) do
        log.debug(v)
      end
    end,
    on_exit = function()
      send_message_jobid = -1
      if #message_queue > 0 then
        send_message(table.remove(message_queue, 1))
      end
    end,
  })

  job.send(
    send_message_jobid,
    json.encode({
      chat_id = chat_id,
      text = content,
      parse_mode = 'Markdown',
    })
  )
  job.send(send_message_jobid, nil)
end

function M.send_message(content)
  local max_length = 4096 -- Telegram message limit

  if #content <= max_length then
    table.insert(message_queue, content)
  else
    local remaining = content
    while #remaining > 0 do
      local chunk
      if #remaining <= max_length then
        chunk = remaining
        remaining = ''
      else
        local split_pos = remaining:sub(1, max_length):reverse():find('\n')
        if split_pos then
          split_pos = max_length - split_pos + 1
          chunk = remaining:sub(1, split_pos)
          remaining = remaining:sub(split_pos + 1)
        else
          chunk = remaining:sub(1, max_length)
          remaining = remaining:sub(max_length + 1)
        end
      end
      table.insert(message_queue, chunk)
    end
  end

  if #message_queue > 0 then
    send_message()
  end
end

--------------------------------------------------
-- Reply to message
--------------------------------------------------
function M.reply(chat_id, message_id, text)
  local bot_token = config.config.integrations
    and config.config.integrations.telegram
    and config.config.integrations.telegram.bot_token

  if not bot_token then
    log.error('[Telegram] bot_token not configured')
    return nil
  end

  return job.start({
    'curl',
    '-s',
    '-X',
    'POST',
    API_BASE .. bot_token .. '/sendMessage',
    '-H',
    'Content-Type: application/json',
    '-d',
    json.encode({
      chat_id = chat_id,
      text = text,
      reply_to_message_id = message_id,
      parse_mode = 'Markdown',
    }),
  }, {
    on_exit = function(id, code, signal)
      if code ~= 0 or signal ~= 0 then
        log.debug(
          string.format(
            '[telegram] reply job %d exit with code %d signal %d',
            id,
            code,
            signal
          )
        )
      end
    end,
  })
end

--------------------------------------------------
-- Status
--------------------------------------------------
function M.get_state()
  return {
    is_running = state.is_running,
    bot_username = state.bot_username,
    last_update_id = state.last_update_id,
    poll_interval = state.poll_interval,
    processed_count = vim.tbl_count(state.processed_ids),
  }
end

--------------------------------------------------
-- Clear saved state
--------------------------------------------------
function M.clear_state()
  state.last_update_id = nil
  state.bot_username = nil
  state.processed_ids = {}
  os.remove(STATE_FILE)
  log.info('[Telegram] State cleared')
end

--------------------------------------------------
-- Session management
--------------------------------------------------
function M.current_session()
  return state.session
end

function M.set_session(session)
  state.session = session
  save_state()
end

--------------------------------------------------
-- Cleanup
--------------------------------------------------
function M.cleanup()
  M.disconnect()
end

return M
