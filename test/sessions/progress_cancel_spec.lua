-- Session progress cancel deadlock recovery tests
--
-- Reproduces: a tool's on_exit crashing before invoking ctx.callback leaks
-- the pending async tool entry, so is_in_progress stays true forever and
-- stop / continue / send are all rejected. cancel_progress must release the
-- session state even when the underlying job already exited.
local lu = require('luaunit')
local job = require('job') -- test stub (interception mode)
local storage = require('chat.sessions.storage')
local sessions = require('chat.sessions')
local async = require('chat.sessions.async')
local progress = require('chat.sessions.progress')
local config = require('chat.config')

TestProgressCancel = {}

-- sessions.new() ids are second-resolution timestamps and collide when
-- several tests run within the same second; seed unique ids directly in
-- storage instead (same approach as http_routes_spec).
local sid_seq = 0

function TestProgressCancel:setUp()
  config.setup({
    provider = 'test-provider',
    model = 'test-model',
    storage_dir = vim.fn.tempname() .. '_cancel_test/',
  })
  self.test_cache_dir = vim.fn.tempname() .. '_cancel_cache/'
  sessions.set_cache_dir(self.test_cache_dir)
  job.intercept()
end

function TestProgressCancel:tearDown()
  -- Reset module-level state so residual entries from live-job tests
  -- (whose pending entries are intentionally left for the exit chain)
  -- never leak into other specs sharing this process.
  async.pending_async_tools = {}
  async.cancelled_sessions = {}
  job.reset()
  if self.test_cache_dir and vim.fn.isdirectory(self.test_cache_dir) == 1 then
    vim.fn.delete(self.test_cache_dir, 'rf')
  end
  local storage_dir = config.config.storage_dir
  if storage_dir and vim.fn.isdirectory(storage_dir) == 1 then
    vim.fn.delete(storage_dir, 'rf')
  end
end

--- Create a session with a unique id directly in storage.
--- @return string session_id
local function new_session()
  sid_seq = sid_seq + 1
  local sid = '2099-01-01-00-00-'
  .. string.format('%02d', sid_seq)
  storage.sessions[sid] = {
    id = sid,
    messages = {},
    provider = 'test-provider',
    model = 'test-model',
    cwd = vim.fn.getcwd(),
  }
  return sid
end

--- Build a session with an assistant tool_calls message, then register a
--- pending async tool whose job already exited (default stub state: the
--- recorded job is not running, mirroring a crashed on_exit).
--- @return string session_id
--- @return integer jobid
local function deadlocked_session()
  local sid = new_session()
  sessions.append_message(sid, {
    role = 'assistant',
    tool_calls = {
      {
        id = 'call_fix',
        type = 'function',
        ['function'] = { name = 'fetch_web', arguments = '{}' },
      },
    },
    created = os.time(),
  })
  local jobid = job.start('curl mock', {})
  async.start_async_tool(sid, jobid, {
    tool_call_id = 'call_fix',
    tool_name = 'fetch_web',
  })
  return sid, jobid
end

function TestProgressCancel:test_cancel_releases_dead_job_and_appends_tool_result()
  local sid = deadlocked_session()

  -- Session is stuck: job exited but pending entry leaked
  lu.assertTrue(sessions.is_in_progress(sid))

  sessions.cancel_progress(sid)

  -- Deadlock released: session accepts new messages again
  lu.assertFalse(sessions.is_in_progress(sid))

  -- A placeholder tool result was appended so the assistant tool_calls
  -- history stays valid for the next request
  local msgs = sessions.get_messages(sid)
  local found = false
  for _, m in ipairs(msgs) do
    if m.role == 'tool' and m.tool_call_id == 'call_fix' then
      found = true
      lu.assertStrContains(m.content, 'fetch_web')
    end
  end
  lu.assertTrue(found, 'expected a tool result for call_fix after cancel')

  -- Cancel is idempotent: a second cancel must not duplicate the message
  sessions.cancel_progress(sid)
  local count = 0
  for _, m in ipairs(sessions.get_messages(sid)) do
    if m.role == 'tool' and m.tool_call_id == 'call_fix' then
      count = count + 1
    end
  end
  lu.assertEquals(count, 1)
end

function TestProgressCancel:test_cancel_live_job_sends_stop_signal()
  local sid = new_session()
  local jobid = job.start('curl mock', {})
  job.set_running(jobid, true)
  async.start_async_tool(sid, jobid, {
    tool_call_id = 'call_live',
    tool_name = 'fetch_web',
  })

  sessions.cancel_progress(sid)

  -- Live job: signal sent, pending entry left for the normal exit chain
  lu.assertEquals(job.jobs[jobid].stopped, 2)
  lu.assertTrue(async.has_pending_async_tools(sid))
  -- Cancel semantics: the eventual finish must not send a new request
  lu.assertTrue(async.cancelled_sessions[sid] == true)
end

function TestProgressCancel:test_cancel_releases_stale_mcp_pending()
  local sid = new_session()
  sessions.append_message(sid, {
    role = 'assistant',
    tool_calls = {
      {
        id = 'call_mcp',
        type = 'function',
        ['function'] = { name = 'mcp_srv_tool', arguments = '{}' },
      },
    },
    created = os.time(),
  })
  -- Negative id = MCP tool call; no mapping registered => cancel_request
  -- returns false and no callback fires: force-finish path
  async.start_async_tool(sid, -42, {
    tool_call_id = 'call_mcp',
    tool_name = 'mcp_srv_tool',
  })
  lu.assertTrue(sessions.is_in_progress(sid))

  sessions.cancel_progress(sid)

  lu.assertFalse(sessions.is_in_progress(sid))
  local found = false
  for _, m in ipairs(sessions.get_messages(sid)) do
    if m.role == 'tool' and m.tool_call_id == 'call_mcp' then
      found = true
    end
  end
  lu.assertTrue(found)
end

function TestProgressCancel:test_cancel_clears_dead_llm_streaming_job()
  local sid = new_session()
  local llm_jobid = job.start('curl llm mock', {}) -- stub job: not running
  progress.set_session_jobid(sid, llm_jobid)
  lu.assertTrue(sessions.is_in_progress(sid))

  sessions.cancel_progress(sid)

  -- Leaked jobid_session entry cleared
  lu.assertFalse(sessions.is_in_progress(sid))
  lu.assertNil(progress.get_progress_session(llm_jobid))
end

function TestProgressCancel:test_cancel_live_llm_job_only_signals()
  local sid = new_session()
  local llm_jobid = job.start('curl llm mock', {})
  job.set_running(llm_jobid, true)
  progress.set_session_jobid(sid, llm_jobid)

  sessions.cancel_progress(sid)

  lu.assertEquals(job.jobs[llm_jobid].stopped, 2)
  -- Entry remains until the exit callback chain cleans it up
  lu.assertEquals(progress.get_progress_session(llm_jobid), sid)
end

function TestProgressCancel:test_finish_async_tool_clears_context()
  local sid = new_session()
  local jobid = job.start('mock', {})
  async.start_async_tool(sid, jobid, {
    tool_call_id = 'call_ctx',
    tool_name = 'fetch_web',
  })
  lu.assertStrContains(
    vim.inspect(async.get_tool_context(sid, jobid)),
    'call_ctx'
  )

  async.finish_async_tool(sid, jobid)

  lu.assertNil(async.get_tool_context(sid, jobid))
  lu.assertNotTrue(async.has_pending_async_tools(sid))
end

function TestProgressCancel:test_cancel_without_pending_state_is_noop()
  local sid = new_session()
  -- No retry, no llm job, no async tools: must not error
  sessions.cancel_progress(sid)
  lu.assertFalse(sessions.is_in_progress(sid))
end

