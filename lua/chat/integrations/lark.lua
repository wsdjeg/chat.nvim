local M = {}

local config = require('chat.config')
local log = require('chat.log')
local job = require('job')

local json = vim.json
local uv = vim.uv

--------------------------------------------------
-- constants
--------------------------------------------------
local STATE_FILE = vim.fn.stdpath('data') .. '/chat-lark-state.json'
local API_BASE = 'https://open.feishu.cn/open-apis'

--------------------------------------------------
-- state
--------------------------------------------------
local state = {
  timer = nil,
  tenant_access_token = nil,
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
-- Save state to file
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
    log.error('[Lark] Failed to encode state')
    return false
  end

  local dir = vim.fn.fnamemodify(STATE_FILE, ':h')
  if vim.fn.isdirectory(dir) == 0 then
    vim.fn.mkdir(dir, 'p')
  end

  local file, err = io.open(STATE_FILE, 'w')
  if not file then
    log.error('[Lark] Failed to save state: ' .. (err or 'unknown'))
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
  if data.processed_ids then
    state.processed_ids = data.processed_ids
  end
  if data.session then
    state.session = data.session
  end

  log.debug('[Lark] State loaded')
  return true
end

--------------------------------------------------
-- Get tenant access token
--------------------------------------------------
local function get_tenant_access_token(callback)
  local app_id = config.config.integrations
    and config.config.integrations.lark
    and config.config.integrations.lark.app_id
  local app_secret = config.config.integrations
    and config.config.integrations.lark
    and config.config.integrations.lark.app_secret

  if not app_id or not app_secret then
    log.error('[Lark] app_id or app_secret not configured')
    return
  end

  local jobid = job.start({
    'curl',
    '-s',
    '-X',
    'POST',
    API_BASE .. '/auth/v3/tenant_access_token/internal',
    '-H',
    'Content-Type: application/json',
    '-d',
    json.encode({
      app_id = app_id,
      app_secret = app_secret,
    }),
  }, {
    on_stdout = function(_, lines)
      local output = table.concat(lines, '\n')
      if output and output ~= '' then
        local ok, result = pcall(json.decode, output)
        if ok and result and result.tenant_access_token then
          state.tenant_access_token = result.tenant_access_token
          state.token_expires_at = os.time() + (result.expire or 7200) - 300
          log.debug('[Lark] Token obtained')
          if callback then
            callback(result.tenant_access_token)
          end
        else
          log.error('[Lark] Failed to get token: ' .. output)
        end
      end
    end,
  })
end

--------------------------------------------------
-- Ensure valid token
--------------------------------------------------
local function ensure_token(callback)
  if state.tenant_access_token and os.time() < state.token_expires_at then
    callback(state.tenant_access_token)
  else
    get_tenant_access_token(callback)
  end
end

--------------------------------------------------
-- Fetch messages (FIXED)
--------------------------------------------------
local function fetch_messages()
  if state.is_fetching then
    return
  end

  local chat_id = config.config.integrations
    and config.config.integrations.lark
    and config.config.integrations.lark.chat_id

  if not chat_id then
    log.error('[Lark] chat_id not configured')
    return
  end

  state.is_fetching = true

  ensure_token(function(token)
    -- Updated endpoint with container_id_type and container_id
    local endpoint = API_BASE
      .. '/im/v1/messages?container_id_type=chat&container_id='
      .. chat_id
      .. '&page_size=50'

    local timeout = uv.new_timer()
    timeout:start(5000, 0, function()
      if state.is_fetching then
        log.warn('[Lark] Request timeout')
        state.is_fetching = false
      end
    end)

    -- FIX: Accumulate response data
    local response_chunks = {}

    job.start({
      'curl',
      '-sS',
      '--compressed',
      '-X',
      'GET',
      endpoint,
      '-H',
      'Authorization: Bearer ' .. token,
    }, {
      raw = true,

      on_stdout = function(_, data)
        for _, chunk in ipairs(data) do
          table.insert(response_chunks, chunk)
        end
      end,
      on_exit = function()
        timeout:stop()
        timeout:close()
        state.is_fetching = false
        local response = table.concat(response_chunks)
        if response == {} then
          return
        end

        local ok, result = pcall(json.decode, response)
        if not ok then
          log.error('[Lark] JSON decode failed: ' .. response)
          return
        end

        if not result then
          log.error('[Lark] Empty response')
          return
        end

        -- Check for API errors
        if result.code and result.code ~= 0 then
          log.error(
            '[Lark] API error ['
              .. result.code
              .. ']: '
              .. (result.msg or 'unknown')
          )
          return
        end

        -- Get messages from response
        local messages = {}
        if result.data and result.data.items then
          messages = result.data.items
        elseif result.items then
          messages = result.items
        else
          log.debug('[Lark] No messages in response')
          return
        end

        local has_new = false

        -- Process messages in chronological order (oldest first)
        for i = #messages, 1, -1 do
          local msg = messages[i]

          -- Skip already processed messages
          if state.processed_ids[msg.message_id] then
            goto continue
          end

          state.processed_ids[msg.message_id] = true
          has_new = true

          -- Skip bot messages (messages from this app itself)
          if msg.sender and msg.sender.sender_type == 'app' then
            goto continue
          end

          local content = msg.body and msg.body.content or ''
          if msg.msg_type == 'text' then
            local ok2, text_data = pcall(json.decode, content)
            if ok2 and text_data and text_data.text then
              content = text_data.text
            end
          end

          if content == '' then
            goto continue
          end

          -- Call callback with the message
          if state.callback then
            vim.schedule(function()
              state.callback({
                author = msg.sender and msg.sender.id or 'Unknown',
                content = content,
                message_id = msg.message_id,
              })
            end)
          end

          ::continue::
        end

        -- Save state if there are new messages
        if has_new then
          save_state()
        end
      end,
    })
  end)
end

--------------------------------------------------
-- Connect
--------------------------------------------------
function M.connect(callback)
  local lark_config = config.config.integrations
    and config.config.integrations.lark
  if
    not lark_config
    or not lark_config.app_id
    or not lark_config.app_secret
  then
    log.error('[Lark] app_id or app_secret not configured')
    return
  end

  if not lark_config.chat_id then
    log.error('[Lark] chat_id not configured')
    return
  end

  if state.is_running then
    return
  end

  state.callback = callback
  state.is_running = true

  load_state()
  log.info('[Lark] Starting polling...')

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

  log.info('[Lark] Polling started')
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
  log.info('[Lark] Polling stopped')
end

--------------------------------------------------
-- Send message
--------------------------------------------------
local message_queue = {}
local send_message_jobid = -1

local function send_message(content)
  local chat_id = config.config.integrations
    and config.config.integrations.lark
    and config.config.integrations.lark.chat_id

  if not chat_id then
    log.error('[Lark] chat_id not configured')
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
      API_BASE .. '/im/v1/messages?receive_id_type=chat_id',
      '-H',
      'Authorization: Bearer ' .. token,
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
        receive_id = chat_id,
        msg_type = 'text',
        content = json.encode({ text = content }),
      })
    )
    job.send(send_message_jobid, nil)
  end)
end

function M.send_message(content)
  local max_length = 30720 -- Lark message limit

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
