local M = {}

local config = require('chat.config')
local log = require('chat.log')
local job = require('job')

local json = vim.json
local uv = vim.uv

--------------------------------------------------
-- constants
--------------------------------------------------
local STATE_FILE = vim.fn.stdpath('data') .. '/chat-dingtalk-state.json'
local API_BASE = 'https://api.dingtalk.com'

--------------------------------------------------
-- state
--------------------------------------------------
local state = {
  timer = nil,
  access_token = nil,
  token_expires_at = 0,
  last_message_id = nil,
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
    last_message_id = state.last_message_id,
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
    return false
  end

  local dir = vim.fn.fnamemodify(STATE_FILE, ':h')
  if vim.fn.isdirectory(dir) == 0 then
    vim.fn.mkdir(dir, 'p')
  end

  local file = io.open(STATE_FILE, 'w')
  if file then
    file:write(encoded)
    file:close()
  end
  return true
end

local function load_state()
  local file = io.open(STATE_FILE, 'r')
  if not file then
    return false
  end

  local content = file:read('*a')
  file:close()

  local ok, data = pcall(json.decode, content)
  if ok and data then
    state.last_message_id = data.last_message_id
    state.processed_ids = data.processed_ids or {}
    state.session = data.session
  end
  return true
end

--------------------------------------------------
-- Get access token
--------------------------------------------------
local function get_access_token(callback)
  local app_key = config.config.integrations
    and config.config.integrations.dingtalk
    and config.config.integrations.dingtalk.app_key
  local app_secret = config.config.integrations
    and config.config.integrations.dingtalk
    and config.config.integrations.dingtalk.app_secret

  if not app_key or not app_secret then
    log.error('[DingTalk] app_key or app_secret not configured')
    return
  end

  job.start({
    'curl',
    '-s',
    '-X',
    'GET',
    'https://oapi.dingtalk.com/gettoken?appkey='
      .. app_key
      .. '&appsecret='
      .. app_secret,
  }, {
    on_stdout = function(_, lines)
      local output = table.concat(lines, '\n')
      local ok, result = pcall(json.decode, output)
      if ok and result and result.access_token then
        state.access_token = result.access_token
        state.token_expires_at = os.time() + (result.expires_in or 7200) - 300
        log.debug('[DingTalk] Token obtained')
        if callback then
          callback(result.access_token)
        end
      else
        log.error('[DingTalk] Failed to get token: ' .. output)
      end
    end,
  })
end

local function ensure_token(callback)
  if state.access_token and os.time() < state.token_expires_at then
    callback(state.access_token)
  else
    get_access_token(callback)
  end
end

--------------------------------------------------
-- Fetch messages (using robot webhook)
--------------------------------------------------
local function fetch_messages()
  if state.is_fetching then
    return
  end

  -- Note: DingTalk robot webhook is one-way
  -- For two-way communication, need to use DingTalk Stream mode
  -- This is a placeholder for Stream mode implementation
  state.is_fetching = true

  -- DingTalk Stream mode would require WebSocket connection
  -- For now, this implementation focuses on sending messages

  state.is_fetching = false
end

--------------------------------------------------
-- Connect
--------------------------------------------------
function M.connect(callback)
  local dingtalk_config = config.config.integrations
    and config.config.integrations.dingtalk

  if not dingtalk_config then
    log.error('[DingTalk] Configuration not found')
    return
  end

  -- Support both webhook mode and stream mode
  if not dingtalk_config.webhook and not dingtalk_config.app_key then
    log.error('[DingTalk] webhook or app_key not configured')
    return
  end

  if state.is_running then
    return
  end

  state.callback = callback
  state.is_running = true

  load_state()
  log.info('[DingTalk] Starting...')

  -- Only start polling for stream mode
  if dingtalk_config.app_key and dingtalk_config.app_secret then
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
  end

  log.info('[DingTalk] Started')
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
  state.callback = nil
  save_state()
  log.info('[DingTalk] Stopped')
end

--------------------------------------------------
-- Send message via webhook
--------------------------------------------------
local message_queue = {}
local send_message_jobid = -1

local function send_message_via_webhook(content)
  local webhook = config.config.integrations
    and config.config.integrations.dingtalk
    and config.config.integrations.dingtalk.webhook

  if not webhook then
    log.error('[DingTalk] webhook not configured')
    return
  end

  if send_message_jobid > 0 then
    return
  end

  send_message_jobid = job.start({
    'curl',
    '-s',
    '-X',
    'POST',
    webhook,
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
        send_message_via_webhook(table.remove(message_queue, 1))
      end
    end,
  })

  job.send(send_message_jobid, json.encode({
    msgtype = 'text',
    text = {
      content = content,
    },
  }))
  job.send(send_message_jobid, nil)
end

local function send_message_via_api(content)
  local conversation_id = config.config.integrations
    and config.config.integrations.dingtalk
    and config.config.integrations.dingtalk.conversation_id

  if not conversation_id then
    log.error('[DingTalk] conversation_id not configured')
    return
  end

  if send_message_jobid > 0 then
    return
  end

  ensure_token(function(token)
    send_message_jobid = job.start({
      'curl',
      '-s',
      '-X',
      'POST',
      API_BASE .. '/v1.0/robot/oToMessages/batchSend',
      '-H',
      'x-acs-dingtalk-access-token: ' .. token,
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
      on_exit = function()
        send_message_jobid = -1
        if #message_queue > 0 then
          send_message_via_api(table.remove(message_queue, 1))
        end
      end,
    })

    job.send(send_message_jobid, json.encode({
      robotCode = config.config.integrations.dingtalk.app_key,
      userIds = { config.config.integrations.dingtalk.user_id },
      msgKey = 'sampleText',
      msgParam = json.encode({ content = content }),
    }))
    job.send(send_message_jobid, nil)
  end)
end

function M.send_message(content)
  local max_length = 20000 -- DingTalk message limit
  local dingtalk_config = config.config.integrations
    and config.config.integrations.dingtalk

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
    -- Use webhook if available, otherwise use API
    if dingtalk_config and dingtalk_config.webhook then
      send_message_via_webhook()
    else
      send_message_via_api()
    end
  end
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

