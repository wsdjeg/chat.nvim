-- lua/chat/integrations/weixin/login.lua
-- WeChat QR code login via OpenClaw gateway

local M = {}

local log = require('chat.log')
local Api = require('chat.integrations.weixin.api')
local job = require('job')

local json = vim.json
local uv = vim.uv

--------------------------------------------------
-- Constants
--------------------------------------------------
local DEFAULT_BOT_TYPE = '3'
local QR_LONG_POLL_TIMEOUT = 35000 -- 35 seconds
local LOGIN_TTL = 300000 -- 5 minutes

--------------------------------------------------
-- Login state
--------------------------------------------------
local login_state = {
  session_key = nil,
  qrcode = nil,
  qrcode_url = nil,
  started_at = nil,
  status = nil, -- wait, scaned, confirmed, expired
}

--------------------------------------------------
-- Check if login is fresh
--------------------------------------------------
local function is_login_fresh()
  if not login_state.started_at then
    return false
  end
  return (uv.now() - login_state.started_at) < LOGIN_TTL
end

--------------------------------------------------
-- Display QR code as ASCII art
--------------------------------------------------
local qr_buf = -1
local qr_win = -1
local function display_qrcode(url)
  M.close_qrcode()
  local cmd = 'npx -y qrcode-terminal "' .. url .. '"'

  if not vim.api.nvim_buf_is_valid(qr_buf) then
    qr_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_option_value('modifiable', false, { buf = qr_buf })
  end

  if not vim.api.nvim_win_is_valid(qr_win) then
    qr_win = vim.api.nvim_open_win(qr_buf, false, {
      relative = 'editor',
      width = 80,
      height = 40,
      row = 5,
      col = 5,
      style = 'minimal',
      border = 'rounded',
    })
  end

  vim.api.nvim_buf_call(qr_buf, function()
    vim.fn.jobstart(cmd, {
      term = true,
    })
  end)
end

--------------------------------------------------
-- Start QR code login
--------------------------------------------------
function M.start_qr_login(opts)
  opts = opts or {}

  local bot_type = opts.bot_type or DEFAULT_BOT_TYPE
  local url = Api.BASE_URL
    .. '/ilink/bot/get_bot_qrcode?bot_type='
    .. bot_type

  log.info('[Weixin] Fetching QR code...')

  -- Generate session key
  login_state.session_key = opts.session_key
    or tostring(os.time()) .. math.random(1000, 9999)
  login_state.status = 'wait'

  -- Fetch QR code (GET request)
  local result = {}
  local jobid = job.start({
    'curl',
    '-s',
    '-X',
    'GET',
    url,
    '--connect-timeout',
    '10',
    '--max-time',
    '30',
  }, {
    on_stdout = function(_, data)
      for _, line in ipairs(data) do
        if line and line ~= '' then
          table.insert(result, line)
        end
      end
    end,
    on_exit = function(_, code)
      if code ~= 0 then
        log.error('[Weixin] Failed to fetch QR code')
        if opts.callback then
          opts.callback(nil, 'Failed to fetch QR code')
        end
        return
      end

      local output = table.concat(result, '\n')
      local ok, resp = pcall(json.decode, output)

      if not ok or not resp then
        log.error('[Weixin] Invalid QR code response: ' .. output)
        if opts.callback then
          opts.callback(nil, 'Invalid response')
        end
        return
      end

      if not resp.qrcode or not resp.qrcode_img_content then
        log.error('[Weixin] No QR code in response')
        if opts.callback then
          opts.callback(nil, 'No QR code in response')
        end
        return
      end

      -- Save login state
      login_state.qrcode = resp.qrcode
      login_state.qrcode_url = resp.qrcode_img_content
      login_state.started_at = uv.now()
      login_state.status = 'wait'

      log.info('[Weixin] QR code obtained')

      -- Display QR code as ASCII art
      display_qrcode(resp.qrcode_img_content)

      if opts.callback then
        opts.callback({
          qrcode_url = resp.qrcode_img_content,
          qrcode = resp.qrcode,
          session_key = login_state.session_key,
          message = '请使用微信扫描二维码',
        }, nil)
      end
    end,
  })

  return jobid
end

--------------------------------------------------
-- Poll QR code status
--------------------------------------------------
local function poll_qr_status(callback)
  if not login_state.qrcode then
    callback(nil, 'No active QR code')
    return
  end

  local url = Api.BASE_URL
    .. '/ilink/bot/get_qrcode_status?qrcode='
    .. login_state.qrcode

  local result = {}
  job.start({
    'curl',
    '-s',
    '-X',
    'GET',
    url,
    '-H',
    'iLink-App-ClientVersion: 1',
    '--connect-timeout',
    '10',
    '--max-time',
    tostring(math.floor(QR_LONG_POLL_TIMEOUT / 1000)),
  }, {
    on_stdout = function(_, data)
      for _, line in ipairs(data) do
        if line and line ~= '' then
          table.insert(result, line)
        end
      end
    end,
    on_exit = function(_, code)
      if code ~= 0 then
        -- Timeout is normal for long-poll
        callback({ status = 'wait' }, nil)
        return
      end

      local output = table.concat(result, '\n')
      local ok, resp = pcall(json.decode, output)

      if not ok or not resp then
        callback(nil, 'Invalid response')
        return
      end

      callback(resp, nil)
    end,
  })
end

--------------------------------------------------
-- Wait for login (poll until confirmed or expired)
--------------------------------------------------
function M.wait_for_login(opts)
  opts = opts or {}

  if not is_login_fresh() then
    if opts.callback then
      opts.callback(nil, 'QR code expired')
    end
    return nil
  end

  local timeout_ms = opts.timeout_ms or 480000 -- 8 minutes
  local deadline = uv.now() + timeout_ms
  local poll_interval = 1000 -- 1 second
  local scanned_printed = false
  local qr_refresh_count = 0
  local max_qr_refresh = 3

  local function poll()
    if uv.now() > deadline then
      log.warn('[Weixin] Login timeout')
      login_state.status = nil
      if opts.callback then
        opts.callback(nil, 'Login timeout')
      end
      return
    end

    if not is_login_fresh() then
      log.warn('[Weixin] QR code expired')
      login_state.status = nil
      if opts.callback then
        opts.callback(nil, 'QR code expired')
      end
      return
    end

    poll_qr_status(function(resp, err)
      if err then
        log.error('[Weixin] Poll error: ' .. err)
        -- Continue polling on error
        vim.defer_fn(poll, poll_interval)
        return
      end

      login_state.status = resp.status

      if resp.status == 'wait' then
        -- Still waiting, continue polling
        vim.defer_fn(poll, poll_interval)
      elseif resp.status == 'scaned' then
        -- Scanned, waiting for confirmation
        if not scanned_printed then
          log.info('[Weixin] QR code scanned, waiting for confirmation...')
          scanned_printed = true
        end
        vim.defer_fn(poll, poll_interval)
      elseif resp.status == 'expired' then
        -- QR code expired, refresh
        qr_refresh_count = qr_refresh_count + 1

        if qr_refresh_count > max_qr_refresh then
          log.warn('[Weixin] QR code expired too many times')
          login_state.status = nil
          if opts.callback then
            opts.callback(nil, 'QR code expired too many times')
          end
          return
        end

        log.info('[Weixin] QR code expired, refreshing...')

        -- Get new QR code
        M.start_qr_login({
          session_key = login_state.session_key,
          callback = function(result, refresh_err)
            if refresh_err then
              login_state.status = nil
              if opts.callback then
                opts.callback(
                  nil,
                  'Failed to refresh QR code: ' .. refresh_err
                )
              end
              return
            end

            -- Notify with new QR code (已自动显示)
            if opts.on_qr_refresh then
              opts.on_qr_refresh(result.qrcode_url)
            end

            -- Continue polling
            scanned_printed = false
            vim.defer_fn(poll, poll_interval)
          end,
        })
      elseif resp.status == 'confirmed' then
        -- Login confirmed!
        if not resp.ilink_bot_id then
          log.error('[Weixin] Login confirmed but missing ilink_bot_id')
          login_state.status = nil
          if opts.callback then
            opts.callback(nil, 'Login failed: missing bot ID')
          end
          return
        end

        log.info('[Weixin] Login confirmed! bot_id=' .. resp.ilink_bot_id)

        login_state.status = 'confirmed'

        M.close_qrcode()

        if opts.callback then
          opts.callback({
            connected = true,
            bot_token = resp.bot_token,
            account_id = resp.ilink_bot_id,
            base_url = resp.baseurl,
            user_id = resp.ilink_user_id,
            message = '✅ 微信登录成功！',
          }, nil)
        end
      end
    end)
  end

  -- Start polling
  poll()

  return true
end

--------------------------------------------------
-- Get current login state
--------------------------------------------------
function M.get_state()
  return {
    session_key = login_state.session_key,
    qrcode_url = login_state.qrcode_url,
    started_at = login_state.started_at,
    status = login_state.status,
    is_fresh = is_login_fresh(),
  }
end

--------------------------------------------------
-- Clear login state
--------------------------------------------------
function M.clear()
  login_state = {
    session_key = nil,
    qrcode = nil,
    qrcode_url = nil,
    started_at = nil,
    status = nil,
  }
end

M.display_qrcode = display_qrcode
M.close_qrcode = function()
  if vim.api.nvim_win_is_valid(qr_win) then
    vim.api.nvim_win_close(qr_win, true)
  end
  if vim.api.nvim_buf_is_valid(qr_buf) then
    vim.api.nvim_buf_delete(qr_buf, {
      force = true,
      unload = false,
    })
  end
end

return M
