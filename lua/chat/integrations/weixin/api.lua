-- lua/chat/integrations/weixin/api.lua
-- https://raw.githubusercontent.com/epiral/weixin-bot/refs/heads/main/PROTOCOL.md
-- WeChat API wrapper (via OpenClaw gateway)

local M = {}

local config = require('chat.config')
local log = require('chat.log')
local job = require('job')

local json = vim.json
local Types = require('chat.integrations.weixin.types')

--------------------------------------------------
-- Constants
--------------------------------------------------
M.BASE_URL = 'https://ilinkai.weixin.qq.com'
M.CDN_BASE_URL = 'https://novac2c.cdn.weixin.qq.com/c2c'

-- API endpoints
M.Endpoints = {
  GET_UPDATES = 'ilink/bot/getupdates',
  SEND_MESSAGE = 'ilink/bot/sendmessage',
  GET_UPLOAD_URL = 'ilink/bot/getuploadurl',
  SEND_TYPING = 'ilink/bot/sendtyping',
  GET_CONFIG = 'ilink/bot/getconfig',
}

-- SDK version
M.CHANNEL_VERSION = '1.0.0'

--------------------------------------------------
-- Generate random X-WECHAT-UIN header
--------------------------------------------------
local function generate_wechat_uin()
  local rand = math.random(1, 4294967295) -- uint32
  return vim.base64.encode(tostring(rand))
end

--------------------------------------------------
-- Build request headers
--------------------------------------------------
local function build_headers(token)
  return {
    'Content-Type: application/json',
    'AuthorizationType: ilink_bot_token',
    'Authorization: Bearer ' .. token,
    'X-WECHAT-UIN: ' .. generate_wechat_uin(),
  }
end

--------------------------------------------------
-- Build base_info
--------------------------------------------------
local function build_base_info()
  return {
    channel_version = M.CHANNEL_VERSION,
  }
end

--------------------------------------------------
-- Get config
--------------------------------------------------
local function get_config()
  local weixin_config = config.config.integrations
    and config.config.integrations.weixin
  if not weixin_config then
    return nil, 'Integration not configured'
  end

  local token = weixin_config.token
  local default_user_id = weixin_config.default_user_id

  if not token then
    return nil, 'Missing token'
  end

  return {
    token = token,
    default_user_id = default_user_id,
  }
end

--------------------------------------------------
-- API request helper
--------------------------------------------------
function M.request(endpoint, data, callback, opts)
  opts = opts or {}

  local cfg, err = get_config()
  if not cfg then
    log.error('[Weixin] ' .. err)
    if callback then
      callback(nil, err)
    end
    return nil
  end

  local url = M.BASE_URL .. '/' .. endpoint
  local headers = build_headers(cfg.token)

  local cmd = {
    'curl',
    '-s',
    '-X',
    'POST',
    url,
    '--connect-timeout',
    '10',
    '--max-time',
    tostring(opts.timeout or Types.Timeout.API_REQUEST),
  }

  for _, h in ipairs(headers) do
    table.insert(cmd, '-H')
    table.insert(cmd, h)
  end

  if data then
    -- Add base_info to all business requests
    data.base_info = data.base_info or build_base_info()

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
            callback(result, nil)
          else
            log.error('[Weixin] Failed to decode: ' .. output)
            callback(nil, 'Decode error')
          end
        else
          callback(nil, 'Empty response')
        end
      end
    end,
    on_stderr = function(_, lines)
      for _, line in ipairs(lines) do
        if line and line ~= '' then
          log.debug('[Weixin] ' .. line)
        end
      end
    end,
    on_exit = function(_, code, signal)
      if opts.on_exit then
        opts.on_exit(code, signal)
      end
    end,
  })

  if data and jobid then
    job.send(jobid, json.encode(data))
    job.send(jobid, nil)
  end

  return jobid
end

--------------------------------------------------
-- Get config (for typing_ticket)
--------------------------------------------------
function M.get_config(user_id, callback)
  M.request(M.Endpoints.GET_CONFIG, {
    ilink_user_id = user_id,
  }, function(result, err)
    if err then
      callback(nil, err)
      return
    end

    if result and result.ret == 0 and result.typing_ticket then
      callback(result.typing_ticket, nil)
    else
      callback(nil, result and result.errmsg or 'No typing ticket')
    end
  end, {
    timeout = Types.Timeout.CONFIG_REQUEST,
  })
end

--------------------------------------------------
-- Send typing indicator
--------------------------------------------------
function M.send_typing(user_id, typing_ticket, is_typing, callback)
  M.request(M.Endpoints.SEND_TYPING, {
    ilink_user_id = user_id,
    typing_ticket = typing_ticket,
    status = is_typing and Types.TypingStatus.TYPING
      or Types.TypingStatus.CANCEL,
  }, function(result, err)
    if callback then
      callback(result, err)
    end
  end, {
    timeout = Types.Timeout.CONFIG_REQUEST,
  })
end

--------------------------------------------------
-- Get updates (long-poll)
--------------------------------------------------
function M.get_updates(get_updates_buf, callback)
  M.request(
    M.Endpoints.GET_UPDATES,
    {
      get_updates_buf = get_updates_buf or '',
    },
    callback,
    {
      timeout = Types.Timeout.LONG_POLL,
    }
  )
end

--------------------------------------------------
-- Generate or get session client ID
--------------------------------------------------
local function get_client_id()
  return string.format(
    'openclaw-weixin:%d-%s',
    os.time() * 1000, -- 毫秒时间戳
    vim.base64.encode(tostring(math.random(1, 99999999)))
  )
end

--------------------------------------------------
-- Send message
--------------------------------------------------
function M.send_message(to_user_id, context_token, content, callback)
  -- Validate context_token (required by API)
  if not context_token or context_token == '' then
    log.error('[Weixin] Cannot send message: missing context_token')
    if callback then
      callback(nil, 'Missing context_token')
    end
    return
  end

  M.request(M.Endpoints.SEND_MESSAGE, {
    msg = {
      from_user_id = '',
      to_user_id = to_user_id,
      client_id = get_client_id(),
      message_type = Types.MessageType.BOT,
      message_state = Types.MessageState.FINISH,
      context_token = context_token,
      item_list = {
        {
          type = Types.MessageItemType.TEXT,
          text_item = { text = content },
        },
      },
    },
  }, function(result, err)
    if callback then
      callback(result, err)
    end
  end)
end

--------------------------------------------------
-- Get default user ID
--------------------------------------------------
function M.get_default_user_id()
  local cfg, _ = get_config()
  return cfg and cfg.default_user_id
end

function M.is_configured()
  local cfg, err = get_config()
  return cfg ~= nil, err
end

--------------------------------------------------
-- Set credentials dynamically
--------------------------------------------------
function M.set_credentials(token, account_id, base_url)
  -- 更新 config
  if not config.config.integrations then
    config.config.integrations = {}
  end

  if not config.config.integrations.weixin then
    config.config.integrations.weixin = {}
  end

  config.config.integrations.weixin.token = token

  if account_id then
    config.config.integrations.weixin.default_user_id = account_id
  end

  if base_url then
    M.BASE_URL = base_url
  end

  log.info('[Weixin] Credentials updated')
end

return M
