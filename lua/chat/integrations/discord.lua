local M = {}

local config = require('chat.config')
local log = require('chat.log')
local job = require('job')

local json = vim.json
local uv = vim.uv

--------------------------------------------------
-- constants
--------------------------------------------------
local STATE_FILE = vim.fn.stdpath('data') .. '/chat-discord-state.json'

--------------------------------------------------
-- state
--------------------------------------------------
local state = {
  timer = nil,
  last_message_id = nil,
  bot_id = nil,
  callback = nil,
  is_running = false,
  is_fetching = false,
  processed_ids = {},
  max_processed_cache = 100,
  poll_interval = 3000,
}

--------------------------------------------------
-- Save state to file
--------------------------------------------------
local function save_state()
  local data = {
    last_message_id = state.last_message_id,
    bot_id = state.bot_id,
    processed_ids = {},
    session = state.session,
  }

  -- Only save recent processed_ids
  local count = 0
  for id, _ in pairs(state.processed_ids) do
    count = count + 1
    if count <= state.max_processed_cache then
      data.processed_ids[id] = true
    end
  end

  local ok, encoded = pcall(json.encode, data)
  if not ok then
    log.error('[Discord] Failed to encode state')
    return false
  end

  local dir = vim.fn.fnamemodify(STATE_FILE, ':h')
  if vim.fn.isdirectory(dir) == 0 then
    vim.fn.mkdir(dir, 'p')
  end

  local file, err = io.open(STATE_FILE, 'w')
  if not file then
    log.error('[Discord] Failed to save state: ' .. (err or 'unknown'))
    return false
  end

  file:write(encoded)
  file:close()
  return true
end

--------------------------------------------------
-- Load state from file
--------------------------------------------------
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

  state.last_message_id = data.last_message_id
  state.bot_id = data.bot_id

  if data.processed_ids then
    state.processed_ids = data.processed_ids
  end

  if data.session then
    state.session = data.session
  end

  log.debug('[Discord] State loaded')
  return true
end

--------------------------------------------------
-- Helper: make API request
--------------------------------------------------
local function api_request(method, endpoint, data, callback)
  local token = config.config.integrations
    and config.config.integrations.discord
    and config.config.integrations.discord.token

  if not token then
    log.error('[Discord] Token not configured')
    return nil
  end

  local cmd = {
    'curl',
    '-s',
    '-X',
    method,
    'https://discord.com/api/v10' .. endpoint,
    '-H',
    'Authorization: Bot ' .. token,
    '-H',
    'Content-Type: application/json',
  }

  if data then
    table.insert(cmd, '-d')
    table.insert(cmd, '@-')
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
            log.error('[Discord] Failed to decode: ' .. output)
          end
        end
      end
    end,
    on_stderr = function(_, lines)
      for _, line in ipairs(lines) do
        if line and line ~= '' then
          log.error('[Discord] ' .. line)
        end
      end
    end,
  })
  job.send(jobid, json.encode(data))
  job.send(jobid, nil)
end

--------------------------------------------------
-- Get bot user info
--------------------------------------------------
local function get_bot_id()
  if state.bot_id then
    return state.bot_id
  end

  api_request('GET', '/users/@me', nil, function(data)
    if data.id then
      state.bot_id = data.id
      save_state()
      log.info('[Discord] Bot ID: ' .. state.bot_id)
    else
      log.error('[Discord] Failed to get bot ID: ' .. vim.inspect(data))
    end
  end)
end

--------------------------------------------------
-- Check if message is for bot
--------------------------------------------------
local function is_for_bot(msg)
  -- Check mentions
  if msg.mentions then
    for _, m in ipairs(msg.mentions) do
      if m.id == state.bot_id then
        return true
      end
    end
  end

  -- Check reply
  if msg.referenced_message and msg.referenced_message.author then
    if msg.referenced_message.author.id == state.bot_id then
      return true
    end
  end

  return false
end

--------------------------------------------------
-- Fetch messages
--------------------------------------------------
local function fetch_messages()
  -- Check request lock
  if state.is_fetching then
    return
  end

  local channel = config.config.integrations
    and config.config.integrations.discord
    and config.config.integrations.discord.channel_id

  if not channel then
    log.error('[Discord] Channel ID not configured')
    return
  end

  -- Set lock
  state.is_fetching = true

  -- Build endpoint
  local endpoint = '/channels/' .. channel .. '/messages?limit=10'
  if state.last_message_id then
    endpoint = endpoint .. '&after=' .. state.last_message_id
  end

  -- Timeout protection
  local timeout = uv.new_timer()
  timeout:start(5000, 0, function()
    if state.is_fetching then
      log.warn('[Discord] Request timeout, releasing lock')
      state.is_fetching = false
    end
  end)

  api_request('GET', endpoint, nil, function(messages)
    -- Cleanup timeout timer
    timeout:stop()
    timeout:close()

    -- Release lock
    state.is_fetching = false

    if not messages or type(messages) ~= 'table' or #messages == 0 then
      return
    end

    -- Track highest ID for updating last_message_id
    local highest_id = state.last_message_id
    local has_new = false

    -- Reverse to process in chronological order
    for i = #messages, 1, -1 do
      local msg = messages[i]

      -- Skip already processed
      if state.processed_ids[msg.id] then
        goto continue
      end

      -- Mark as processed
      state.processed_ids[msg.id] = true
      has_new = true

      -- Update highest ID (for last_message_id)
      if not highest_id or msg.id > highest_id then
        highest_id = msg.id
      end

      -- Skip bot messages
      if not msg.author or msg.author.bot then
        goto continue
      end

      -- Check if mentioned
      if not is_for_bot(msg) then
        goto continue
      end

      -- Clean content
      local content = msg.content or ''
      content = content:gsub('<@!?%d+>', ''):gsub('^%s+', ''):gsub('%s+$', '')

      if content == '' then
        goto continue
      end

      -- Callback
      if state.callback then
        vim.schedule(function()
          state.callback({
            author = msg.author.username or 'Unknown',
            content = content,
            channel_id = msg.channel_id,
            message_id = msg.id,
            reply = msg.referenced_message ~= nil,
          })
        end)
      end

      ::continue::
    end

    -- Update last_message_id after all processing
    if highest_id and highest_id ~= state.last_message_id then
      state.last_message_id = highest_id
    end

    -- Cleanup old processed_ids (prevent memory leak)
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

    -- Save state if there were new messages
    if has_new then
      save_state()
    end
  end)
end

--------------------------------------------------
-- Start polling
--------------------------------------------------
function M.connect(callback)
  -- Check config
  if
    not config.config.integrations
    or not config.config.integrations.discord
    or not config.config.integrations.discord.token
  then
    log.error('[Discord] Token not configured')
    return
  end

  if not config.config.integrations.discord.channel_id then
    log.error('[Discord] Channel ID not configured')
    return
  end

  if state.is_running then
    return
  end

  state.callback = callback
  state.is_running = true
  state.time = os.time()

  -- Load saved state
  load_state()

  log.info('[Discord] Starting polling...')

  -- Get bot ID
  get_bot_id()

  -- Start timer
  state.timer = uv.new_timer()
  state.timer:start(
    0,
    state.poll_interval,
    vim.schedule_wrap(function()
      if state.is_running then
        fetch_messages()
      end
    end)
  )

  log.info('[Discord] Polling started')
end

--------------------------------------------------
-- Stop polling
--------------------------------------------------
function M.disconnect()
  if state.timer then
    state.timer:stop()
    state.timer = nil
  end

  state.is_running = false
  state.is_fetching = false
  state.callback = nil

  -- Save state before stopping
  save_state()

  log.info('[Discord] Polling stopped')
end

--------------------------------------------------
-- Send message
--
--------------------------------------------------
local message_queue = {}

local send_message_jobid = -1

local function send_message(content)
  local channel = config.config.integrations
    and config.config.integrations.discord
    and config.config.integrations.discord.channel_id
  local token = config.config.integrations
    and config.config.integrations.discord
    and config.config.integrations.discord.token

  if not channel or not token then
    log.error('[Discord] Missing channel_id or token')
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
    'https://discord.com/api/v10/channels/' .. channel .. '/messages',
    '-H',
    'Authorization: Bot ' .. token,
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
    on_exit = function(_, code, single)
      log.debug(
        'discord send_message job exit ' .. code .. ' single ' .. single
      )
      send_message_jobid = -1
      if #message_queue > 0 then
        send_message(table.remove(message_queue, 1))
      end
    end,
  })
  job.send(send_message_jobid, json.encode({ content = content }))
  job.send(send_message_jobid, nil)
end

function M.send_message(content)
  local max_length = 2000

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
function M.reply(channel, message_id, text)
  local token = config.config.integrations
    and config.config.integrations.discord
    and config.config.integrations.discord.token

  if not token then
    log.error('[Discord] Token not configured')
    return nil
  end

  local jobid = job.start({
    'curl',
    '-s',
    '-X',
    'POST',
    'https://discord.com/api/v10/channels/' .. channel .. '/messages',
    '-H',
    'Authorization: Bot ' .. token,
    '-H',
    'Content-Type: application/json',
    '-d',
    json.encode({
      content = text,
      message_reference = {
        message_id = message_id,
      },
    }),
  }, {
    on_exit = function(id, code, signal)
      if code ~= 0 or signal ~= 0 then
        log.debug(
          string.format(
            '[discord] reply job %d exit with code %d signal %d',
            id,
            code,
            signal
          )
        )
      end
    end,
  })

  return jobid
end

--------------------------------------------------
-- Status
--------------------------------------------------
function M.get_state()
  return {
    is_running = state.is_running,
    bot_id = state.bot_id,
    last_message_id = state.last_message_id,
    poll_interval = state.poll_interval,
    processed_count = vim.tbl_count(state.processed_ids),
  }
end

--------------------------------------------------
-- Clear saved state
--------------------------------------------------
function M.clear_state()
  state.last_message_id = nil
  state.bot_id = nil
  state.processed_ids = {}
  os.remove(STATE_FILE)
  log.info('[Discord] State cleared')
end

--------------------------------------------------
-- Legacy compatibility
--------------------------------------------------
M.receive_messages = M.connect

--------------------------------------------------
-- Cleanup on module unload
--------------------------------------------------
function M.cleanup()
  M.disconnect()
end
function M.current_session()
  return state.session
end

function M.set_session(session)
  state.session = session
  save_state()
end

return M
