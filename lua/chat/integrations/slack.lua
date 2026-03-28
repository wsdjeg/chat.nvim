local M = {}

local config = require('chat.config')
local log = require('chat.log')
local job = require('job')

local json = vim.json
local uv = vim.uv

--------------------------------------------------
-- constants
--------------------------------------------------
local STATE_FILE = vim.fn.stdpath('data') .. '/chat-slack-state.json'
local API_BASE = 'https://slack.com/api'

--------------------------------------------------
-- state
--------------------------------------------------
local state = {
  timer = nil,
  last_timestamp = nil,
  bot_user_id = nil,
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
    last_timestamp = state.last_timestamp,
    bot_user_id = state.bot_user_id,
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
    log.error('[Slack] Failed to encode state')
    return false
  end

  local dir = vim.fn.fnamemodify(STATE_FILE, ':h')
  if vim.fn.isdirectory(dir) == 0 then
    vim.fn.mkdir(dir, 'p')
  end

  local file, err = io.open(STATE_FILE, 'w')
  if not file then
    log.error('[Slack] Failed to save state: ' .. (err or 'unknown'))
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

  state.last_timestamp = data.last_timestamp
  state.bot_user_id = data.bot_user_id
  state.processed_ids = data.processed_ids or {}
  state.session = data.session

  log.debug('[Slack] State loaded')
  return true
end

--------------------------------------------------
-- API request helper
--------------------------------------------------
local function api_request(method, params, callback)
  local bot_token = config.config.integrations
    and config.config.integrations.slack
    and config.config.integrations.slack.bot_token

  if not bot_token then
    log.error('[Slack] bot_token not configured')
    return nil
  end

  local cmd = {
    'curl',
    '-s',
    '-X',
    'POST',
    API_BASE .. '/' .. method,
    '-H',
    'Authorization: Bearer ' .. bot_token,
    '-H',
    'Content-Type: application/x-www-form-urlencoded',
  }

  -- Build query string from params
  if params then
    local query_parts = {}
    for k, v in pairs(params) do
      table.insert(query_parts, k .. '=' .. vim.uri_encode(v))
    end
    if #query_parts > 0 then
      table.insert(cmd, '-d')
      table.insert(cmd, table.concat(query_parts, '&'))
    end
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
            log.error('[Slack] Failed to decode: ' .. output)
          end
        end
      end
    end,
    on_stderr = function(_, lines)
      for _, line in ipairs(lines) do
        if line and line ~= '' then
          log.error('[Slack] ' .. line)
        end
      end
    end,
  })

  return jobid
end

--------------------------------------------------
-- Get bot user ID
--------------------------------------------------
local function get_bot_user_id()
  if state.bot_user_id then
    return state.bot_user_id
  end

  api_request('auth.test', nil, function(result)
    if result.ok and result.user_id then
      state.bot_user_id = result.user_id
      save_state()
      log.info('[Slack] Bot User ID: ' .. state.bot_user_id)
    else
      log.error('[Slack] Failed to get bot user ID: ' .. vim.inspect(result))
    end
  end)
end

--------------------------------------------------
-- Fetch messages
--------------------------------------------------
local function fetch_messages()
  if state.is_fetching then
    return
  end

  local channel = config.config.integrations
    and config.config.integrations.slack
    and config.config.integrations.slack.channel_id

  if not channel then
    log.error('[Slack] channel_id not configured')
    return
  end

  state.is_fetching = true

  -- Timeout protection
  local timeout = uv.new_timer()
  timeout:start(5000, 0, function()
    if state.is_fetching then
      log.warn('[Slack] Request timeout, releasing lock')
      state.is_fetching = false
    end
  end)

  local params = {
    channel = channel,
    limit = '10',
  }

  if state.last_timestamp then
    params.oldest = state.last_timestamp
  end

  api_request('conversations.history', params, function(result)
    -- Cleanup timeout timer
    timeout:stop()
    timeout:close()

    -- Release lock
    state.is_fetching = false

    if not result.ok or not result.messages or #result.messages == 0 then
      if not result.ok then
        log.error('[Slack] API error: ' .. (result.error or 'unknown'))
      end
      return
    end

    -- Track highest timestamp for updating last_timestamp
    local highest_ts = state.last_timestamp
    local has_new = false

    -- Reverse to process in chronological order
    for i = #result.messages, 1, -1 do
      local msg = result.messages[i]

      -- Skip already processed
      if state.processed_ids[msg.ts] then
        goto continue
      end

      -- Mark as processed
      state.processed_ids[msg.ts] = true
      has_new = true

      -- Update highest timestamp
      if not highest_ts or msg.ts > highest_ts then
        highest_ts = msg.ts
      end

      -- Skip bot messages
      if msg.bot_id or (msg.user and msg.user == state.bot_user_id) then
        goto continue
      end

      -- Check if mentioned
      local is_mentioned = false
      local content = msg.text or ''

      -- Check for <@USER_ID> mention
      if state.bot_user_id then
        if content:match('<@' .. state.bot_user_id .. '>') then
          is_mentioned = true
          content = content
            :gsub('<@' .. state.bot_user_id .. '>', '')
            :gsub('^%s+', '')
            :gsub('%s+$', '')
        end
      end

      -- Check for reply to bot
      if msg.thread_ts and msg.thread_ts ~= msg.ts then
        -- This is a reply in a thread, check if it's for the bot
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
            author = msg.user or 'Unknown',
            content = content,
            channel_id = channel,
            message_ts = msg.ts,
            thread_ts = msg.thread_ts,
          })
        end)
      end

      ::continue::
    end

    -- Update last_timestamp
    if highest_ts and highest_ts ~= state.last_timestamp then
      state.last_timestamp = highest_ts
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
-- Connect
--------------------------------------------------
function M.connect(callback)
  local slack_config = config.config.integrations
    and config.config.integrations.slack

  if not slack_config or not slack_config.bot_token then
    log.error('[Slack] bot_token not configured')
    return
  end

  if not slack_config.channel_id then
    log.error('[Slack] channel_id not configured')
    return
  end

  if state.is_running then
    return
  end

  state.callback = callback
  state.is_running = true

  load_state()
  log.info('[Slack] Starting polling...')

  -- Get bot user ID
  get_bot_user_id()

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

  log.info('[Slack] Polling started')
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
  log.info('[Slack] Polling stopped')
end

--------------------------------------------------
-- Send message
--------------------------------------------------
local message_queue = {}
local send_message_jobid = -1

local function send_message(content)
  local channel = config.config.integrations
    and config.config.integrations.slack
    and config.config.integrations.slack.channel_id
  local bot_token = config.config.integrations
    and config.config.integrations.slack
    and config.config.integrations.slack.bot_token

  if not channel or not bot_token then
    log.error('[Slack] channel_id or bot_token not configured')
    return nil
  end

  if send_message_jobid > 0 then
    return
  end

  local params = {
    channel = channel,
    text = content,
  }

  local query_parts = {}
  for k, v in pairs(params) do
    table.insert(query_parts, k .. '=' .. vim.uri_encode(v))
  end

  send_message_jobid = job.start({
    'curl',
    '-s',
    '-X',
    'POST',
    API_BASE .. '/chat.postMessage',
    '-H',
    'Authorization: Bearer ' .. bot_token,
    '-H',
    'Content-Type: application/x-www-form-urlencoded',
    '-d',
    table.concat(query_parts, '&'),
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

  return send_message_jobid
end

function M.send_message(content)
  local max_length = 40000 -- Slack message limit

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
-- Reply to message (thread reply)
--------------------------------------------------
function M.reply(channel, thread_ts, text)
  local bot_token = config.config.integrations
    and config.config.integrations.slack
    and config.config.integrations.slack.bot_token

  if not bot_token then
    log.error('[Slack] bot_token not configured')
    return nil
  end

  local params = {
    channel = channel,
    text = text,
    thread_ts = thread_ts,
  }

  local query_parts = {}
  for k, v in pairs(params) do
    table.insert(query_parts, k .. '=' .. vim.uri_encode(v))
  end

  return job.start({
    'curl',
    '-s',
    '-X',
    'POST',
    API_BASE .. '/chat.postMessage',
    '-H',
    'Authorization: Bearer ' .. bot_token,
    '-H',
    'Content-Type: application/x-www-form-urlencoded',
    '-d',
    table.concat(query_parts, '&'),
  }, {
    on_exit = function(id, code, signal)
      if code ~= 0 or signal ~= 0 then
        log.debug(
          string.format(
            '[slack] reply job %d exit with code %d signal %d',
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
    bot_user_id = state.bot_user_id,
    last_timestamp = state.last_timestamp,
    poll_interval = state.poll_interval,
    processed_count = vim.tbl_count(state.processed_ids),
  }
end

--------------------------------------------------
-- Clear saved state
--------------------------------------------------
function M.clear_state()
  state.last_timestamp = nil
  state.bot_user_id = nil
  state.processed_ids = {}
  os.remove(STATE_FILE)
  log.info('[Slack] State cleared')
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

