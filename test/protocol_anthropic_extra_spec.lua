local lu = require('luaunit')
local anthropic = require('chat.protocol.anthropic')
local sessions = require('chat.sessions')
local windows = require('chat.windows')
local spinners = require('chat.spinners')
local continue_mod = require('chat.sessions.continue')
local retry_mod = require('chat.sessions.retry')
local curl = require('chat.curl')

-- Save original references so mocks never leak into other spec files.
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
  'get_messages',
  'get_request_messages',
  'has_pending_async_tools',
  'send_tool_results',
  'nudge_if_dirty',
}
local sessions_orig = {}
for _, m in ipairs(sessions_methods) do
  sessions_orig[m] = sessions[m]
end
local windows_orig = {
  on_message = windows.on_message,
  current_session = windows.current_session,
}
local spinners_stop_orig = spinners.stop
local continue_orig = continue_mod.continue
local retry_orig = retry_mod.handle_exit_error
local curl_orig = curl.get_error_message

local function reset_mocks()
  sessions.get_progress_session = function() return 's1' end
  sessions.set_progress_usage = function() end
  sessions.set_progress_finish_reason = function() end
  sessions.get_progress_finish_reason = function() return nil end
  sessions.on_progress = function() end
  sessions.on_progress_reasoning_content = function() end
  sessions.on_progress_tool_call = function() end
  sessions.on_progress_tool_call_done = function() end
  sessions.on_progress_done = function() end
  sessions.on_complete = function() end
  sessions.on_progress_partial = function() end
  sessions.on_progress_exit = function() end
  sessions.append_message = function() end
  sessions.get_messages = function() return { { role = 'assistant', content = 'x' } } end
  sessions.get_request_messages = function() return { { role = 'assistant', content = 'x' } } end
  sessions.has_pending_async_tools = function() return false end
  sessions.send_tool_results = function() end
  sessions.nudge_if_dirty = function() end
  windows.on_message = function() end
  windows.current_session = function() return 's1' end
  spinners.stop = function() end
  continue_mod.continue = function() return nil, nil end
  retry_mod.handle_exit_error = function() return nil end
  curl.get_error_message = function() return 'curl error' end
end

local function restore_mocks()
  for m, orig in pairs(sessions_orig) do
    sessions[m] = orig
  end
  windows.on_message = windows_orig.on_message
  windows.current_session = windows_orig.current_session
  spinners.stop = spinners_stop_orig
  continue_mod.continue = continue_orig
  retry_mod.handle_exit_error = retry_orig
  curl.get_error_message = curl_orig
end

local function wait_schedule()
  vim.wait(50, function() return false end)
end

TestProtocolAnthropicExtra = {}

function TestProtocolAnthropicExtra:setUp()
  reset_mocks()
end

function TestProtocolAnthropicExtra:tearDown()
  restore_mocks()
end

function TestProtocolAnthropicExtra:testConvertMessageToolResult()
  local system_prompt, msgs = anthropic.convert_message({
    {
      role = 'tool',
      content = 'tool output',
      tool_call_id = 'tc_1',
    },
  })
  lu.assertNil(system_prompt)
  lu.assertEquals('user', msgs[1].role)
  lu.assertEquals('tool_result', msgs[1].content[1].type)
  lu.assertEquals('tc_1', msgs[1].content[1].tool_use_id)
end

function TestProtocolAnthropicExtra:testConvertMessageAssistantWithToolCalls()
  local _, msgs = anthropic.convert_message({
    {
      role = 'assistant',
      tool_calls = {
        {
          id = 'id1',
          ['function'] = { name = 'read_file', arguments = '{"filepath":"a"}' },
        },
      },
    },
  })
  lu.assertEquals('assistant', msgs[1].role)
  lu.assertEquals('tool_use', msgs[1].content[1].type)
  lu.assertEquals('read_file', msgs[1].content[1].name)
end

function TestProtocolAnthropicExtra:testConvertMessageAssistantBadToolArgs()
  local _, msgs = anthropic.convert_message({
    {
      role = 'assistant',
      tool_calls = {
        { id = 'id1', ['function'] = { name = 'x', arguments = 'not json' } },
      },
    },
  })
  lu.assertEquals('tool_use', msgs[1].content[1].type)
  lu.assertEquals({}, msgs[1].content[1].input)
end

function TestProtocolAnthropicExtra:testOnExitNoSession()
  sessions.get_progress_session = function() return nil end
  anthropic.on_exit(1, 0, 0)
  wait_schedule()
  lu.assertTrue(true)
end

function TestProtocolAnthropicExtra:testOnExitStopReason()
  sessions.get_progress_finish_reason = function() return 'stop' end
  local done = false
  sessions.on_progress_done = function() done = true end
  anthropic.on_exit(1, 0, 0)
  wait_schedule()
  lu.assertTrue(done)
end

function TestProtocolAnthropicExtra:testOnExitToolUseReason()
  sessions.get_progress_finish_reason = function() return 'tool_use' end
  local tool_done = false
  sessions.on_progress_tool_call_done = function() tool_done = true end
  anthropic.on_exit(1, 0, 0)
  wait_schedule()
  lu.assertTrue(tool_done)
end

function TestProtocolAnthropicExtra:testOnExitLengthReason()
  sessions.get_progress_finish_reason = function() return 'length' end
  local partial = false
  sessions.on_progress_partial = function() partial = true end
  continue_mod.continue = function() return 99, nil end
  anthropic.on_exit(1, 0, 0)
  wait_schedule()
  lu.assertTrue(partial)
end

function TestProtocolAnthropicExtra:testOnExitSignalCancelled()
  local appended
  sessions.append_message = function(_, msg) appended = msg end
  sessions.get_progress_finish_reason = function() return nil end
  anthropic.on_exit(1, 0, 2)
  wait_schedule()
  lu.assertNotNil(appended)
  lu.assertStrContains(appended.error, 'cancelled')
end

function TestProtocolAnthropicExtra:testOnExitNonZeroCode()
  sessions.get_progress_finish_reason = function() return nil end
  local appended
  sessions.append_message = function(_, msg) appended = msg end
  anthropic.on_exit(1, 7, 0)
  wait_schedule()
  lu.assertNotNil(appended)
  lu.assertStrContains(appended.error, 'curl error')
end

function TestProtocolAnthropicExtra:testOnStdoutMessageStart()
  sessions.get_progress_finish_reason = function() return nil end
  local usage
  sessions.set_progress_usage = function(_, u) usage = u end
  anthropic.on_stdout(1, {
    '',
    'data: {"type":"message_start","message":{"usage":{"input_tokens":5,"output_tokens":3}}}',
    '',
  })
  wait_schedule()
  lu.assertNotNil(usage)
  lu.assertEquals(8, usage.total_tokens)
end

function TestProtocolAnthropicExtra:testOnStdoutTextDelta()
  local progress
  sessions.on_progress = function(_, txt) progress = txt end
  anthropic.on_stdout(1, {
    '',
    'data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"hi"}}',
    '',
  })
  wait_schedule()
  lu.assertEquals('hi', progress)
end

function TestProtocolAnthropicExtra:testOnStdoutErrorChunk()
  local appended
  sessions.append_message = function(_, msg) appended = msg end
  anthropic.on_stdout(1, {
    '',
    'data: {"error":{"message":"boom","type":"invalid_request"}}',
    '',
  })
  wait_schedule()
  lu.assertNotNil(appended)
  lu.assertStrContains(appended.error, 'boom')
end

function TestProtocolAnthropicExtra:testOnStdoutPingIgnored()
  anthropic.on_stdout(1, {
    '',
    'data: {"type":"ping"}',
    '',
  })
  wait_schedule()
  lu.assertTrue(true)
end

return TestProtocolAnthropicExtra
