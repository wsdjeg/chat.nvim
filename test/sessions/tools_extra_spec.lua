-- Coverage for the streaming tool-call pipeline in chat.sessions.tools:
-- delta accumulation (on_progress_tool_call), the completion dispatcher
-- (on_progress_tool_call_done) with sync/async/error/undecodable paths,
-- the async result callback incl. idempotent duplicate suppression, and
-- send_tool_results.
--
-- Uses a real session stored in chat.sessions.storage and stubs the
-- surrounding modules (progress, windows, protocol, spinners, async,
-- retry, chat.tools.call). Every test gets a unique session id and a
-- clean instance state (luaunit reuses the class instance table between
-- tests, so setUp must reset ALL mutable fields, including tool_impl).

local lu = require('luaunit')

local st = require('chat.sessions.tools')
local storage = require('chat.sessions.storage')
local messages = require('chat.sessions.messages')
local progress = require('chat.sessions.progress')
local windows = require('chat.windows')
local tools = require('chat.tools')
local protocol = require('chat.protocol')
local spinners = require('chat.spinners')
local retry = require('chat.sessions.retry')
local async = require('chat.sessions.async')

local CWD = vim.fs.normalize(vim.fn.getcwd())

TestSessionsToolsExtra = {}

local orig = {}

local function save(module, name)
  table.insert(orig, { module = module, name = name, fn = module[name] })
end

function TestSessionsToolsExtra:setUp()
  -- Reset ALL mutable instance state first: luaunit reuses the class
  -- instance table, so stubs installed by a previous test (e.g. tool_impl)
  -- would otherwise leak into this one via the shared self table.
  self.tool_impl = nil
  self.tool_result = { content = 'ok' }

  -- unique session per test: total isolation of the message history
  self.sid = 'tool-extra-' .. tostring(os.time()) .. '-' .. tostring(math.random(100000, 999999))

  storage.sessions[self.sid] = {
    id = self.sid,
    cwd = CWD,
    messages = {},
    created = os.time(),
  }

  orig = {}

  -- progress
  save(progress, 'get_progress_session')
  save(progress, 'get_progress_usage')
  save(progress, 'on_progress_done')
  progress.get_progress_session = function()
    return self.sid
  end
  self.usage_seen = nil
  progress.get_progress_usage = function(jobid)
    self.usage_seen = jobid
    return { total_tokens = 11 }
  end
  self.done_calls = {}
  progress.on_progress_done = function(jobid, opts)
    table.insert(self.done_calls, { jobid = jobid, opts = opts })
  end

  -- windows
  save(windows, 'on_message')
  save(windows, 'on_tool_call_start')
  save(windows, 'on_tool_call_done')
  save(windows, 'current_session')
  self.win_messages = {}
  windows.on_message = function(_, msg)
    table.insert(self.win_messages, msg)
  end
  self.tool_starts = {}
  windows.on_tool_call_start = function(sid, msg)
    table.insert(self.tool_starts, { sid = sid, msg = msg })
  end
  self.tool_dones = {}
  windows.on_tool_call_done = function(sid, msgs)
    table.insert(self.tool_dones, { sid = sid, msgs = msgs })
  end
  windows.current_session = function()
    return self.sid
  end

  -- messages.get_request_messages
  save(messages, 'get_request_messages')
  self.request_messages = nil
  messages.get_request_messages = function(_)
    return self.request_messages
  end

  -- storage.write_cache
  save(storage, 'write_cache')
  self.cache_writes = 0
  storage.write_cache = function(_)
    self.cache_writes = self.cache_writes + 1
  end

  -- protocol
  save(protocol, 'request')
  self.protocol_calls = {}
  protocol.request = function(opts)
    table.insert(self.protocol_calls, opts)
    return self.protocol_result
  end

  -- spinners
  save(spinners, 'start')
  self.spinner_starts = 0
  spinners.start = function()
    self.spinner_starts = self.spinner_starts + 1
  end

  -- retry
  save(retry, 'reset_retry_count')
  self.retry_resets = 0
  retry.reset_retry_count = function(_)
    self.retry_resets = self.retry_resets + 1
  end

  -- async
  save(async, 'start_async_tool')
  save(async, 'finish_async_tool')
  self.async_starts = {}
  async.start_async_tool = function(sid, jobid, ctx)
    table.insert(self.async_starts, { sid = sid, jobid = jobid, ctx = ctx })
  end
  self.async_finishes = {}
  async.finish_async_tool = function(sid, jobid)
    table.insert(self.async_finishes, { sid = sid, jobid = jobid })
  end

  -- tools.call
  save(tools, 'call')
  self.tool_calls = {}
  tools.call = function(name, args, ctx)
    table.insert(self.tool_calls, { name = name, args = args, ctx = ctx })
    if type(self.tool_impl) == 'function' then
      return self.tool_impl(name, args, ctx)
    end
    return self.tool_result
  end
end

function TestSessionsToolsExtra:tearDown()
  for _, entry in ipairs(orig) do
    entry.module[entry.name] = entry.fn
  end
  if self.sid then
    storage.sessions[self.sid] = nil
    async.cancelled_sessions[self.sid] = nil
  end
end

local function tool_messages(sid)
  local out = {}
  for _, m in ipairs(storage.sessions[sid].messages) do
    if m.role == 'tool' then
      table.insert(out, m)
    end
  end
  return out
end

local function find_message(sid, predicate)
  for _, m in ipairs(storage.sessions[sid].messages) do
    if predicate(m) then
      return m
    end
  end
  return nil
end

-- delta accumulation -------------------------------------------------------

function TestSessionsToolsExtra:testDeltaAccumulationOverwriteRules()
  st.on_progress_tool_call(101, {
    index = 1,
    id = 't1',
    type = 'function',
    ['function'] = { name = 'read_file', arguments = '{"a"' },
  })
  -- name is not a delta: an empty or vim.NIL name must not overwrite
  st.on_progress_tool_call(101, {
    index = 1,
    ['function'] = { name = vim.NIL, arguments = ': 1}' },
  })
  st.on_progress_tool_call(101, {
    index = 1,
    ['function'] = { name = '', arguments = vim.NIL },
  })

  st.on_progress_tool_call_done(101)

  lu.assertEquals(1, #self.tool_starts)
  local calls = self.tool_starts[1].msg.tool_calls
  lu.assertEquals(1, #calls)
  lu.assertEquals('t1', calls[1].id)
  lu.assertEquals('read_file', calls[1]['function'].name)
  lu.assertEquals('{"a": 1}', calls[1]['function'].arguments)
end

function TestSessionsToolsExtra:testNilIndexDeltaIsIgnored()
  st.on_progress_tool_call(102, {
    id = 'ignored',
    type = 'function',
    ['function'] = { name = 'read_file', arguments = '{}' },
  })
  st.on_progress_tool_call_done(102)
  -- No usable tool call was recorded: an error message is appended
  lu.assertEquals(0, #self.tool_starts)
  local err = find_message(self.sid, function(m)
    return m.error ~= nil
  end)
  lu.assertNotNil(err)
  lu.assertStrContains(err.error, 'Tool call parsing failed')
end

-- completion dispatcher ---------------------------------------------------

function TestSessionsToolsExtra:testDoneWithoutDataAppendsError()
  st.on_progress_tool_call_done(103)
  lu.assertEquals(0, #self.tool_starts)
  lu.assertEquals(1, #self.done_calls)
  lu.assertEquals({}, self.done_calls[1].opts.tool_calls)
  -- on_complete ran after the error message: both notify windows
  lu.assertTrue(self.cache_writes >= 1)
  lu.assertEquals(2, #self.win_messages)
  lu.assertNil(self.win_messages[1].on_complete)
  lu.assertTrue(self.win_messages[2].on_complete)
end

function TestSessionsToolsExtra:testDoneSyncToolSuccess()
  st.on_progress_tool_call(104, {
    index = 1,
    id = 't104',
    type = 'function',
    ['function'] = { name = 'read_file', arguments = '{"filepath":"x"}' },
  })
  st.on_progress_tool_call_done(104)

  lu.assertEquals(1, #self.tool_calls)
  lu.assertEquals('read_file', self.tool_calls[1].name)
  lu.assertEquals({ filepath = 'x' }, self.tool_calls[1].args)
  lu.assertEquals(CWD, self.tool_calls[1].ctx.cwd)
  lu.assertEquals(self.sid, self.tool_calls[1].ctx.session)

  local tm = tool_messages(self.sid)
  lu.assertEquals(1, #tm)
  lu.assertEquals('ok', tm[1].content)
  lu.assertEquals('t104', tm[1].tool_call_id)
  lu.assertEquals(1, #self.tool_dones)
  lu.assertEquals(1, #self.done_calls)
  lu.assertEquals(1, #(self.done_calls[1].opts.tool_calls))
end

function TestSessionsToolsExtra:testDoneSyncToolErrorResult()
  self.tool_result = { error = 'boom' }
  st.on_progress_tool_call(105, {
    index = 1,
    id = 't105',
    type = 'function',
    ['function'] = { name = 'git_log', arguments = '{}' },
  })
  st.on_progress_tool_call_done(105)

  local tm = tool_messages(self.sid)
  lu.assertEquals(1, #tm)
  lu.assertStrContains(tm[1].content, 'tool_call run failed')
  lu.assertStrContains(tm[1].content, 'boom')
  lu.assertEquals('boom', tm[1].tool_call_state.error)
  lu.assertEquals('git_log', tm[1].tool_call_state.name)
end

function TestSessionsToolsExtra:testDoneToolCallRaisesError()
  self.tool_impl = function()
    error('exploded')
  end
  st.on_progress_tool_call(106, {
    index = 1,
    id = 't106',
    type = 'function',
    ['function'] = { name = 'git_log', arguments = '{}' },
  })
  st.on_progress_tool_call_done(106)

  local tm = tool_messages(self.sid)
  lu.assertEquals(1, #tm)
  lu.assertStrContains(tm[1].content, 'tool_call raised an error: ')
  lu.assertStrContains(tm[1].tool_call_state.error, 'exploded')
end

function TestSessionsToolsExtra:testDoneToolCallNilResult()
  self.tool_impl = function()
    return nil
  end
  st.on_progress_tool_call(107, {
    index = 1,
    id = 't107',
    type = 'function',
    ['function'] = { name = 'git_log', arguments = '{}' },
  })
  st.on_progress_tool_call_done(107)

  local tm = tool_messages(self.sid)
  lu.assertEquals(1, #tm)
  lu.assertEquals('tool_call returned no result', tm[1].content)
  lu.assertEquals('no result returned from tool', tm[1].tool_call_state.error)
end

function TestSessionsToolsExtra:testDoneAsyncToolRegistersPending()
  self.tool_result = { jobid = 77 }
  st.on_progress_tool_call(108, {
    index = 1,
    id = 't108',
    type = 'function',
    ['function'] = { name = 'make', arguments = '{}' },
  })
  st.on_progress_tool_call_done(108)

  lu.assertEquals(1, #self.async_starts)
  lu.assertEquals(self.sid, self.async_starts[1].sid)
  lu.assertEquals(77, self.async_starts[1].jobid)
  lu.assertEquals('t108', self.async_starts[1].ctx.tool_call_id)
  lu.assertEquals('make', self.async_starts[1].ctx.tool_name)
  lu.assertEquals(0, #tool_messages(self.sid))
end

function TestSessionsToolsExtra:testDoneUndecodableArguments()
  st.on_progress_tool_call(109, {
    index = 1,
    id = 't109',
    type = 'function',
    ['function'] = { name = 'read_file', arguments = 'not-json(' },
  })
  st.on_progress_tool_call_done(109)

  lu.assertEquals(0, #self.tool_calls)
  local tm = tool_messages(self.sid)
  lu.assertEquals(1, #tm)
  lu.assertStrContains(tm[1].content, 'failed to decode arguments')
  lu.assertEquals(1, #self.tool_dones)
end

function TestSessionsToolsExtra:testDoneSkipsToolCallWithoutName()
  st.on_progress_tool_call(110, {
    index = 1,
    id = 't110',
    type = 'function',
    -- no function.name ever streamed
  })
  st.on_progress_tool_call_done(110)

  -- tool call is displayed but not executed
  lu.assertEquals(1, #self.tool_starts)
  lu.assertEquals(0, #self.tool_calls)
  lu.assertEquals(0, #tool_messages(self.sid))
end

-- async result callback ---------------------------------------------------

function TestSessionsToolsExtra:testCallbackAppendsToolResult()
  self.tool_impl = function(_, _, ctx)
    ctx.callback({ content = 'converted', jobid = 99 })
    return { jobid = 99 }
  end
  st.on_progress_tool_call(111, {
    index = 1,
    id = 't111',
    type = 'function',
    ['function'] = { name = 'ffmpeg', arguments = '{}' },
  })
  st.on_progress_tool_call_done(111)

  local tm = tool_messages(self.sid)
  lu.assertEquals(1, #tm)
  lu.assertEquals('converted', tm[1].content)
  lu.assertEquals(1, #self.tool_dones)
  lu.assertEquals(1, #self.async_finishes)
  lu.assertEquals(99, self.async_finishes[1].jobid)
end

function TestSessionsToolsExtra:testCallbackErrorResultMessage()
  self.tool_impl = function(_, _, ctx)
    ctx.callback({ error = 'bad conversion' })
    return { jobid = 98 }
  end
  st.on_progress_tool_call(112, {
    index = 1,
    id = 't112',
    type = 'function',
    ['function'] = { name = 'ffmpeg', arguments = '{}' },
  })
  st.on_progress_tool_call_done(112)

  local tm = tool_messages(self.sid)
  lu.assertEquals(1, #tm)
  lu.assertStrContains(tm[1].content, 'tool_call run failed')
  lu.assertStrContains(tm[1].content, 'bad conversion')
  lu.assertEquals(1, #self.async_finishes)
end

function TestSessionsToolsExtra:testCallbackSuppressesDuplicateResult()
  -- a tool result for t113 already exists (e.g. cancel_progress ran first)
  messages.append_message(self.sid, {
    role = 'tool',
    content = 'stale result',
    tool_call_id = 't113',
    created = os.time(),
  })
  local before = #storage.sessions[self.sid].messages

  self.tool_impl = function(_, _, ctx)
    ctx.callback({ content = 'late duplicate', jobid = 97 })
    return { jobid = 97 }
  end
  st.on_progress_tool_call(113, {
    index = 1,
    id = 't113',
    type = 'function',
    ['function'] = { name = 'ffmpeg', arguments = '{}' },
  })
  st.on_progress_tool_call_done(113)

  -- no duplicate tool result appended: only the on_complete marker adds
  -- one message to the history
  lu.assertEquals(before + 1, #storage.sessions[self.sid].messages)
  local tm = tool_messages(self.sid)
  lu.assertEquals(1, #tm)
  lu.assertEquals('stale result', tm[1].content)
  lu.assertEquals(1, #self.async_finishes)
  lu.assertEquals(97, self.async_finishes[1].jobid)
  lu.assertEquals(0, #self.tool_dones)
end

-- on_complete -------------------------------------------------------------

function TestSessionsToolsExtra:testOnCompleteAppendsUsageMessage()
  st.on_complete(self.sid, 114)
  local msg = find_message(self.sid, function(m)
    return m.on_complete == true
  end)
  lu.assertNotNil(msg)
  lu.assertEquals({ total_tokens = 11 }, msg.usage)
  lu.assertEquals(114, self.usage_seen)
  lu.assertTrue(self.cache_writes >= 1)
  lu.assertEquals(1, #self.win_messages)
end

-- send_tool_results -------------------------------------------------------

function TestSessionsToolsExtra:testSendSkipsCancelledSession()
  async.cancelled_sessions[self.sid] = true
  st.send_tool_results(self.sid)
  lu.assertNil(async.cancelled_sessions[self.sid])
  lu.assertEquals(0, #self.protocol_calls)
end

function TestSessionsToolsExtra:testSendWithoutTrailingToolNoop()
  self.request_messages = { { role = 'assistant', content = 'hi' } }
  st.send_tool_results(self.sid)
  lu.assertEquals(0, #self.protocol_calls)
  lu.assertEquals(0, self.retry_resets)
end

function TestSessionsToolsExtra:testSendWithEmptyMessagesNoop()
  self.request_messages = {}
  st.send_tool_results(self.sid)
  lu.assertEquals(0, #self.protocol_calls)
end

function TestSessionsToolsExtra:testSendTrailingToolStartsRequest()
  self.request_messages = { { role = 'tool', content = 'done' } }
  self.protocol_result = 55
  st.send_tool_results(self.sid)
  lu.assertEquals(1, #self.protocol_calls)
  lu.assertEquals(self.sid, self.protocol_calls[1].session)
  lu.assertEquals(1, self.retry_resets)
  lu.assertEquals(1, self.spinner_starts)
end

function TestSessionsToolsExtra:testSendRequestStartFailureNoSpinner()
  self.request_messages = { { role = 'tool', content = 'done' } }
  self.protocol_result = nil
  st.send_tool_results(self.sid)
  lu.assertEquals(1, #self.protocol_calls)
  lu.assertEquals(0, self.spinner_starts)
end

function TestSessionsToolsExtra:testSendOtherSessionNoSpinner()
  self.request_messages = { { role = 'tool', content = 'done' } }
  self.protocol_result = 66
  windows.current_session = function()
    return 'some-other-session'
  end
  st.send_tool_results(self.sid)
  lu.assertEquals(1, #self.protocol_calls)
  lu.assertEquals(0, self.spinner_starts)
end

return TestSessionsToolsExtra

