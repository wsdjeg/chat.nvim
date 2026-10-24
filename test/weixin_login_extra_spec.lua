-- Coverage for chat/integrations/weixin/login.lua:
-- QR fetch (success / failure / invalid / missing fields) incl. the ASCII
-- qrcode window, the poll state machine (wait / scaned / expired refresh
-- incl. refresh exhaustion and refresh failure / confirmed with and without
-- bot id / poll errors / timeout), the combined login flow and the login
-- state accessors.

local lu = require('luaunit')
local job = require('job')
local curl = require('chat.curl')
local login = require('chat.integrations.weixin.login')

TestWeixinLoginExtra = {}

function TestWeixinLoginExtra:setUp()
  job.reset()
  job.intercept(true)

  login.clear()

  self.orig = {}
  self.build_calls = {}
  self.orig_build = curl.build_request
  curl.build_request = function(opts)
    table.insert(self.build_calls, opts)
    return { 'curl', opts.url }
  end

  self.defer_orig = vim.defer_fn
  self.deferred = {}
  vim.defer_fn = function(fn, delay)
    table.insert(self.deferred, { fn = fn, delay = delay })
    return { stop = function() end }
  end

  -- avoid opening a real terminal inside the qr buffer
  self.jobstart_orig = vim.fn.jobstart
  self.jobstarts = {}
  vim.fn.jobstart = function(cmd, opts)
    table.insert(self.jobstarts, { cmd = cmd, opts = opts })
    return 1
  end
end

function TestWeixinLoginExtra:tearDown()
  curl.build_request = self.orig_build
  vim.defer_fn = self.defer_orig
  vim.fn.jobstart = self.jobstart_orig
  login.close_qrcode()
  login.clear()
  job.reset()
end

--- Drive a QR fetch job: emit the given stdout lines and exit code.
local function finish_job(jobid, lines, code)
  if lines then
    job.emit_stdout(jobid, lines)
  end
  job.emit_exit(jobid, code or 0, 0)
end

local QR_RESPONSE = vim.json.encode({
  qrcode = 'QR-CODE-VALUE',
  qrcode_img_content = 'https://example.com/qr.png',
})

function TestWeixinLoginExtra:testStartQrLoginSuccessWithDisplay()
  local result
  local jobid = login.start_qr_login({
    callback = function(res, err)
      result = { res = res, err = err }
    end,
  })
  lu.assertNumber(jobid)
  finish_job(jobid, { QR_RESPONSE }, 0)

  lu.assertNil(result.err)
  lu.assertEquals('https://example.com/qr.png', result.res.qrcode_url)
  lu.assertEquals('QR-CODE-VALUE', result.res.qrcode)
  lu.assertNotNil(result.res.session_key)
  -- the QR window opens and a terminal job renders the code
  lu.assertEquals(1, #self.jobstarts)
  lu.assertStrContains(self.jobstarts[1].cmd, 'qrcode-terminal')
  -- state
  local state = login.get_state()
  lu.assertEquals('wait', state.status)
  lu.assertTrue(state.is_fresh)
  lu.assertEquals('https://example.com/qr.png', state.qrcode_url)
end

function TestWeixinLoginExtra:testStartQrLoginFetchFailure()
  local result
  local jobid = login.start_qr_login({
    callback = function(res, err)
      result = { res = res, err = err }
    end,
  })
  finish_job(jobid, nil, 7)
  lu.assertNil(result.res)
  lu.assertEquals('Failed to fetch QR code', result.err)
end

function TestWeixinLoginExtra:testStartQrLoginInvalidJson()
  local result
  local jobid = login.start_qr_login({
    callback = function(res, err)
      result = { res = res, err = err }
    end,
  })
  finish_job(jobid, { 'not json at all' }, 0)
  lu.assertEquals('Invalid response', result.err)
end

function TestWeixinLoginExtra:testStartQrLoginNoQrcodeFields()
  local result
  local jobid = login.start_qr_login({
    callback = function(res, err)
      result = { res = res, err = err }
    end,
  })
  finish_job(jobid, { vim.json.encode({ hello = 'world' }) }, 0)
  lu.assertEquals('No QR code in response', result.err)
end

--- Start a fresh login and answer the first poll with the given response.
local function start_and_poll(self, poll_response, poll_exit_code)
  login.start_qr_login({ skip_display = true })
  local qr_jobid = 1
  finish_job(qr_jobid, { QR_RESPONSE }, 0)

  local cb_result
  login.wait_for_login({
    callback = function(res, err)
      cb_result = { res = res, err = err }
    end,
  })
  -- the poll job is the newest intercepted job
  local poll_jobid = #job.jobs
  finish_job(poll_jobid, { vim.json.encode(poll_response) }, poll_exit_code or 0)
  return cb_result
end

function TestWeixinLoginExtra:testPollWaitKeepsPolling()
  local cb_result = start_and_poll(self, { status = 'wait' })
  lu.assertNil(cb_result)
  lu.assertTrue(#self.deferred >= 1)
  -- a follow-up poll was scheduled
  self.deferred[#self.deferred].fn()
  lu.assertTrue(#job.jobs >= 3)
end

function TestWeixinLoginExtra:testPollScanedKeepsPolling()
  local cb_result = start_and_poll(self, { status = 'scaned' })
  lu.assertNil(cb_result)
  lu.assertTrue(#self.deferred >= 1)
end

function TestWeixinLoginExtra:testPollLongPollTimeoutReportsWait()
  -- exit code != 0 is treated as a long-poll timeout: keep polling
  local cb_result = start_and_poll(self, { status = 'wait' }, 28)
  lu.assertNil(cb_result)
  lu.assertTrue(#self.deferred >= 1)
end

function TestWeixinLoginExtra:testPollInvalidResponseContinues()
  login.start_qr_login({ skip_display = true })
  finish_job(1, { QR_RESPONSE }, 0)
  local cb_result
  login.wait_for_login({
    callback = function(res, err)
      cb_result = { res = res, err = err }
    end,
  })
  finish_job(#job.jobs, { 'garbage' }, 0)
  -- poll error: keep polling instead of failing the login
  lu.assertNil(cb_result)
  lu.assertTrue(#self.deferred >= 1)
end

function TestWeixinLoginExtra:testPollConfirmedStoresResult()
  local on_success = {}
  local cb_result = start_and_poll(self, {
    status = 'confirmed',
    ilink_bot_id = 'bot-1',
    ilink_user_id = 'user-9',
    bot_token = 'tok',
    baseurl = 'https://gw.example.com',
  })
  lu.assertNil(cb_result.err)
  lu.assertEquals('bot-1', cb_result.res.account_id)
  lu.assertEquals('tok', cb_result.res.bot_token)

  local state = login.get_state()
  lu.assertEquals('confirmed', state.status)
  lu.assertEquals('tok', state.bot_token)
  lu.assertEquals('bot-1', state.account_id)
  lu.assertEquals('user-9', state.user_id)
end

function TestWeixinLoginExtra:testPollConfirmedMissingBotIdFails()
  local cb_result = start_and_poll(self, {
    status = 'confirmed',
  })
  lu.assertNil(cb_result.res)
  lu.assertEquals('Login failed: missing bot ID', cb_result.err)
  lu.assertEquals('expired', login.get_state().status)
end

function TestWeixinLoginExtra:testPollExpiredRefreshesQrCode()
  login.start_qr_login({ skip_display = true })
  finish_job(1, { QR_RESPONSE }, 0)
  local refreshed
  local cb_result
  login.wait_for_login({
    on_qr_refresh = function(url)
      refreshed = url
    end,
    callback = function(res, err)
      cb_result = { res = res, err = err }
    end,
  })
  finish_job(#job.jobs, { vim.json.encode({ status = 'expired' }) }, 0)

  -- a refresh fetch was started; finish it with a new QR code
  lu.assertTrue(#job.jobs >= 3)
  finish_job(#job.jobs, {
    vim.json.encode({
      qrcode = 'QR-2',
      qrcode_img_content = 'https://example.com/qr2.png',
    }),
  }, 0)
  lu.assertEquals('https://example.com/qr2.png', refreshed)
  lu.assertNil(cb_result)
  -- polling continues after the refresh
  lu.assertTrue(#self.deferred >= 1)
end

function TestWeixinLoginExtra:testPollExpiredRefreshFailureFails()
  login.start_qr_login({ skip_display = true })
  finish_job(1, { QR_RESPONSE }, 0)
  local cb_result
  login.wait_for_login({
    callback = function(res, err)
      cb_result = { res = res, err = err }
    end,
  })
  finish_job(#job.jobs, { vim.json.encode({ status = 'expired' }) }, 0)
  -- the refresh fetch fails
  finish_job(#job.jobs, nil, 7)
  lu.assertNil(cb_result.res)
  lu.assertStrContains(cb_result.err, 'Failed to refresh QR code')
end

function TestWeixinLoginExtra:testPollExpiredTooManyTimesFails()
  login.start_qr_login({ skip_display = true })
  finish_job(1, { QR_RESPONSE }, 0)
  local cb_result
  login.wait_for_login({
    callback = function(res, err)
      cb_result = { res = res, err = err }
    end,
  })

  -- feed expired responses; every refresh must itself succeed, and the
  -- deferred poll continuation must be driven manually between rounds
  for _ = 1, 4 do
    finish_job(#job.jobs, { vim.json.encode({ status = 'expired' }) }, 0)
    finish_job(#job.jobs, {
      vim.json.encode({
        qrcode = 'QR-NEXT',
        qrcode_img_content = 'https://example.com/next.png',
      }),
    }, 0)
    -- run the scheduled poll continuation to start the next poll job
    local deferred_poll = self.deferred[#self.deferred]
    if deferred_poll then
      deferred_poll.fn()
    end
  end
  lu.assertNil(cb_result.res)
  lu.assertEquals('QR code expired too many times', cb_result.err)
end

function TestWeixinLoginExtra:testWaitForLoginTimeout()
  login.start_qr_login({ skip_display = true })
  finish_job(1, { QR_RESPONSE }, 0)
  local cb_result
  login.wait_for_login({
    timeout_ms = -1, -- deadline already passed
    callback = function(res, err)
      cb_result = { res = res, err = err }
    end,
  })
  lu.assertNil(cb_result.res)
  lu.assertEquals('Login timeout', cb_result.err)
  lu.assertEquals('expired', login.get_state().status)
end

function TestWeixinLoginExtra:testWaitForLoginNotFresh()
  login.clear()
  local cb_result
  login.wait_for_login({
    callback = function(res, err)
      cb_result = { res = res, err = err }
    end,
  })
  lu.assertNil(cb_result.res)
  lu.assertEquals('QR code expired', cb_result.err)
end

function TestWeixinLoginExtra:testStartLoginFlowQrFailureNotifiesError()
  local errors = {}
  local jobid = login.start_login_flow({
    on_error = function(err)
      table.insert(errors, err)
    end,
  })
  lu.assertNumber(jobid)
  finish_job(jobid, nil, 7)
  lu.assertEquals(1, #errors)
  lu.assertEquals('Failed to fetch QR code', errors[1])
  lu.assertEquals('expired', login.get_state().status)
end

function TestWeixinLoginExtra:testStartLoginFlowConfirmedEndToEnd()
  local final
  local errors = {}
  local jobid = login.start_login_flow({
    callback = function(res, err)
      final = { res = res, err = err }
    end,
    on_error = function(err)
      table.insert(errors, err)
    end,
  })
  finish_job(jobid, { QR_RESPONSE }, 0)
  -- the flow immediately starts polling: confirm the login
  finish_job(#job.jobs, {
    vim.json.encode({
      status = 'confirmed',
      ilink_bot_id = 'flow-bot',
      ilink_user_id = 'flow-user',
      bot_token = 'flow-token',
      baseurl = 'https://flow.example.com',
    }),
  }, 0)

  lu.assertEquals(0, #errors)
  lu.assertNil(final.err)
  lu.assertEquals('flow-bot', final.res.account_id)
  lu.assertEquals('confirmed', login.get_state().status)
end

function TestWeixinLoginExtra:testCloseQrcodeCleansUp()
  login.start_qr_login({})
  finish_job(1, { QR_RESPONSE }, 0)
  -- display_qrcode opened a window + buffer via the stubbed jobstart
  login.close_qrcode()
  -- a second close is a no-op
  login.close_qrcode()
  lu.assertTrue(true)
end

return TestWeixinLoginExtra

