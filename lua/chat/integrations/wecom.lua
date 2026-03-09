local M = {}

local config = require('chat.config')
local log = require('chat.log')
local job = require('job')

local json = vim.json
local uv = vim.uv

--------------------------------------------------
-- constants
--------------------------------------------------
local STATE_FILE = vim.fn.stdpath('data') .. '/chat-wecom-state.json'
local API_BASE = 'https://qyapi.weixin.qq.com/cgi-bin'

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
  local corp_id = config.config.integrations
    and config.config.integrations.wecom
    and config.config.integrations.wecom.corp_id
  local corp_secret = config.config.integrations
    and config.config.integrations.wecom
    and config.config.integrations.wecom.corp_secret

  if not corp_id or not corp_secret then
    log.error('[WeCom] corp_id or corp_secret not configured')
    return
  end

  job.start({
    'curl',
    '-s',
    '-X',
    'GET',
    API_BASE
      .. '/gettoken?corpid='
      .. corp_id
      .. '&corpsecret='
      .. corp_secret,
  }, {
    on_stdout = function(_, lines)
      local output = table.concat(lines, '\n')
      local ok, result = pcall(json.decode, output)
      if ok and result and result.access_token then
        state.access_token = result.access_token
        state.token_expires_at = os.time() + (result.expires_in or 7200) - 300
        log.debug('[WeCom] Token obtained')
        if callback then
          callback(result.access_token)
        end
      else
        log.error('[WeCom] Failed to get token: ' .. output)
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
-- Fetch messages (using webhook or callback mode)
--------------------------------------------------
local function fetch_messages()
  -- WeCom webhook is one-way only
  -- For two-way, need to setup callback server
  -- This is a placeholder
end

--------------------------------------------------
-- Connect
--------------------------------------------------
function M.connect(callback)
  local wecom_config = config.config.integrations
    and config.config.integrations.wecom

  if not wecom_config then
    log.error('[WeCom] Configuration not found')
    return
  end

  -- Support both webhook mode and API mode
  if not wecom_config.webhook_key and not wecom_config.corp_id then
    log.error('[WeCom] webhook_key or corp_id not configured')
    return
  end

  if state.is_running then
    return
  end

  state.callback = callback
  state.is_running = true

  load_state()
  log.info('[WeCom] Starting...')

  -- Only start polling for API mode
  if wecom_config.corp_id and wecom_config.corp_secret then
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

  log.info('[WeCom] Started')
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
  log.info('[WeCom] Stopped')
end

--------------------------------------------------
-- Send message via webhook
--------------------------------------------------
local message_queue = {}
local send_message_jobid = -1

local function send_message_via_webhook(content)
  local webhook_key = config.config.integrations
    and config.config.integrations.wecom
    and config.config.integrations.wecom.webhook_key

  if not webhook_key then
    log.error('[WeCom] webhook_key not configured')
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
    'https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=' .. webhook_key,
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

  job.send(
    send_message_jobid,
    json.encode({
      msgtype = 'text',
      text = {
        content = content,
      },
    })
  )
  job.send(send_message_jobid, nil)
end

local function send_message_via_api(content)
  local agent_id = config.config.integrations
    and config.config.integrations.wecom
    and config.config.integrations.wecom.agent_id
  local user_id = config.config.integrations
    and config.config.integrations.wecom
    and config.config.integrations.wecom.user_id

  if not agent_id or not user_id then
    log.error('[WeCom] agent_id or user_id not configured')
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
      API_BASE .. '/message/send?access_token=' .. token,
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

    job.send(
      send_message_jobid,
      json.encode({
        touser = user_id,
        msgtype = 'text',
        agentid = agent_id,
        text = {
          content = content,
        },
      })
    )
    job.send(send_message_jobid, nil)
  end)
end

function M.send_message(content)
  local max_length = 2048 -- WeCom message limit
  local wecom_config = config.config.integrations
    and config.config.integrations.wecom

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
    if wecom_config and wecom_config.webhook_key then
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
