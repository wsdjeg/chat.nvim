-- Coverage for the remaining branches of chat.sessions.progress,
-- chat.sessions.retry (schedule/deferred retry body) and
-- chat.sessions.failover (default defer + rotated request lifecycle).

local lu = require('luaunit')

local progress = require('chat.sessions.progress')
local retry = require('chat.sessions.retry')
local failover = require('chat.sessions.failover')
local continue = require('chat.sessions.continue')
local storage = require('chat.sessions.storage')
local messages = require('chat.sessions.messages')
local windows = require('chat.windows')
local integrations = require('chat.integrations')
local sessions = require('chat.sessions')
local protocol = require('chat.protocol')
local spinners = require('chat.spinners')
local config = require('chat.config')
local tokens = require('chat.tokens')
local job = require('job')

local CWD = vim.fs.normalize(vim.fn.getcwd())

-- =========================================================================
-- progress
-- =========================================================================

TestProgressExtra = {}

local orig = {}

local function save(module, name)
  table.insert(orig, { module = module, name = name, fn = module[name] })
end

function TestProgressExtra:setUp()
  orig = {}
  self.sid = 'prog-extra-' .. tostring(math.random(100000, 999999))
  storage.sessions[self.sid] = {
    id = self.sid,
    messages = {},
    cwd = CWD,
  }

  save(windows, 'push_text')
  save(windows, 'current_session')
  self.pushes = {}
  windows.push_text = function(chunk)
    table.insert(self.pushes, chunk)
  end
  windows.current_session = function()
    return self.sid
  end

  save(integrations, 'on_response')
  self.on_response = {}
  integrations.on_response = function(sid, content)
    table.insert(self.on_response, { sid = sid, content = content })
  end

  save(storage, 'write_cache')
  self.cache_writes = 0
  storage.write_cache = function()
    self.cache_writes = self.cache_writes + 1
  end

  save(protocol, 'request')
  self.protocol_result = nil
  protocol.request = function(_)
    return self.protocol_result
  end

  save(spinners, 'start')
  save(spinners, 'stop')
  self.spinner_starts = 0
  spinners.start = function()
    self.spinner_starts = self.spinner_starts + 1
  end
  self.spinner_stops = 0
  spinners.stop = function()
    self.spinner_stops = self.spinner_stops + 1
  end

  save(retry, 'is_retrying')
  self.retrying = false
  retry.is_retrying = function(_)
    return self.retrying
  end
  save(retry, 'cancel_retry')
  self.retry_cancels = 0
  retry.cancel_retry = function()
    self.retry_cancels = self.retry_cancels + 1
  end

  save(failover, 'cancel')
  self.failover_cancels = 0
  failover.cancel = function()
    self.failover_cancels = self.failover_cancels + 1
  end
end

function TestProgressExtra:tearDown()
  for _, entry in ipairs(orig) do
    entry.module[entry.name] = entry.fn
  end
  storage.sessions[self.sid] = nil
  continue.reset(self.sid)
end

function TestProgressExtra:testUsageAndFinishReasonAccessors()
  progress.set_progress_usage(21, { total_tokens = 5 })
  lu.assertEquals({ total_tokens = 5 }, progress.get_progress_usage(21))
  progress.set_progress_finish_reason(21, 'stop')
  lu.assertEquals('stop', progress.get_progress_finish_reason(21))
  lu.assertNil(progress.get_progress_usage(999))
  lu.assertNil(progress.get_progress_finish_reason(999))
  progress.on_progress_exit(21)
  lu.assertNil(progress.get_progress_usage(21))
  lu.assertNil(progress.get_progress_finish_reason(21))
end

function TestProgressExtra:testOnProgressPushesStartAndChunks()
  progress.set_session_jobid(self.sid, 22)
  progress.on_progress(22, 'Hello')
  progress.on_progress(22, ' world')
  lu.assertEquals(2, #self.pushes)
  lu.assertTrue(self.pushes[1].is_start)
  lu.assertEquals('Hello', self.pushes[1].content)
  lu.assertNil(self.pushes[2].is_start)
  lu.assertEquals(' world', self.pushes[2].content)
  lu.assertEquals('Hello world', progress.get_progress_message(self.sid))
end

function TestProgressExtra:testOnProgressAfterReasoningUsesSeparator()
  progress.set_session_jobid(self.sid, 23)
  progress.on_progress_reasoning_content(23, 'thinking...')
  progress.on_progress(23, 'Answer')
  lu.assertEquals(2, #self.pushes)
  lu.assertTrue(self.pushes[1].is_start)
  lu.assertEquals('thinking...', self.pushes[1].reasoning_content)
  lu.assertEquals('\n\nAnswer', self.pushes[2].content)
end

function TestProgressExtra:testOnProgressOtherSessionOnlyBuffers()
  progress.set_session_jobid(self.sid, 24)
  windows.current_session = function()
    return 'other-session'
  end
  progress.on_progress(24, 'buffered')
  lu.assertEquals(0, #self.pushes)
  lu.assertEquals('buffered', progress.get_progress_message(self.sid))
end

function TestProgressExtra:testOnProgressReasoningBranches()
  progress.set_session_jobid(self.sid, 25)
  progress.on_progress_reasoning_content(25, 'first thought')
  progress.on_progress_reasoning_content(25, ' and more')
  lu.assertEquals(2, #self.pushes)
  lu.assertTrue(self.pushes[1].is_start)
  lu.assertNil(self.pushes[2].is_start)
  lu.assertEquals(' and more', self.pushes[2].reasoning_content)
  lu.assertEquals(
    'first thought and more',
    progress.get_progress_reasoning_content(self.sid)
  )
end

function TestProgressExtra:testOnProgressDoneAppendsAssistantMessage()
  progress.set_session_jobid(self.sid, 26)
  progress.on_progress(26, 'the answer')
  progress.on_progress_done(26, {})
  local msgs = storage.sessions[self.sid].messages
  lu.assertEquals(1, #msgs)
  lu.assertEquals('assistant', msgs[1].role)
  lu.assertEquals('the answer', msgs[1].content)
  -- no continuation pending: integrations not notified here
  lu.assertEquals(0, #self.on_response)
  -- progress buffer flushed
  lu.assertNil(progress.get_progress_message(self.sid))
  lu.assertTrue(self.cache_writes >= 1)
end

function TestProgressExtra:testOnProgressDoneNotifiesOnContinuation()
  progress.set_session_jobid(self.sid, 27)
  -- simulate a truncated response: assistant message pending continuation
  local msg = { role = 'assistant', created = os.time() }
  messages.append_message(self.sid, msg)
  continue.set_pending(self.sid, msg)
  progress.on_progress(27, ' continued part')
  progress.on_progress_done(27, {})
  lu.assertEquals(' continued part', msg.content)
  lu.assertEquals(1, #self.on_response)
  lu.assertEquals(' continued part', self.on_response[1].content)
end

function TestProgressExtra:testOnProgressPartialWithoutSessionNoop()
  progress.on_progress_partial(999)
  lu.assertEquals(0, self.cache_writes)
end

function TestProgressExtra:testOnProgressPartialWithoutContentNoop()
  progress.set_session_jobid(self.sid, 28)
  progress.on_progress_partial(28)
  lu.assertNil(continue.get_pending(self.sid))
end

function TestProgressExtra:testOnProgressPartialKeepsPendingMessage()
  progress.set_session_jobid(self.sid, 29)
  progress.on_progress(29, 'partial answer')
  progress.on_progress_partial(29)
  local pending = continue.get_pending(self.sid)
  lu.assertNotNil(pending)
  lu.assertEquals('partial answer', pending.content)
  lu.assertEquals('assistant', pending.role)
end

function TestProgressExtra:testOnProgressExitClearsState()
  progress.set_session_jobid(self.sid, 30)
  progress.on_progress(30, 'text')
  progress.on_progress_reasoning_content(30, 'reason')
  progress.set_progress_usage(30, { total_tokens = 1 })
  progress.on_progress_exit(30)
  lu.assertNil(progress.get_progress_message(self.sid))
  lu.assertNil(progress.get_progress_reasoning_content(self.sid))
  lu.assertNil(progress.get_progress_session(30))
end

function TestProgressExtra:testIsInProgressDetectionPaths()
  lu.assertFalse(progress.is_in_progress('nothing-here'))
  progress.set_session_jobid(self.sid, 31)
  lu.assertTrue(progress.is_in_progress(self.sid))
  progress.on_progress_exit(31)
  lu.assertFalse(progress.is_in_progress(self.sid))
end

function TestProgressExtra:testCancelProgressRetryStopsSpinner()
  self.retrying = true
  progress.cancel_progress(self.sid)
  lu.assertEquals(1, self.retry_cancels)
  lu.assertEquals(1, self.spinner_stops)
  lu.assertEquals(1, self.failover_cancels)
end

function TestProgressExtra:testCancelProgressRetryOtherSessionNoSpinner()
  self.retrying = true
  windows.current_session = function()
    return 'other-session'
  end
  progress.cancel_progress(self.sid)
  lu.assertEquals(1, self.retry_cancels)
  lu.assertEquals(0, self.spinner_stops)
end

function TestProgressExtra:testCancelProgressStopsLiveJob()
  job.intercept()
  local jid = job.start({ 'sleep', '10' }, {})
  job.set_running(jid, true)
  progress.set_session_jobid(self.sid, jid)
  progress.cancel_progress(self.sid)
  lu.assertNotNil(job.jobs[jid].stopped)
  job.reset()
end

-- =========================================================================
-- retry
-- =========================================================================

TestRetryExtra = {}

function TestRetryExtra:setUp()
  orig = {}
  self.sid = 'retry-extra-' .. tostring(math.random(100000, 999999))

  self.retry_config_orig = config.config.retry
  config.config.retry = { max_retries = 3, retry_delay = 5 }

  self.defer_orig = vim.defer_fn
  self.deferred = {}
  vim.defer_fn = function(fn, delay)
    table.insert(self.deferred, { fn = fn, delay = delay })
    return { stop = function() end }
  end

  save(sessions, 'exists')
  self.session_exists = true
  sessions.exists = function(_)
    return self.session_exists
  end
  save(sessions, 'get_request_messages')
  self.request_messages = { { role = 'user', content = 'hi' } }
  sessions.get_request_messages = function(_)
    return self.request_messages
  end

  save(windows, 'current_session')
  windows.current_session = function()
    return self.sid
  end

  save(spinners, 'start')
  save(spinners, 'stop')
  self.spinner_starts = 0
  spinners.start = function()
    self.spinner_starts = self.spinner_starts + 1
  end
  self.spinner_stops = 0
  spinners.stop = function()
    self.spinner_stops = self.spinner_stops + 1
  end

  save(protocol, 'request')
  self.protocol_result = 4
  self.protocol_calls = {}
  protocol.request = function(opts)
    table.insert(self.protocol_calls, opts)
    return self.protocol_result
  end
end

function TestRetryExtra:tearDown()
  for _, entry in ipairs(orig) do
    entry.module[entry.name] = entry.fn
  end
  vim.defer_fn = self.defer_orig
  config.config.retry = self.retry_config_orig
  retry.reset_retry_count(self.sid)
end

function TestRetryExtra:testScheduleRetryExhaustsAfterMaxAttempts()
  for i = 1, 3 do
    local hint = retry.schedule_retry(self.sid)
    lu.assertStrContains(hint, string.format('Auto-retry %d/3', i))
    lu.assertTrue(retry.is_retrying(self.sid))
    lu.assertEquals(i, retry.get_retry_count(self.sid))
  end
  local final = retry.schedule_retry(self.sid)
  lu.assertStrContains(final, 'All 3 auto-retries exhausted')
  lu.assertFalse(retry.is_retrying(self.sid))
  lu.assertEquals(0, retry.get_retry_count(self.sid))
end

function TestRetryExtra:testScheduleRetryKeepsSpinnerForCurrentSession()
  local hint = retry.schedule_retry(self.sid)
  lu.assertStrContains(hint, 'Auto-retry 1/3')
  lu.assertEquals(1, self.spinner_starts)
end

function TestRetryExtra:testScheduleRetryOtherSessionNoSpinner()
  windows.current_session = function()
    return 'other-session'
  end
  retry.schedule_retry(self.sid)
  lu.assertEquals(0, self.spinner_starts)
end

function TestRetryExtra:testDeferredRetrySkipsDeletedSession()
  retry.schedule_retry(self.sid)
  self.session_exists = false
  self.deferred[1].fn()
  lu.assertEquals(0, #self.protocol_calls)
  lu.assertEquals(0, retry.get_retry_count(self.sid))
end

function TestRetryExtra:testDeferredRetryStartsRequest()
  retry.schedule_retry(self.sid)
  self.deferred[1].fn()
  lu.assertEquals(1, #self.protocol_calls)
  lu.assertEquals(self.sid, self.protocol_calls[1].session)
  lu.assertEquals(0, self.spinner_stops)
end

function TestRetryExtra:testDeferredRetryFailureStopsSpinner()
  self.protocol_result = nil
  retry.schedule_retry(self.sid)
  self.deferred[1].fn()
  lu.assertEquals(1, #self.protocol_calls)
  lu.assertEquals(1, self.spinner_stops)
  lu.assertEquals(0, retry.get_retry_count(self.sid))
end

-- =========================================================================
-- failover
-- =========================================================================

TestFailoverExtra = {}

function TestFailoverExtra:setUp()
  orig = {}
  self.sid = 'failover-extra-' .. tostring(math.random(100000, 999999))
  storage.sessions[self.sid] = {
    id = self.sid,
    messages = {},
    cwd = CWD,
  }

  self.saved_api_key = config.config.api_key
  config.config.api_key = {
    multi = { 'key-1', 'key-2', 'key-3' },
  }
  tokens.reset()

  self.defer_orig = vim.defer_fn
  self.deferred = {}
  vim.defer_fn = function(fn, delay)
    table.insert(self.deferred, { fn = fn, delay = delay })
    return { stop = function() end }
  end

  save(sessions, 'exists')
  self.session_exists = true
  sessions.exists = function(_)
    return self.session_exists
  end
  save(sessions, 'get_request_messages')
  self.request_messages = { { role = 'user', content = 'hi' } }
  sessions.get_request_messages = function(_)
    return self.request_messages
  end
  save(sessions, 'write_cache')
  save(storage, 'write_cache')
  self.cache_writes = 0
  sessions.write_cache = function()
    self.cache_writes = self.cache_writes + 1
  end
  storage.write_cache = function()
    self.cache_writes = self.cache_writes + 1
  end

  save(windows, 'current_session')
  windows.current_session = function()
    return self.sid
  end
  save(windows, 'on_message')
  self.win_messages = {}
  windows.on_message = function(_, msg)
    table.insert(self.win_messages, msg)
  end

  save(progress, 'is_in_progress')
  self.in_progress = false
  progress.is_in_progress = function(_)
    return self.in_progress
  end

  save(protocol, 'request')
  self.protocol_result = 5
  self.protocol_calls = {}
  protocol.request = function(opts)
    table.insert(self.protocol_calls, opts)
    return self.protocol_result
  end

  save(spinners, 'start')
  self.spinner_starts = 0
  spinners.start = function()
    self.spinner_starts = self.spinner_starts + 1
  end
end

function TestFailoverExtra:tearDown()
  for _, entry in ipairs(orig) do
    entry.module[entry.name] = entry.fn
  end
  vim.defer_fn = self.defer_orig
  config.config.api_key = self.saved_api_key
  storage.sessions[self.sid] = nil
  failover.cancel(self.sid)
  tokens.reset()
end

--- mark + consume: the default _defer routes through vim.defer_fn
local function arm_rotation(sid, jobid, code, msg)
  tokens.bind(jobid, 'multi', 1)
  failover.mark(jobid, sid, code, msg)
  return failover.consume(jobid, sid)
end

function TestFailoverExtra:testConsumeRoutesThroughDefaultDefer()
  lu.assertTrue(arm_rotation(self.sid, 401, 429, 'rate limit reached'))
  lu.assertEquals(1, #self.deferred)
  lu.assertNotNil(self.deferred[1].delay)
end

function TestFailoverExtra:testRotationStartsRequestShowsNoticeAndSpinner()
  lu.assertTrue(arm_rotation(self.sid, 402, 429, 'rate limit reached'))
  self.deferred[1].fn()
  lu.assertEquals(1, #self.protocol_calls)
  lu.assertEquals(1, self.spinner_starts)
  -- notice stored in history + shown in window
  local notices = {}
  for _, m in ipairs(storage.sessions[self.sid].messages) do
    if m.notice then
      table.insert(notices, m.notice)
    end
  end
  lu.assertEquals(1, #notices)
  lu.assertStrContains(notices[1], 'API key #1 (multi)')
  lu.assertStrContains(notices[1], 'retrying with the next api key')
  lu.assertEquals(1, #self.win_messages)
  lu.assertTrue(self.cache_writes >= 1)
end

function TestFailoverExtra:testRotationSkippedWhenSessionGone()
  lu.assertTrue(arm_rotation(self.sid, 403, 429, 'rate limit reached'))
  self.session_exists = false
  self.deferred[1].fn()
  lu.assertEquals(0, #self.protocol_calls)
end

function TestFailoverExtra:testRotationSkippedWhenUserTookOver()
  lu.assertTrue(arm_rotation(self.sid, 404, 429, 'rate limit reached'))
  self.in_progress = true
  self.deferred[1].fn()
  lu.assertEquals(0, #self.protocol_calls)
end

function TestFailoverExtra:testRotationFailureAppendsErrorMessage()
  lu.assertTrue(arm_rotation(self.sid, 405, 429, 'rate limit reached'))
  self.protocol_result = nil
  self.deferred[1].fn()
  lu.assertEquals(1, #self.protocol_calls)
  lu.assertEquals(0, self.spinner_starts)
  local errors = {}
  for _, m in ipairs(storage.sessions[self.sid].messages) do
    if m.error then
      table.insert(errors, m.error)
    end
  end
  lu.assertEquals(1, #errors)
  lu.assertStrContains(errors[1], 'rotation failed to start')
end

return TestProgressExtra, TestRetryExtra, TestFailoverExtra

