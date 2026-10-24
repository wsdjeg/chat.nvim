-- Coverage for chat/integrations/dingtalk.lua:
-- state persistence (load + save incl. the processed-id cache trim),
-- connect validation, the api-key token flow (fetch + cache) and both
-- send paths (webhook queue draining, api conversation validation).

local lu = require('luaunit')
local job = require('job')
local curl = require('chat.curl')
local dingtalk = require('chat.integrations.dingtalk')
local config = require('chat.config')

TestDingtalkExtra = {}

local STATE_DIR = config.config.storage_dir .. 'integration/'
local STATE_FILE = STATE_DIR .. 'dingtalk.json'

function TestDingtalkExtra:setUp()
  job.reset()
  job.intercept(true)

  self.integrations_orig = config.config.integrations
  config.config.integrations = { dingtalk = {} }

  self.build_calls = {}
  self.build_orig = curl.build_request
  curl.build_request = function(opts)
    table.insert(self.build_calls, opts)
    return { 'curl', opts.method or 'GET', opts.url or '' }
  end

  -- clean state file workspace
  vim.fn.delete(STATE_FILE)
end

function TestDingtalkExtra:tearDown()
  config.config.integrations = self.integrations_orig
  curl.build_request = self.build_orig
  dingtalk.cleanup()
  job.reset()
  vim.fn.delete(STATE_DIR, 'rf')
end

function TestDingtalkExtra:testConnectWithoutWebhookAndAppKey()
  config.config.integrations.dingtalk = {}
  dingtalk.connect(function() end)
  -- validation failed: no poll job started
  lu.assertEquals(0, #job.jobs)
end

function TestDingtalkExtra:testStatePersistenceRoundTrip()
  -- prepare a persisted state with more processed ids than the cache cap
  vim.fn.mkdir(STATE_DIR, 'p')
  local processed = {}
  for i = 1, 105 do
    processed['msg-' .. i] = true
  end
  vim.fn.writefile({
    vim.json.encode({
      last_message_id = 'last-1',
      processed_ids = processed,
      session = 'persisted-session',
    }),
  }, STATE_FILE)

  -- connect loads the persisted state
  config.config.integrations.dingtalk = { webhook = 'https://oapi.dingtalk.com/hook' }
  dingtalk.connect(function() end)
  lu.assertEquals('persisted-session', dingtalk.current_session())

  -- saving trims the processed-id cache to the cap
  dingtalk.set_session('updated-session')
  local ok, content = pcall(vim.fn.readfile, STATE_FILE)
  lu.assertTrue(ok)
  local decoded = vim.json.decode(table.concat(content, '\n'))
  local count = 0
  for _ in pairs(decoded.processed_ids) do
    count = count + 1
  end
  lu.assertEquals(100, count)
  lu.assertEquals('updated-session', decoded.session)
end

function TestDingtalkExtra:testSendViaApiTokenFlow()
  config.config.integrations.dingtalk = {
    app_key = 'ak',
    app_secret = 'as',
    conversation_id = 'cid',
    user_id = 'uid',
  }
  local before = #job.jobs
  local calls_before = #self.build_calls
  dingtalk.send_message('hello')
  -- first job: token fetch
  lu.assertEquals(before + 1, #job.jobs)
  lu.assertStrContains(self.build_calls[calls_before + 1].url, 'gettoken')
  local token_job = #job.jobs
  job.emit_stdout(token_job, {
    vim.json.encode({ access_token = 'tok-1', expires_in = 7200 }),
  })

  -- token callback starts the api send job
  lu.assertEquals(before + 2, #job.jobs)
  lu.assertStrContains(self.build_calls[calls_before + 2].url, 'batchSend')
  lu.assertStrContains(self.build_calls[calls_before + 2].headers[1], 'tok-1')
  local api_job = #job.jobs
  local body = table.concat(job.jobs[api_job].stdin, '')
  lu.assertStrContains(body, 'ak')
  lu.assertStrContains(body, 'hello')
  job.emit_stdout(api_job, { 'send result' })
  job.emit_stderr(api_job, { 'warn line' })
  job.emit_exit(api_job, 0, 0)

  -- a second send reuses the cached token (no extra token fetch)
  dingtalk.send_message('again')
  lu.assertEquals(before + 3, #job.jobs)
  lu.assertStrContains(self.build_calls[calls_before + 3].url, 'batchSend')
  job.emit_exit(#job.jobs, 0, 0)
end

function TestDingtalkExtra:testSendViaApiWithoutConversationId()
  config.config.integrations.dingtalk = {
    app_key = 'ak',
    app_secret = 'as',
  }
  local before = #job.jobs
  local calls_before = #self.build_calls
  dingtalk.send_message('hello')
  -- no conversation_id: no request started
  lu.assertEquals(before, #job.jobs)
  lu.assertEquals(calls_before, #self.build_calls)
end

function TestDingtalkExtra:testWebhookQueueDrainsAfterExit()
  config.config.integrations.dingtalk = {
    webhook = 'https://oapi.dingtalk.com/robot/send',
  }
  local baseline = #job.jobs

  -- one oversized message is chunked and queued: the first chunk is sent
  -- immediately, the rest waits for the running job to finish
  local long_message = 'head ' .. string.rep('x', 21000) .. ' tail'
  dingtalk.send_message(long_message)

  -- exercise the stdout/stderr logging callbacks on the live job
  local live = #job.jobs
  lu.assertTrue(live > baseline, 'first chunk should send immediately')
  job.emit_stdout(live, { '{"errcode":0}' })
  job.emit_stderr(live, { 'warn' })

  -- drive completions until every queued chunk has been sent
  for _ = 1, 15 do
    local n = #job.jobs
    if n <= baseline then
      break
    end
    job.emit_exit(n, 0, 0)
  end

  local sent = {}
  for jid, j in pairs(job.jobs) do
    if jid > baseline and j.stdin and #j.stdin > 0 then
      table.insert(sent, table.concat(j.stdin, ''))
    end
  end
  lu.assertTrue(#sent >= 2, 'expected the queued chunks to be sent')
  local all = table.concat(sent, '')
  lu.assertStrContains(all, 'head')
  lu.assertStrContains(all, 'tail')
end

function TestDingtalkExtra:testWebhookSendMessageWithoutConfig()
  config.config.integrations = nil
  local before = #job.jobs
  dingtalk.send_message('hello')
  -- falls back to the api path which rejects the missing conversation_id
  lu.assertEquals(before, #job.jobs)
end

return TestDingtalkExtra

