-- Coverage for the remaining branches of chat/protocol/anthropic.lua and
-- chat/protocol/init.lua:
--   * SSE events: tool_use content_block_start, thinking / signature /
--     input_json deltas, message_delta (stop_reason + usage),
--     message_stop default-reason rules, malformed payloads
--   * stderr body collection -> API error handling on exit incl. the
--     api-key rotation flow (should/mark/consume)
--   * exit retry hint composition, tool-result dispatch rules
--   * protocol.request provider dispatch incl. unknown providers

local lu = require('luaunit')
local anthropic = require('chat.protocol.anthropic')
local protocol_init = require('chat.protocol')
local sessions = require('chat.sessions')
local windows = require('chat.windows')
local spinners = require('chat.spinners')
local continue_mod = require('chat.sessions.continue')
local retry_mod = require('chat.sessions.retry')
local failover = require('chat.sessions.failover')
local curl = require('chat.curl')

local sessions_methods = {
  'get_progress_session',
  'set_progress_usage',
  'set_progress_finish_reason',
  'get_progress_finish_reason',
  'on_progress',
  'on_progress_reasoning_content',
  'on_progress_tool_call',
  'on_progress_tool_call_done',
  'on_progress_done',
  'on_complete',
  'on_progress_partial',
  'on_progress_exit',
  'append_message',
  'write_cache',
  'get_messages',
  'get_request_messages',
  'has_pending_async_tools',
  'send_tool_results',
  'nudge_if_dirty',
  'get_session_provider',
}
local failover_methods = {
  'should',
  'is_pending',
  'mark',
  'consume',
}

TestProtocolAnthropicJobs = {}

local sessions_orig = {}
local failover_orig = {}
local windows_orig = {
  on_message = windows.on_message,
  current_session = windows.current_session,
}
local spinners_stop_orig = spinners.stop
local continue_orig = continue_mod.continue
local retry_orig = retry_mod.handle_exit_error
local curl_orig = curl.get_error_message

local M = TestProtocolAnthropicJobs

-- per-test captured state, rebuilt by reset_mocks
local captured = {}

local function reset_mocks()
  captured = {
    usage = nil,
    finish_reason = nil,
    finish_reason_set = nil,
    progress = nil,
    reasoning = nil,
    tool_calls = {},
    appended = {},
    win_messages = {},
    cache_writes = 0,
    session_messages = nil,
    request_messages = nil,
    sent_tool_results = 0,
    nudged = 0,
    pending_async = false,
    retry_hint = nil,
    should_rotate = false,
    is_pending = false,
    marks = {},
    consumes = {},
    stop_calls = 0,
  }

  sessions.get_progress_session = function()
    return 's1'
  end
  sessions.set_progress_usage = function(_, u)
    captured.usage = u
  end
  sessions.set_progress_finish_reason = function(_, r)
    captured.finish_reason_set = r
  end
  sessions.get_progress_finish_reason = function()
    return captured.finish_reason
  end
  sessions.on_progress = function(_, txt)
    captured.progress = txt
  end
  sessions.on_progress_reasoning_content = function(_, txt)
    captured.reasoning = txt
  end
  sessions.on_progress_tool_call = function(_, tc)
    table.insert(captured.tool_calls, tc)
  end
  sessions.on_progress_tool_call_done = function() end
  sessions.on_progress_done = function() end
  sessions.on_complete = function() end
  sessions.on_progress_partial = function() end
  sessions.on_progress_exit = function() end
  sessions.append_message = function(_, msg)
    table.insert(captured.appended, msg)
  end
  sessions.write_cache = function()
    captured.cache_writes = captured.cache_writes + 1
  end
  sessions.get_messages = function()
    return captured.session_messages
        or { { role = 'assistant', content = 'x' } }
  end
  sessions.get_request_messages = function()
    return captured.request_messages
        or { { role = 'assistant', content = 'x' } }
  end
  sessions.has_pending_async_tools = function()
    return captured.pending_async
  end
  sessions.send_tool_results = function()
    captured.sent_tool_results = captured.sent_tool_results + 1
  end
  sessions.nudge_if_dirty = function()
    captured.nudged = captured.nudged + 1
  end
  sessions.get_session_provider = function()
    return 'test-provider'
  end

  failover.should = function()
    return captured.should_rotate
  end
  failover.is_pending = function()
    return captured.is_pending
  end
  failover.mark = function(id, session, code, msg)
    table.insert(captured.marks, { id = id, session = session, code = code, msg = msg })
  end
  failover.consume = function(id, session)
    table.insert(captured.consumes, { id = id, session = session })
  end

  windows.on_message = function(_, msg)
    table.insert(captured.win_messages, msg)
  end
  windows.current_session = function()
    return 's1'
  end
  spinners.stop = function()
    captured.stop_calls = captured.stop_calls + 1
  end
  continue_mod.continue = function()
    return nil, nil
  end
  retry_mod.handle_exit_error = function()
    return captured.retry_hint
  end
  curl.get_error_message = function()
    return 'curl connection refused'
  end
end

local function restore_mocks()
  for m, orig in pairs(sessions_orig) do
    sessions[m] = orig
  end
  for m, orig in pairs(failover_orig) do
    failover[m] = orig
  end
  windows.on_message = windows_orig.on_message
  windows.current_session = windows_orig.current_session
  spinners.stop = spinners_stop_orig
  continue_mod.continue = continue_orig
  retry_mod.handle_exit_error = retry_orig
  curl.get_error_message = curl_orig
end

for _, m in ipairs(sessions_methods) do
  sessions_orig[m] = sessions[m]
end
for _, m in ipairs(failover_methods) do
  failover_orig[m] = failover[m]
end

local function wait_schedule()
  vim.wait(60, function()
    return false
  end)
end

-- anthropic keeps SSE/body buffers per jobid in module-local tables:
-- every test uses a fresh jobid so leftovers from another test can never
-- leak into this one.
local job_counter = 100

function M:setUp()
  reset_mocks()
  self.jobid = job_counter
  job_counter = job_counter + 1
end

function M:tearDown()
  restore_mocks()
end

-- SSE delta events ---------------------------------------------------------

function M:testContentBlockStartToolUse()
  anthropic.on_stdout(self.jobid, {
    '',
    'data: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"tu_1","name":"get_weather","input":{}}}',
    '',
  })
  wait_schedule()
  lu.assertEquals(1, #captured.tool_calls)
  local tc = captured.tool_calls[1]
  lu.assertEquals('tu_1', tc.id)
  lu.assertEquals(0, tc.index)
  lu.assertEquals('function', tc.type)
  lu.assertEquals('get_weather', tc['function'].name)
  lu.assertEquals('', tc['function'].arguments)
end

function M:testThinkingDelta()
  anthropic.on_stdout(self.jobid, {
    '',
    'data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"reasoning hard"}}',
    '',
  })
  wait_schedule()
  lu.assertEquals('reasoning hard', captured.reasoning)
  lu.assertNil(captured.progress)
end

function M:testSignatureDeltaIsAcknowledged()
  anthropic.on_stdout(self.jobid, {
    '',
    'data: {"type":"content_block_delta","index":0,"delta":{"type":"signature_delta"}}',
    '',
  })
  wait_schedule()
  lu.assertEquals(0, #captured.tool_calls)
  lu.assertNil(captured.reasoning)
  lu.assertNil(captured.progress)
end

function M:testInputJsonDelta()
  anthropic.on_stdout(self.jobid, {
    '',
    'data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\\"city\\":"}}',
    '',
  })
  wait_schedule()
  lu.assertEquals(1, #captured.tool_calls)
  lu.assertEquals(0, captured.tool_calls[1].index)
  lu.assertEquals('{"city":', captured.tool_calls[1]['function'].arguments)
end

function M:testContentBlockStopIsInert()
  anthropic.on_stdout(self.jobid, {
    '',
    'data: {"type":"content_block_stop","index":0}',
    '',
  })
  wait_schedule()
  lu.assertEquals(0, #captured.tool_calls)
  lu.assertNil(captured.usage)
end

function M:testMessageDeltaStopReasonAndUsage()
  anthropic.on_stdout(self.jobid, {
    '',
    'data: {"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"input_tokens":2,"output_tokens":3,"total_tokens":5}}',
    '',
  })
  wait_schedule()
  lu.assertEquals('tool_use', captured.finish_reason_set)
  lu.assertNotNil(captured.usage)
  lu.assertEquals(5, captured.usage.total_tokens)
  lu.assertEquals(2, captured.usage.prompt_tokens)
end

function M:testMessageDeltaUsageWithoutTotalFallsBackToSum()
  anthropic.on_stdout(self.jobid, {
    '',
    'data: {"type":"message_delta","delta":{},"usage":{"input_tokens":2,"output_tokens":3}}',
    '',
  })
  wait_schedule()
  lu.assertEquals(5, captured.usage.total_tokens)
  lu.assertNil(captured.finish_reason_set)
end

function M:testMessageStopSetsDefaultReason()
  captured.finish_reason = nil
  anthropic.on_stdout(self.jobid, {
    '',
    'data: {"type":"message_stop"}',
    '',
  })
  wait_schedule()
  lu.assertEquals('stop', captured.finish_reason_set)
end

function M:testMessageStopKeepsExistingReason()
  captured.finish_reason = 'tool_use'
  anthropic.on_stdout(self.jobid, {
    '',
    'data: {"type":"message_stop"}',
    '',
  })
  wait_schedule()
  lu.assertNil(captured.finish_reason_set)
end

function M:testEmptyDataPayloadIgnored()
  anthropic.on_stdout(self.jobid, { '', 'data:    ', '' })
  wait_schedule()
  lu.assertEquals(0, #captured.appended)
  lu.assertNil(captured.usage)
end

function M:testInvalidJsonPayloadLogged()
  anthropic.on_stdout(self.jobid, { '', 'data: not-a-json-body', '' })
  wait_schedule()
  lu.assertEquals(0, #captured.appended)
  lu.assertNil(captured.usage)
end

-- stderr body -> exit error handling ---------------------------------------

function M:testStderrIsOnlyLogged()
  anthropic.on_stderr(self.jobid, { 'warning noise' }, 'claude')
  wait_schedule()
  lu.assertEquals(0, #captured.appended)
  lu.assertEquals(0, #captured.marks)
  lu.assertEquals(0, #captured.consumes)
end

--- A non-SSE stdout line is an API error body: it lands in the body
--- buffer and is decoded when the job exits.
local function feed_body_error(self, body)
  anthropic.on_stdout(self.jobid, { body })
end

function M:testBodyErrorAppendsMessage()
  feed_body_error(self, '{"error":{"message":"rate limited","type":"rate_limit_error"}}')
  anthropic.on_exit(self.jobid, 0, 0)
  wait_schedule()

  lu.assertEquals(1, #captured.appended)
  lu.assertStrContains(captured.appended[1].error, 'Anthropic API Error (rate_limit_error): rate limited')
  lu.assertEquals(1, #captured.win_messages)
  lu.assertTrue(captured.cache_writes >= 1)
  -- no rotation was requested
  lu.assertEquals(0, #captured.marks)
  lu.assertEquals(0, #captured.consumes)
end

function M:testBodyErrorRotatesKey()
  captured.should_rotate = true
  feed_body_error(self, '{"error":{"message":"rate limited","type":"rate_limit_error"}}')
  anthropic.on_exit(self.jobid, 0, 0)
  wait_schedule()

  lu.assertEquals(1, #captured.marks)
  lu.assertEquals('rate_limit_error', captured.marks[1].code)
  -- rotation is consumed after cleanup
  lu.assertEquals(1, #captured.consumes)
  -- body errors surface a message even when rotating
  lu.assertEquals(1, #captured.appended)
end

function M:testExitNonZeroCodeAppendsRetryHint()
  captured.retry_hint = 'Auto-retry 1/3 scheduled.'
  anthropic.on_exit(self.jobid,7, 0)
  wait_schedule()
  lu.assertEquals(1, #captured.appended)
  lu.assertStrContains(captured.appended[1].error, 'curl connection refused')
  lu.assertStrContains(captured.appended[1].error, 'Auto-retry 1/3 scheduled.')
end

-- tool result dispatch rules ------------------------------------------------

function M:testExitSkipsToolResultsAfterApiError()
  captured.session_messages = { { error = 'previous failure' } }
  anthropic.on_exit(self.jobid,0, 0)
  wait_schedule()
  lu.assertEquals(0, captured.sent_tool_results)
  lu.assertEquals(0, captured.nudged)
end

function M:testExitSendsToolResultsWhenLastIsTool()
  captured.request_messages = {
    { role = 'user', content = 'q' },
    { role = 'tool', content = 'done' },
  }
  anthropic.on_exit(self.jobid,0, 0)
  wait_schedule()
  lu.assertEquals(1, captured.sent_tool_results)
  lu.assertEquals(0, captured.nudged)
end

function M:testExitNudgesWhenTurnComplete()
  captured.request_messages = {
    { role = 'user', content = 'q' },
    { role = 'assistant', content = 'a' },
  }
  anthropic.on_exit(self.jobid,0, 0)
  wait_schedule()
  lu.assertEquals(0, captured.sent_tool_results)
  lu.assertEquals(1, captured.nudged)
end

function M:testExitPendingAsyncSkipsNudgeAndSend()
  captured.pending_async = true
  captured.request_messages = {
    { role = 'tool', content = 'pending' },
  }
  anthropic.on_exit(self.jobid,0, 0)
  wait_schedule()
  lu.assertEquals(0, captured.sent_tool_results)
  lu.assertEquals(0, captured.nudged)
end

function M:testExitLengthReasonSkipsToolResults()
  captured.finish_reason = 'length'
  captured.request_messages = {
    { role = 'tool', content = 'done' },
  }
  anthropic.on_exit(self.jobid,0, 0)
  wait_schedule()
  lu.assertEquals(0, captured.sent_tool_results)
end

function M:testExitSignalCancelDropsRotation()
  captured.should_rotate = true
  feed_body_error(self, '{"error":{"message":"x","type":"api"}}')
  anthropic.on_exit(self.jobid, 0, 2)
  wait_schedule()
  -- the body error surfaced, then the user-cancel message
  lu.assertEquals(2, #captured.appended)
  lu.assertStrContains(captured.appended[2].error, 'cancelled by user')
  lu.assertEquals(0, captured.sent_tool_results)
  -- rotation was marked but dropped when the user cancelled
  lu.assertEquals(1, #captured.marks)
  lu.assertEquals(0, #captured.consumes)
end

-- =========================================================================
-- chat/protocol/init.lua
-- =========================================================================

TestProtocolInitExtra = {}

function TestProtocolInitExtra:setUp()
  self.orig = {}
  self.provider_orig = sessions.get_session_provider
  sessions.get_session_provider = function()
    return 'fakep'
  end

  package.preload['chat.providers.fakep'] = function()
    return {
      protocol = 'openai',
      request = function(opt)
        self.request_opts = opt
        return 42
      end,
    }
  end
end

function TestProtocolInitExtra:tearDown()
  sessions.get_session_provider = self.provider_orig
  package.preload['chat.providers.fakep'] = nil
  package.loaded['chat.providers.fakep'] = nil
end

function TestProtocolInitExtra:testRequestDispatchesToProvider()
  local jobid = protocol_init.request({ session = 's1', messages = {} })
  lu.assertEquals(42, jobid)
  -- provider received the openai protocol callbacks
  lu.assertNotNil(self.request_opts.on_stdout)
  lu.assertNotNil(self.request_opts.on_stderr)
  lu.assertNotNil(self.request_opts.on_exit)
  lu.assertEquals('s1', self.request_opts.session)
end

function TestProtocolInitExtra:testRequestUnknownProviderReturnsNil()
  sessions.get_session_provider = function()
    return 'definitely-no-such-provider'
  end
  lu.assertNil(protocol_init.request({ session = 's1', messages = {} }))
end

function TestProtocolInitExtra:testRequestDefaultsToOpenaiProtocol()
  package.preload['chat.providers.fakep'] = function()
    return {
      -- no protocol field: falls back to 'openai'
      request = function(opt)
        return 7
      end,
    }
  end
  lu.assertEquals(7, protocol_init.request({ session = 's1', messages = {} }))
end

return TestProtocolAnthropicJobs, TestProtocolInitExtra

