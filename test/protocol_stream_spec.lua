-- Coverage for lua/chat/protocol/openai.lua and gemini.lua
-- Stubs chat.sessions / chat.windows / chat.spinners / chat.sessions.retry
-- so streaming callbacks can be driven synchronously.
local lu = require('luaunit')

local real_sessions = package.loaded['chat.sessions']
local real_windows = package.loaded['chat.windows']
local real_spinners = package.loaded['chat.spinners']
local real_retry = package.loaded['chat.sessions.retry']
if not real_sessions then
  real_sessions = require('chat.sessions')
end

-- Mutable stub state
local S = {}

local function sessions_stub()
  return {
    on_progress = function(id, text)
      table.insert(S.progress, text)
    end,
    on_progress_reasoning_content = function(id, text)
      table.insert(S.reasoning, text)
    end,
    on_progress_tool_call = function(id, tc)
      table.insert(S.tool_calls, tc)
    end,
    set_progress_finish_reason = function(id, r)
      S.finish_reason = r
    end,
    get_progress_finish_reason = function()
      return S.finish_reason
    end,
    set_progress_usage = function(id, u)
      S.usage = u
    end,
    get_progress_session = function()
      return S.session
    end,
    append_message = function(sid, msg)
      table.insert(S.appended, msg)
    end,
    on_progress_exit = function()
      S.exited = true
    end,
    on_progress_done = function()
      S.done = true
    end,
    on_complete = function()
      S.complete = true
    end,
    on_progress_tool_call_done = function()
      S.tool_done = true
    end,
    has_pending_async_tools = function()
      return S.pending_async
    end,
    send_tool_results = function()
      S.sent_tool_results = true
    end,
    nudge_if_dirty = function()
      S.nudged = true
    end,
    get_messages = function()
      return S.messages
    end,
    get_request_messages = function()
      return S.messages
    end,
  }
end

local function windows_stub()
  return {
    on_message = function(sid, msg)
      table.insert(S.ui_messages, msg)
    end,
    current_session = function()
      return S.session
    end,
  }
end

local function spinners_stub()
  return { stop = function()
    S.spinner_stopped = true
  end }
end

local function retry_stub()
  return {
    handle_exit_error = function()
      return S.retry_hint
    end,
    reset_retry_count = function() end,
  }
end

local function load_protocol_fresh(name)
  package.loaded['chat.sessions'] = sessions_stub()
  package.loaded['chat.windows'] = windows_stub()
  package.loaded['chat.spinners'] = spinners_stub()
  package.loaded['chat.sessions.retry'] = retry_stub()
  package.loaded['chat.protocol.' .. name] = nil
  return require('chat.protocol.' .. name)
end

local function restore_modules()
  package.loaded['chat.sessions'] = real_sessions
  package.loaded['chat.windows'] = real_windows
  package.loaded['chat.spinners'] = real_spinners
  package.loaded['chat.sessions.retry'] = real_retry
  package.loaded['chat.protocol.openai'] = nil
  package.loaded['chat.protocol.gemini'] = nil
end

local function reset_state()
  S = {
    session = 'sess-proto',
    progress = {},
    reasoning = {},
    tool_calls = {},
    appended = {},
    ui_messages = {},
    messages = {},
    finish_reason = nil,
    usage = nil,
    pending_async = false,
    retry_hint = nil,
    done = false,
    complete = false,
    tool_done = false,
    nudged = false,
    sent_tool_results = false,
    exited = false,
    spinner_stopped = false,
  }
end

--- Trigger on_stdout and let vim.schedule callbacks run
local function flush(timeout)
  vim.wait(timeout or 300, function()
    return false
  end, 30)
end

TestProtocolOpenAI = {}

function TestProtocolOpenAI:setUp()
  reset_state()
  self.proto = load_protocol_fresh('openai')
end

function TestProtocolOpenAI:tearDown()
  restore_modules()
end

function TestProtocolOpenAI:test_content_stream()
  self.proto.on_stdout(1, {
    'data: {"choices":[{"delta":{"content":"Hi"}}]}',
    '',
  })
  flush()
  lu.assertEquals(S.progress, { 'Hi' })
end

function TestProtocolOpenAI:test_content_stream_no_space_after_data()
  self.proto.on_stdout(2, {
    'data:{"choices":[{"delta":{"content":"NoSpace"}}]}',
    '',
  })
  flush()
  lu.assertEquals(S.progress, { 'NoSpace' })
end

function TestProtocolOpenAI:test_reasoning_content_stream()
  self.proto.on_stdout(3, {
    'data: {"choices":[{"delta":{"reasoning_content":"thinking..."}}]}',
    '',
  })
  flush()
  lu.assertEquals(S.reasoning, { 'thinking...' })
  lu.assertEquals(#S.progress, 0)
end

function TestProtocolOpenAI:test_tool_calls_stream()
  self.proto.on_stdout(4, {
    'data: {"choices":[{"delta":{"tool_calls":[{"id":"t1","function":{"name":"f","arguments":"{}"}}]}}]}',
    '',
  })
  flush()
  lu.assertEquals(#S.tool_calls, 1)
  lu.assertEquals(S.tool_calls[1].id, 't1')
end

function TestProtocolOpenAI:test_finish_reason_and_usage()
  self.proto.on_stdout(5, {
    'data: {"choices":[{"delta":{},"finish_reason":"stop"}],"usage":{"total_tokens":42}}',
    '',
  })
  flush()
  lu.assertEquals(S.finish_reason, 'stop')
  lu.assertEquals(S.usage.total_tokens, 42)
end

function TestProtocolOpenAI:test_done_marker()
  self.proto.on_stdout(6, { 'data: [DONE]', '' })
  flush()
  lu.assertEquals(#S.appended, 0)
  lu.assertNil(S.usage)
end

function TestProtocolOpenAI:test_invalid_json_chunk()
  self.proto.on_stdout(7, { 'data: {invalid json', '' })
  flush()
  lu.assertEquals(#S.appended, 0)
end

function TestProtocolOpenAI:test_chunk_without_choices()
  self.proto.on_stdout(8, { 'data: {"id":"x"}', '' })
  flush()
  lu.assertEquals(#S.appended, 0)
end

function TestProtocolOpenAI:test_empty_content_delta_ignored()
  self.proto.on_stdout(9, {
    'data: {"choices":[{"delta":{"content":""}}]}',
    '',
  })
  flush()
  lu.assertEquals(#S.progress, 0)
end

function TestProtocolOpenAI:test_error_chunk()
  self.proto.on_stdout(10, {
    'data: {"error":{"code":429,"message":"rate limited"}}',
    '',
  })
  flush()
  lu.assertEquals(#S.appended, 1)
  lu.assertStrContains(S.appended[1].error, 'API Error (429)')
  lu.assertStrContains(S.appended[1].error, 'rate limited')
  lu.assertEquals(#S.ui_messages, 1)
end

function TestProtocolOpenAI:test_error_chunk_defaults()
  self.proto.on_stdout(11, { 'data: {"error":{}}', '' })
  flush()
  lu.assertEquals(#S.appended, 1)
  lu.assertStrContains(S.appended[1].error, 'API Error (unknown): Unknown error')
end

function TestProtocolOpenAI:test_multi_line_sse_event()
  -- Two data: lines in one event are joined with newline before decode
  self.proto.on_stdout(12, {
    'data: {"choices":',
    'data: [{"delta":{"content":"joined"}}]}',
    '',
  })
  flush()
  lu.assertEquals(S.progress, { 'joined' })
end

function TestProtocolOpenAI:test_on_stderr_noop()
  self.proto.on_stderr(13, { 'some curl noise' })
  flush(100)
  lu.assertEquals(#S.appended, 0)
end

function TestProtocolOpenAI:test_exit_without_session()
  S.session = nil
  self.proto.on_exit(14, 0, 0)
  flush()
  lu.assertTrue(S.exited, 'cleans up progress state')
  lu.assertEquals(#S.appended, 0)
end

function TestProtocolOpenAI:test_exit_reason_stop_sends_tool_results()
  S.finish_reason = 'stop'
  S.messages = { { role = 'tool', content = 'result' } }
  self.proto.on_exit(15, 0, 0)
  flush()
  lu.assertTrue(S.done)
  lu.assertTrue(S.complete)
  lu.assertTrue(S.sent_tool_results)
  lu.assertFalse(S.nudged)
  lu.assertTrue(S.spinner_stopped)
end

function TestProtocolOpenAI:test_exit_reason_stop_nudges_when_no_tools()
  S.finish_reason = 'stop'
  S.messages = { { role = 'assistant', content = 'done' } }
  self.proto.on_exit(16, 0, 0)
  flush()
  lu.assertTrue(S.nudged)
  lu.assertFalse(S.sent_tool_results)
end

function TestProtocolOpenAI:test_exit_skips_tool_results_when_pending_async()
  S.finish_reason = 'stop'
  S.pending_async = true
  S.messages = { { role = 'tool', content = 'result' } }
  self.proto.on_exit(17, 0, 0)
  flush()
  lu.assertFalse(S.sent_tool_results)
  lu.assertFalse(S.nudged)
end

function TestProtocolOpenAI:test_exit_skips_when_last_message_is_error()
  S.finish_reason = 'stop'
  S.messages = { { role = 'assistant', content = 'x' }, { error = 'API Error' } }
  self.proto.on_exit(18, 0, 0)
  flush()
  lu.assertFalse(S.sent_tool_results)
  lu.assertFalse(S.nudged)
end

function TestProtocolOpenAI:test_exit_reason_tool_calls()
  S.finish_reason = 'tool_calls'
  self.proto.on_exit(19, 0, 0)
  flush()
  lu.assertTrue(S.tool_done)
  lu.assertFalse(S.done)
end

function TestProtocolOpenAI:test_exit_cancelled_by_signal()
  S.finish_reason = 'stop'
  self.proto.on_exit(20, 0, 2)
  flush()
  lu.assertEquals(#S.appended, 1)
  lu.assertStrContains(S.appended[1].error, 'cancelled')
end

function TestProtocolOpenAI:test_exit_curl_error_with_retry_hint()
  S.retry_hint = 'Auto-retrying (attempt 1/3)...'
  self.proto.on_exit(21, 6, 0)
  flush()
  lu.assertEquals(#S.appended, 1)
  lu.assertStrContains(S.appended[1].error, "Couldn't resolve host")
  lu.assertStrContains(S.appended[1].error, 'Auto-retrying')
end

function TestProtocolOpenAI:test_exit_curl_error_unknown_code()
  self.proto.on_exit(22, 99, 0)
  flush()
  lu.assertEquals(#S.appended, 1)
  lu.assertStrContains(S.appended[1].error, 'exit code 99')
end

function TestProtocolOpenAI:test_exit_body_buffer_error_object()
  -- non-SSE lines accumulate into body buffer, decoded on exit
  self.proto.on_stdout(23, { '{"error":{"code":401,"message":"bad key"}}', '' })
  flush()
  self.proto.on_exit(23, 0, 0)
  flush()
  lu.assertEquals(#S.appended, 1)
  lu.assertStrContains(S.appended[1].error, 'API Error (401)')
end

function TestProtocolOpenAI:test_exit_body_buffer_code_object()
  -- qwen style error: {"code":..., "msg":...}
  self.proto.on_stdout(24, { '{"code":1100,"msg":"invalid api key"}', '' })
  flush()
  S.finish_reason = nil
  self.proto.on_exit(24, 0, 0)
  flush()
  lu.assertEquals(#S.appended, 1)
  lu.assertStrContains(S.appended[1].error, 'API Error (1100)')
  lu.assertStrContains(S.appended[1].error, 'invalid api key')
end

function TestProtocolOpenAI:test_exit_body_buffer_invalid_json()
  self.proto.on_stdout(25, { 'not json at all', '' })
  flush()
  self.proto.on_exit(25, 0, 0)
  flush()
  lu.assertEquals(#S.appended, 0)
end

function TestProtocolOpenAI:test_exit_no_finish_reason()
  S.finish_reason = nil
  self.proto.on_exit(26, 0, 0)
  flush()
  lu.assertFalse(S.done)
  lu.assertTrue(S.exited)
end

TestProtocolGemini = {}

function TestProtocolGemini:setUp()
  reset_state()
  self.proto = load_protocol_fresh('gemini')
end

function TestProtocolGemini:tearDown()
  restore_modules()
end

function TestProtocolGemini:test_content_stream()
  self.proto.on_stdout(1, {
    '{"candidates":[{"content":{"parts":[{"text":"Hello "},{"text":"Gemini"}],"role":"model"}}]}',
  })
  flush()
  lu.assertEquals(S.progress, { 'Hello ', 'Gemini' })
end

function TestProtocolGemini:test_empty_text_part_ignored()
  self.proto.on_stdout(2, {
    '{"candidates":[{"content":{"parts":[{"text":""}],"role":"model"}}]}',
  })
  flush()
  lu.assertEquals(#S.progress, 0)
end

function TestProtocolGemini:test_finish_reason_stop()
  self.proto.on_stdout(3, { '{"candidates":[{"finishReason":"STOP"}]}' })
  flush()
  lu.assertEquals(S.finish_reason, 'stop')
end

function TestProtocolGemini:test_finish_reason_max_tokens()
  self.proto.on_stdout(4, { '{"candidates":[{"finishReason":"MAX_TOKENS"}]}' })
  flush()
  lu.assertEquals(S.finish_reason, 'length')
end

function TestProtocolGemini:test_finish_reason_safety()
  self.proto.on_stdout(5, { '{"candidates":[{"finishReason":"SAFETY"}]}' })
  flush()
  lu.assertEquals(S.finish_reason, 'content_filter')
end

function TestProtocolGemini:test_finish_reason_other()
  self.proto.on_stdout(6, { '{"candidates":[{"finishReason":"RECITATION"}]}' })
  flush()
  lu.assertEquals(S.finish_reason, 'recitation')
end

function TestProtocolGemini:test_usage_metadata()
  self.proto.on_stdout(7, {
    '{"usageMetadata":{"promptTokenCount":10,"candidatesTokenCount":5,"totalTokenCount":15}}',
  })
  flush()
  lu.assertEquals(S.usage.prompt_tokens, 10)
  lu.assertEquals(S.usage.completion_tokens, 5)
  lu.assertEquals(S.usage.total_tokens, 15)
end

function TestProtocolGemini:test_usage_metadata_defaults()
  self.proto.on_stdout(8, { '{"usageMetadata":{}}' })
  flush()
  lu.assertEquals(S.usage.prompt_tokens, 0)
  lu.assertEquals(S.usage.total_tokens, 0)
end

function TestProtocolGemini:test_error_chunk()
  self.proto.on_stdout(9, { '{"error":{"code":500,"message":"boom"}}' })
  flush()
  lu.assertEquals(#S.appended, 1)
  lu.assertStrContains(S.appended[1].error, 'Gemini API Error (500)')
end

function TestProtocolGemini:test_error_chunk_defaults()
  self.proto.on_stdout(10, { '{"error":{}}' })
  flush()
  lu.assertEquals(#S.appended, 1)
  lu.assertStrContains(S.appended[1].error, 'unknown')
end

function TestProtocolGemini:test_invalid_line_accumulates()
  self.proto.on_stdout(11, { '{"error":{' })
  flush()
  -- buffered, no immediate error
  lu.assertEquals(#S.appended, 0)
end

function TestProtocolGemini:test_accumulated_buffer_error_on_exit()
  self.proto.on_stdout(12, { '{"error":{', '"code":503,"message":"split"}}' })
  flush()
  self.proto.on_exit(12, 0, 0)
  flush()
  -- joined buffer decodes into error object
  lu.assertEquals(#S.appended, 1)
  lu.assertStrContains(S.appended[1].error, 'Gemini API Error (503)')
end

function TestProtocolGemini:test_on_stderr_noop()
  self.proto.on_stderr(13, { 'noise' })
  flush(100)
  lu.assertEquals(#S.appended, 0)
end

function TestProtocolGemini:test_exit_without_session()
  S.session = nil
  self.proto.on_exit(14, 0, 0)
  flush()
  lu.assertTrue(S.exited)
  lu.assertEquals(#S.appended, 0)
end

function TestProtocolGemini:test_exit_reason_stop()
  S.finish_reason = 'stop'
  self.proto.on_exit(15, 0, 0)
  flush()
  lu.assertTrue(S.done)
  lu.assertTrue(S.complete)
  lu.assertTrue(S.nudged)
  lu.assertTrue(S.spinner_stopped)
end

function TestProtocolGemini:test_exit_stop_skips_nudge_with_pending_async()
  S.finish_reason = 'stop'
  S.pending_async = true
  self.proto.on_exit(16, 0, 0)
  flush()
  lu.assertFalse(S.nudged)
end

function TestProtocolGemini:test_exit_tool_calls_reason_no_done()
  S.finish_reason = 'tool_calls'
  self.proto.on_exit(17, 0, 0)
  flush()
  lu.assertFalse(S.done)
  lu.assertTrue(S.exited)
end

function TestProtocolGemini:test_exit_cancelled_by_signal()
  self.proto.on_exit(18, 0, 2)
  flush()
  lu.assertEquals(#S.appended, 1)
  lu.assertStrContains(S.appended[1].error, 'cancelled')
end

function TestProtocolGemini:test_exit_curl_error_with_hint()
  S.retry_hint = 'will retry'
  self.proto.on_exit(19, 28, 0)
  flush()
  lu.assertEquals(#S.appended, 1)
  lu.assertStrContains(S.appended[1].error, 'Operation timeout')
  lu.assertStrContains(S.appended[1].error, 'will retry')
end

function TestProtocolGemini:test_exit_curl_error_unknown_code()
  self.proto.on_exit(20, 77, 0)
  flush()
  lu.assertEquals(#S.appended, 1)
  lu.assertStrContains(S.appended[1].error, 'exit code 77')
end

function TestProtocolGemini:test_exit_nonzero_without_retry_hint()
  S.finish_reason = 'stop'
  self.proto.on_exit(21, 7, 0)
  flush()
  lu.assertEquals(#S.appended, 1)
  lu.assertStrContains(S.appended[1].error, 'Failed to connect')
end

