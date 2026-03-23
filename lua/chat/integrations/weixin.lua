-- lua/chat/integrations/weixin.lua
-- WeChat integration via OpenClaw gateway

local M = {}

local log = require('chat.log')
local uv = vim.uv

local State = require('chat.integrations.weixin.state')
local Api = require('chat.integrations.weixin.api')
local Message = require('chat.integrations.weixin.message')
local Types = require('chat.integrations.weixin.types')

--------------------------------------------------
-- Message queue for sending
--------------------------------------------------
local message_queue = {}
local send_jobid = -1

--------------------------------------------------
-- Process message queue
--------------------------------------------------
local function process_queue()
  if #message_queue == 0 then
    return
  end

  if send_jobid > 0 then
    return
  end

  local msg_data = table.remove(message_queue, 1)
  local default_user_id = Api.get_default_user_id()
  -- 优先使用 last_from_user_id
  local to_user_id = msg_data.to_user_id
    or State.get_last_from_user_id()
    or default_user_id

  if not to_user_id then
    log.error('[Weixin] No user_id to send to')
    -- Process next message
    vim.schedule(process_queue)
    return
  end

  local context_token = msg_data.context_token
    or State.get_context_token(to_user_id)

  log.debug(
    string.format(
      '[Weixin] Getting context_token for user %s: %s',
      to_user_id,
      context_token and (context_token:sub(1, 20) .. '...') or 'nil'
    )
  )
  send_jobid = Api.send_message(
    to_user_id,
    context_token,
    msg_data.content,
    function(result, err)
      -- Reset job ID in callback
      send_jobid = -1

      log.debug(vim.inspect(result))

      if err then
        log.error('[Weixin] Failed to send message: ' .. err)
      elseif not result then
        log.error('[Weixin] Failed to send message: empty response')
      elseif result.ret and result.ret ~= 0 then
        log.error('[Weixin] Failed to send message:')
        log.error('  ret=' .. (result.ret or '?'))
        log.error('  errcode=' .. (result.errcode or '?'))
        log.error('  errmsg=' .. (result.errmsg or 'unknown'))
        log.error('  Full response: ' .. vim.json.encode(result))

        -- Session expired
        if
          result.ret == -14
          or result.errcode == Types.ErrorCode.SESSION_EXPIRED
        then
          log.error('[Weixin] Session expired, please re-login')
          State.clear_credentials()
        end
      else
         log.debug(string.format('[Weixin] Message sent to %s', to_user_id))
      end

      -- Process next message in queue
      if #message_queue > 0 then
        vim.schedule(process_queue)
      end
    end
  )
end

--------------------------------------------------
-- Split long messages
--------------------------------------------------
local function split_message(content, max_length)
  if #content <= max_length then
    return { content }
  end

  local chunks = {}
  local remaining = content

  while #remaining > 0 do
    local chunk
    if #remaining <= max_length then
      chunk = remaining
      remaining = ''
    else
      -- Try to split at newline
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
    table.insert(chunks, chunk)
  end

  return chunks
end

--------------------------------------------------
-- Long-poll for updates
--------------------------------------------------
local function poll_updates()
  if State.is_polling() then
    return
  end

  State.set_polling(true)

  Api.get_updates(State.get_updates_buf(), function(result, err)
    State.set_polling(false)

    if err then
      log.error('[Weixin] getupdates error: ' .. err)
      -- Retry after 3 seconds
      return
    end

    if not result then
      log.error('[Weixin] Empty response from getupdates')
      return
    end

    -- Check for errors (ret is optional, nil or 0 means success)
    if result.ret and result.ret ~= 0 then
      log.error('[Weixin] getupdates failed:')
      log.error('  ret=' .. (result.ret or '?'))
      log.error('  errcode=' .. (result.errcode or '?'))
      log.error('  errmsg=' .. (result.errmsg or 'unknown'))

      -- Session expired
      if
        result.ret == -14
        or result.errcode == Types.ErrorCode.SESSION_EXPIRED
      then
        log.error('[Weixin] Session expired, please re-login')
        State.clear_credentials()
      end
      return
    end

    -- Update sync cursor
    if result.get_updates_buf then
      State.set_updates_buf(result.get_updates_buf)
      State.save()
    end

    -- Process messages
    if result.msgs and #result.msgs > 0 then
      local state = State.get()
      local inbound =
        Message.extract_inbound(result.msgs, state.context_tokens)

      -- Update last sender
      if #inbound > 0 then
        State.set_last_from_user_id(inbound[#inbound].user_id)
      end

      -- Save context tokens
      State.save()

      -- Trigger callbacks
      local callback = State.get_callback()
      if callback then
        for _, msg in ipairs(inbound) do
          vim.schedule(function()
            callback(msg)
          end)
        end
      end
    end
  end)
end

--------------------------------------------------
-- Get typing ticket (lazy load)
--------------------------------------------------
local function ensure_typing_ticket(user_id, callback)
  local ticket = State.get_typing_ticket(user_id)
  if ticket then
    callback(ticket)
    return
  end

  Api.get_config(user_id, function(new_ticket, err)
    if err then
      log.warn('[Weixin] Failed to get typing ticket: ' .. err)
      return
    end

    State.set_typing_ticket(user_id, new_ticket)
    callback(new_ticket)
  end)
end

--------------------------------------------------
-- Public API: Connect
--------------------------------------------------
function M.connect(callback)
  if State.is_running() then
    log.warn('[Weixin] Already running')
    return
  end

  -- Load saved state first
  State.load()

  -- 检查是否有缓存的登录凭证
  if State.has_credentials() then
    local creds = State.get_credentials()
    log.info('[Weixin] Found cached credentials, using token...')

    -- 设置 API 使用缓存的 token
    Api.set_credentials(creds.bot_token, creds.account_id, creds.base_url)
  end

  -- Now check config (after setting cached credentials)
  local configured, err = Api.is_configured()
  if not configured then
    log.error('[Weixin] Configuration error: ' .. (err or 'unknown'))
    return
  end

  State.set_callback(callback)
  State.set_running(true)

  log.info('[Weixin] Starting long-polling...')

  -- Start polling timer
  local timer = uv.new_timer()
  State.set_timer(timer)

  timer:start(
    0,
    3000,
    vim.schedule_wrap(function()
      if State.is_running() then
        poll_updates()
      end
    end)
  )

  log.info('[Weixin] Connected')
end

--------------------------------------------------
-- Public API: Disconnect
--------------------------------------------------
function M.disconnect()
  local timer = State.get_timer()
  if timer then
    timer:stop()
    timer:close()
    State.set_timer(nil)
  end

  State.set_running(false)
  State.set_polling(false)
  State.set_callback(nil)

  State.save()

  log.info('[Weixin] Disconnected')
end

--------------------------------------------------
-- Public API: Send message
--------------------------------------------------
function M.send_message(content, user_id)
  if not content or content == '' then
    return
  end

  -- Split long messages
  local chunks = split_message(content, Types.Limits.MAX_MESSAGE_LENGTH)

  for _, chunk in ipairs(chunks) do
    if #message_queue < Types.Limits.MAX_QUEUE_SIZE then
      table.insert(message_queue, {
        content = chunk,
        to_user_id = user_id,
      })
    else
      log.warn('[Weixin] Message queue full, dropping message')
    end
  end

  process_queue()
end

--------------------------------------------------
-- Public API: Send typing indicator
--------------------------------------------------
function M.send_typing(user_id, is_typing)
  if not user_id then
    return
  end

  ensure_typing_ticket(user_id, function(ticket)
    if ticket then
      Api.send_typing(user_id, ticket, is_typing)
    end
  end)
end

--------------------------------------------------
-- Public API: Current session
--------------------------------------------------
function M.current_session()
  return State.get_session()
end

--------------------------------------------------
-- Public API: Set session
--------------------------------------------------
function M.set_session(session)
  State.set_session(session)
end

--------------------------------------------------
-- Public API: Get state info
--------------------------------------------------
function M.get_state()
  return State.get_info()
end

--------------------------------------------------
-- Public API: Clear state
--------------------------------------------------
function M.clear_state()
  State.clear()
  message_queue = {}
  log.info('[Weixin] State cleared')
end

--------------------------------------------------
-- Public API: Cleanup
--------------------------------------------------
function M.cleanup()
  M.disconnect()
end

--------------------------------------------------
-- Login support
--------------------------------------------------
local Login = require('chat.integrations.weixin.login')

--------------------------------------------------
-- Public API: Start QR code login
--------------------------------------------------
function M.login(callback)
  log.info('[Weixin] Starting QR code login...')

  Login.start_qr_login({
    callback = function(result, err)
      if err then
        log.error('[Weixin] Login failed: ' .. err)
        if callback then
          callback(nil, err)
        end
        return
      end

      -- Start waiting for login (QR already displayed by start_qr_login)
      Login.wait_for_login({
        timeout_ms = 480000, -- 8 minutes
        on_qr_refresh = function(new_qr_url)
          Login.display_qrcode(new_qr_url)
        end,
        callback = function(login_result, login_err)
          if login_err then
            log.error('[Weixin] ' .. login_err)
            if callback then
              callback(nil, login_err)
            end
            return
          end

          -- Login successful
          log.info('')
          log.info('✅ ' .. login_result.message)
          log.info('Bot Token: ' .. (login_result.bot_token or 'N/A'))
          log.info('Account ID: ' .. (login_result.account_id))

          -- 保存登录凭证到 state
          State.set_credentials({
            bot_token = login_result.bot_token,
            account_id = login_result.account_id,
            base_url = login_result.base_url,
            user_id = login_result.user_id,
          })
          State.save()
          log.info('[Weixin] Credentials saved')

          -- 同时更新 API 配置
          Api.set_credentials(
            login_result.bot_token,
            login_result.account_id,
            login_result.base_url
          )

          if callback then
            callback(login_result, nil)
          end
        end,
      })
    end,
  })
end

--------------------------------------------------
-- Public API: Get login state
--------------------------------------------------
function M.get_login_state()
  return Login.get_state()
end

--------------------------------------------------
-- Public API: Logout
--------------------------------------------------
function M.logout()
  M.disconnect()
  State.clear()
  log.info('[Weixin] Logged out, credentials cleared')
end

return M
