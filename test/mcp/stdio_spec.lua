local lu = require('luaunit')
local job = require('job')
local stdio = require('chat.mcp.transport.stdio')

TestStdioTransport = {}

function TestStdioTransport:setUp()
  job.reset()
  job.intercept(true)
end

function TestStdioTransport:tearDown()
  job.reset()
end

function TestStdioTransport:testCreateRequiresCommand()
  local t, err = stdio.create('srv', {}, function() end)
  lu.assertNil(t)
  lu.assertStrContains(err, 'command')
end

function TestStdioTransport:testCreate()
  local msgs = {}
  local t, err = stdio.create(
    'srv',
    { command = 'echo', args = { 'hi' }, env = { A = '1' } },
    function(m) table.insert(msgs, m) end
  )
  lu.assertNil(err)
  lu.assertNotNil(t)
  lu.assertEquals('stdio', t.type)
  lu.assertEquals(1, t.jobid)
  lu.assertEquals('srv', t.server_name)
end

function TestStdioTransport:testSend()
  local t = stdio.create('srv', { command = 'echo' }, function() end)
  stdio.send(t, '{"jsonrpc":"2.0"}\n')
  lu.assertEquals(1, #job.jobs[t.jobid].stdin)
  lu.assertEquals('{"jsonrpc":"2.0"}\n', job.jobs[t.jobid].stdin[1])
end

function TestStdioTransport:testSendNoJob()
  stdio.send({ jobid = nil }, 'x')
end

function TestStdioTransport:testClose()
  local t = stdio.create('srv', { command = 'echo' }, function() end)
  stdio.close(t)
  lu.assertNil(t.jobid)
  lu.assertNotNil(job.jobs[1].stopped)
end

function TestStdioTransport:testCloseNoJob()
  stdio.close({ jobid = nil })
end

function TestStdioTransport:testOnStdoutJson()
  local msgs = {}
  stdio.create('srv', { command = 'echo' }, function(m) table.insert(msgs, m) end)
  job.emit_stdout(1, '{"jsonrpc":"2.0","id":1,"result":{}}')
  lu.assertEquals(1, #msgs)
  lu.assertEquals(1, msgs[1].id)
end

function TestStdioTransport:testOnStdoutMultiLine()
  local msgs = {}
  stdio.create('srv', { command = 'echo' }, function(m) table.insert(msgs, m) end)
  job.emit_stdout(1, '{"id":1}\nnot json\n{"id":2}')
  lu.assertEquals(2, #msgs)
end

function TestStdioTransport:testOnStdoutInvalidJson()
  stdio.create('srv', { command = 'echo' }, function(m) error('should not fire') end)
  job.emit_stdout(1, '{invalid json')
end

function TestStdioTransport:testOnStderr()
  stdio.create('srv', { command = 'echo' }, function() end)
  job.emit_stderr(1, 'some debug line')
end

function TestStdioTransport:testOnExit()
  local disconnected = false
  local t = stdio.create(
    'srv',
    { command = 'echo', on_disconnect = function() disconnected = true end },
    function() end
  )
  job.emit_exit(1, 0, 0)
  lu.assertTrue(disconnected)
  lu.assertNil(t.jobid)
end

return TestStdioTransport
