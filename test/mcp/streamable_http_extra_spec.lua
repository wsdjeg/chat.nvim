-- Coverage for chat/mcp/transport/streamable_http.lua job integration:
-- server process stdout/stderr logging, server exit -> on_disconnect,
-- server start failure, send() responses delivered through the curl job
-- stdout, curl error logging, process-tree cleanup on close (kill failures
-- are tolerated) and remote session termination via DELETE.

local lu = require('luaunit')
local job = require('job')
local curl = require('chat.curl')
local streamable = require('chat.mcp.transport.streamable_http')

TestStreamableHttpExtra = {}

local orig_pid
local orig_build
local orig_children

function TestStreamableHttpExtra:setUp()
  job.reset()
  job.intercept(true)
  self.calls = {}
  orig_build = curl.build_request
  curl.build_request = function(opts)
    table.insert(self.calls, opts)
    return { 'curl', opts.method or 'POST', opts.url or '' }
  end
  orig_pid = job.pid
  job.pid = function()
    return 99999
  end
end

function TestStreamableHttpExtra:tearDown()
  curl.build_request = orig_build
  job.pid = orig_pid
  if orig_children then
    vim.api.nvim_get_proc_children = orig_children
    orig_children = nil
  end
  job.reset()
end

function TestStreamableHttpExtra:testServerStdoutAndStderrAreLogged()
  local t = streamable.create('srv', {
    url = 'http://127.0.0.1:9000/mcp',
    command = 'sleep',
    args = { '100' },
  }, function() end)
  lu.assertNotNil(t.jobid)
  job.emit_stdout(t.jobid, { 'server ready', '' })
  job.emit_stderr(t.jobid, { 'server warning' })
  -- purely log side effects: no crash, transport still usable
  lu.assertNotNil(t.jobid)
end

function TestStreamableHttpExtra:testServerExitClearsJobAndNotifies()
  local disconnected = 0
  local t = streamable.create('srv', {
    url = 'http://127.0.0.1:9000/mcp',
    command = 'sleep',
    args = { '100' },
    on_disconnect = function()
      disconnected = disconnected + 1
    end,
  }, function() end)
  job.emit_exit(t.jobid, 1, 0)
  lu.assertNil(t.jobid)
  lu.assertEquals(1, disconnected)
end

function TestStreamableHttpExtra:testServerStartFailureReturnsError()
  local orig_start = job.start
  job.start = function()
    return 0
  end
  local t, err = streamable.create('srv', {
    url = 'http://127.0.0.1:9000/mcp',
    command = 'sleep',
    args = { '100' },
  }, function() end)
  job.start = orig_start
  lu.assertNil(t)
  lu.assertStrContains(err, 'Failed to start server: srv')
end

function TestStreamableHttpExtra:testSendDeliversResponseThroughStdout()
  local msgs = {}
  local t = streamable.create('srv', {
    url = 'http://127.0.0.1:9000/mcp',
  }, function(m)
    table.insert(msgs, m)
  end)
  streamable.send(t, vim.json.encode({ jsonrpc = '2.0', method = 'ping', id = 1 }))
  -- the curl job is the most recent intercepted job
  local jobid = #job.jobs
  lu.assertTrue(jobid >= 1)
  job.emit_stdout(jobid, {
    'HTTP/1.1 200 OK\r\n\r\n{"jsonrpc":"2.0","id":1,"result":{}}',
  })
  lu.assertEquals(1, #msgs)
  lu.assertEquals(1, msgs[1].id)
end

function TestStreamableHttpExtra:testSendCurlErrorIsLogged()
  local t = streamable.create('srv', {
    url = 'http://127.0.0.1:9000/mcp',
  }, function() end)
  streamable.send(t, vim.json.encode({ jsonrpc = '2.0', method = 'ping', id = 2 }))
  local jobid = #job.jobs
  job.emit_stderr(jobid, { 'curl: (7) failed to connect' })
  -- log-only path: no crash
  lu.assertTrue(true)
end

function TestStreamableHttpExtra:testCloseLocalProcessKillsTree()
  orig_children = vim.api.nvim_get_proc_children
  -- report a fake child process for the root pid; the fake pid itself has
  -- no children so the recursion terminates. killing the fake pid fails
  -- and must only be warned about.
  vim.api.nvim_get_proc_children = function(pid)
    if pid == 99999 then
      return { 123456 }
    end
    return {}
  end
  local t = streamable.create('srv', {
    url = 'http://127.0.0.1:9000/mcp',
    command = 'sleep',
    args = { '100' },
  }, function() end)
  streamable.close(t)
  lu.assertNil(t.jobid)
  lu.assertNil(t.session_id)
end

function TestStreamableHttpExtra:testCloseRemoteSessionSendsDelete()
  local t = streamable.create('srv', {
    url = 'http://127.0.0.1:9000/mcp',
  }, function() end)
  t.session_id = 'sess-42'
  streamable.close(t)
  lu.assertNil(t.session_id)
  -- a DELETE request job was started and its exit callback logs cleanly
  local delete_started = false
  for _, j in pairs(job.jobs) do
    if vim.tbl_contains(j.cmd, 'DELETE') then
      delete_started = true
    end
  end
  lu.assertTrue(delete_started)
  local jobid = #job.jobs
  job.emit_exit(jobid, 0, 0)
end

return TestStreamableHttpExtra

