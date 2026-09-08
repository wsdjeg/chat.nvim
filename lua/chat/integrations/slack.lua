local M = {}

local config = require('chat.config')
local log = require('chat.log')
local job = require('job')
local curl = require('chat.curl')
local chunker = require('chat.utils.chunker')

local json = vim.json
local uv = vim.uv

--------------------------------------------------
-- constants
--------------------------------------------------
local STATE_FILE = config.config.storage_dir .. 'integration/slack.json'
local API_BASE = 'https://slack.com/api'

-- curl-level timeouts: a failing request is fast and definitive instead
-- of hanging until the watchdog fires
local CONNECT_TIMEOUT = 5
local MAX_TIME = 10

-- Safety net for lost job callbacks. Must be larger than MAX_TIME so it
-- never fires in normal operation — if it does, something is a bug.
local WATCHDOG_TIMEOUT = 15000

-- While an outage persists, re-log a heartbeat every N failed polls
local FAILURE_HEARTBEAT = 10

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
  -- request epoch: responses from earlier requests are discarded
  request_seq = 0,
  -- consecutive failed polls (for state-change logging)
  fail_count = 0,
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
-- callback(result, err): result is the decoded JSON table (nil on
-- failure), err is a human-readable failure reason
local function api_request(method, params, callback)
  local bot_token = config.config.integrations
    and config.config.integrations.slack
    and config.config.integrations.slack.bot_token

  if not bot_token then
    log.error('[Slack] bot_token not configured')
    return nil
  end

  local body_data
  if params then
    local query_parts = {}
    for k, v in pairs(params) do
      table.insert(query_parts, k .. '=' .. vim.uri_encode(v))
    end
    if #query_parts > 0 then
      body_data = table.concat(query_parts, '&')
    end
  end

  local cmd = curl.build_request({
    url = API_BASE .. '/' .. method,
    method = 'POST',
    headers = {
      'Authorization: Bearer ' .. bot_token,
      'Content-Type: application/x-www-form-urlencoded',
    },
    body = body_data,
    connect_timeout = CONNECT_TIMEOUT,
    max_time = MAX_TIME,
  })

  local stdout, stderr = {}, {}

  local jobid = job.start(cmd, {
    on_stdout = function(_, lines)
      for _, v in ipairs(lines) do
        table.insert(stdout, v)
      end
    end,
    on_stderr = function(_, lines)
      -- Collect instead of logging: curl writes network errors to
      -- stderr even with -s, and per-line logging would spam every
      -- poll while the network is down
      for _, line in ipairs(lines) do
        if line and line ~= '' then
          table.insert(stderr, line)
        end
      end
    end,
    on_exit = function(_, code, signal)
      if not callback then
        return
      end

      if code ~= 0 or signal ~= 0 then
        local reason = 'curl exited with code ' .. code
        if #stderr > 0 then
          reason = reason .. ': ' .. table.concat(stderr, ' ')
        end
        return callback(nil, reason)
      end

      local output = table.concat(stdout, '\n')
      if output == '' then
        return callback(nil, 'empty response')
      end

      local ok, result = pcall(json.decode, output)
      if not ok or result == nil then
        return callback(nil, 'invalid JSON: ' .. output:sub(1, 120))
      end
      callback(result)
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

  api_request('auth.test', nil, function(result, err)
    if result and result.ok and result.user_id then
      state.bot_user_id = result.user_id
      save_state()
      log.info('[Slack] Bot User ID: ' .. state.bot_user_id)
    else
      log.error('[Slack] Failed to get bot user ID: ' .. (err or vim.inspect(result)))
    end
  end)
end

--------------------------------------------------
-- Poll health tracking (state-change logging)
--
-- Healthy polling is silent. A failure logs once on entry, every
-- FAILURE_HEARTBEAT polls while it persists, and once on recovery.
--------------------------------------------------
local function poll_failed(reason)
  state.fail_count = state.fail_count + 1
  if state.fail_count == 1 then
    log.error('[Slack] Polling failed: ' .. (reason or 'unknown error'))
  elseif state.fail_count % FAILURE_HEARTBEAT == 0 then
    log.warn(
      string.format(
        '[Slack] Polling still failing (%d attempts, last: %s)',
        state.fail_count,
        reason or 'unknown error'
      )
    )
  end
end

local function poll_ok()
  if state.fail_count > 0 then
    log.info(
      string.format(
        '[Slack] Polling recovered after %d failed attempt(s)',
        state.fail_count
      )
    )
    state.fail_count = 0
  end
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

  local seq = state.request_seq + 1
  state.request_seq = seq
  state.is_fetching = true

  -- Safety net only: curl itself fails fast (connect 5s / total 10s).
  -- If this fires, the job callback was lost — always worth a warning.
  local timeout = uv.new_timer()
  timeout:start(WATCHDOG_TIMEOUT, 0, function()
    timeout:close()
    if state.is_fetching and state.request_seq == seq then
      log.warn('[Slack] Watchdog fired (callback lost?), releasing lock')
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

  api_request('conversations.history', params, function(result, err)
    -- Stale response from an earlier request — discard
    if state.request_seq ~= seq then
      return
    end

    timeout:stop()
    if not timeout:is_closing() then
      timeout:close()
    end

    -- Release lock
    state.is_fetching = false

    -- Request failed (network error, curl timeout, bad JSON)
    if result == nil then
      poll_failed(err or 'request failed')
      return
    end

    -- Slack API-level error
    if not result.ok then
      poll_failed('API error: ' .. (result.error or 'unknown'))
      return
    end

    -- Healthy again
    poll_ok()

    if not result.messages or #result.messages == 0 then
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

  -- Invalidate any in-flight request
  state.request_seq = state.request_seq + 1
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
  local body = table.concat(query_parts, '&')

  local cmd = curl.build_request({
    url = API_BASE .. '/chat.postMessage',
    method = 'POST',
    headers = {
      'Authorization: Bearer ' .. bot_token,
      'Content-Type: application/x-www-form-urlencoded',
    },
    body = body,
    connect_timeout = CONNECT_TIMEOUT,
    max_time = MAX_TIME,
  })
  local stderr_lines = {}
  send_message_jobid = job.start(cmd, {
    on_stdout = function(_, data)
      for _, v in ipairs(data) do
        log.debug(v)
      end
    end,
    on_stderr = function(_, data)
      for _, v in ipairs(data) do
        log.debug(v)
        if v and v ~= '' then
          table.insert(stderr_lines, v)
        end
      end
    end,
    on_exit = function(_, code, signal)
      if code ~= 0 or signal ~= 0 then
        local reason = 'curl exit ' .. code
        if #stderr_lines > 0 then
          reason = reason .. ': ' .. table.concat(stderr_lines, ' ')
        end
        log.error('[Slack] Failed to send message (' .. reason .. ')')
      end
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

  local chunks = chunker.chunk(content, max_length)
  for _, chunk in ipairs(chunks) do
    table.insert(message_queue, chunk)
  end

  if #message_queue > 0 then
    send_message(table.remove(message_queue, 1))
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
  local body = table.concat(query_parts, '&')

  local cmd = curl.build_request({
    url = API_BASE .. '/chat.postMessage',
    method = 'POST',
    headers = {
      'Authorization: Bearer ' .. bot_token,
      'Content-Type: application/x-www-form-urlencoded',
    },
    body = body,
    connect_timeout = CONNECT_TIMEOUT,
    max_time = MAX_TIME,
  })
  return job.start(cmd, {
    on_exit = function(id, code, signal)
      if code ~= 0 or signal ~= 0 then
        log.error(
          string.format(
            '[Slack] Failed to send reply (job %d exit %d signal %d)',
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

