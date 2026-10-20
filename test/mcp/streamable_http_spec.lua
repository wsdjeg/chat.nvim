local lu = require('luaunit')
local job = require('job')
local curl = require('chat.curl')
local streamable = require('chat.mcp.transport.streamable_http')

TestStreamableHttpTransport = {}

function TestStreamableHttpTransport:setUp()
  job.reset()
  job.intercept(true)
  self.orig_build = curl.build_request
  self.orig_pid = job.pid
  self.calls = {}
  curl.build_request = function(opts)
    table.insert(self.calls, opts)
    return { 'curl', opts.method or 'POST', opts.url or '' }
  end
  job.pid = function() return 99999 end
end

function TestStreamableHttpTransport:tearDown()
  curl.build_request = self.orig_build
  job.pid = self.orig_pid
  job.reset()
end

function TestStreamableHttpTransport:testCreateRequiresUrl()
  local t, err = streamable.create('srv', {}, function() end)
  lu.assertNil(t)
  lu.assertStrContains(err, 'url')
end

function TestStreamableHttpTransport:testCreate()
  local t, err = streamable.create(
    'srv',
    { url = 'http://127.0.0.1:9000/mcp', headers = { Authorization = 'x' } },
    function() end
  )
  lu.assertNil(err)
  lu.assertEquals('streamable_http', t.type)
  lu.assertEquals('http://127.0.0.1:9000/mcp', t.url)
  lu.assertNil(t.jobid)
end

function TestStreamableHttpTransport:testCreateWithCommand()
  local t, err = streamable.create(
    'srv',
    { url = 'http://127.0.0.1:9000/mcp', command = 'echo', args = { 'x' } },
    function() end
  )
  lu.assertNil(err)
  lu.assertNotNil(t.jobid)
end

function TestStreamableHttpTransport:testHandleResponseJson()
  local msgs = {}
  local t = { on_message = function(m) table.insert(msgs, m) end, session_id = nil, server_name = 'srv' }
  streamable._handle_response(t, 'HTTP/1.1 200 OK\r\nMcp-Session-Id: abc123\r\n\r\n{"jsonrpc":"2.0","id":1,"result":{}}')
  lu.assertEquals(1, #msgs)
  lu.assertEquals(1, msgs[1].id)
  lu.assertEquals('abc123', t.session_id)
end

function TestStreamableHttpTransport:testHandleResponseEmptyBody()
  local msgs = {}
  local t = { on_message = function(m) table.insert(msgs, m) end, session_id = nil, server_name = 'srv' }
  streamable._handle_response(t, 'HTTP/1.1 200 OK\r\n\r\n')
  lu.assertEquals(0, #msgs)
end

function TestStreamableHttpTransport:testHandleResponseSse()
  local msgs = {}
  local t = { on_message = function(m) table.insert(msgs, m) end, session_id = nil, server_name = 'srv' }
  streamable._handle_response(
    t,
    'HTTP/1.1 200 OK\r\n\r\nevent: message\ndata: {"id":7}\n\ndata: {"id":8}\n'
  )
  lu.assertEquals(2, #msgs)
  lu.assertEquals(7, msgs[1].id)
  lu.assertEquals(8, msgs[2].id)
end

function TestStreamableHttpTransport:testHandleResponseBatch()
  local msgs = {}
  local t = { on_message = function(m) table.insert(msgs, m) end, session_id = nil, server_name = 'srv' }
  streamable._handle_response(t, 'HTTP/1.1 200 OK\r\n\r\n[{"id":1},{"id":2}]')
  lu.assertEquals(2, #msgs)
end

function TestStreamableHttpTransport:testSend()
  local t = {
    url = 'http://127.0.0.1:9000/mcp',
    headers = { Authorization = 'Bearer x' },
    session_id = 'sess-1',
    server_name = 'srv',
  }
  streamable.send(t, '{"jsonrpc":"2.0","id":1}\n')
  lu.assertEquals(1, #self.calls)
  local opts = self.calls[1]
  lu.assertEquals('http://127.0.0.1:9000/mcp', opts.url)
  lu.assertTrue(opts.no_proxy)
  lu.assertStrContains(opts.body, '{"jsonrpc":"2.0","id":1}')
end

function TestStreamableHttpTransport:testSendRemoteUrlNotNoProxy()
  local t = { url = 'https://example.com/mcp', headers = {}, session_id = nil }
  streamable.send(t, '{"id":1}\n')
  lu.assertFalse(self.calls[1].no_proxy)
end

function TestStreamableHttpTransport:testCloseRemote()
  local t = { session_id = 'sess-1', url = 'http://example.com/mcp', jobid = nil, server_name = 'srv' }
  streamable.close(t)
  lu.assertNil(t.session_id)
end

function TestStreamableHttpTransport:testCloseLocal()
  local t = { jobid = 1, session_id = 'sess', server_name = 'srv' }
  streamable.close(t)
  lu.assertNil(t.jobid)
  lu.assertNil(t.session_id)
end

return TestStreamableHttpTransport
