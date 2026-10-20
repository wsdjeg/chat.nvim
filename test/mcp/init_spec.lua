local lu = require('luaunit')
local mcp = require('chat.mcp')
local transport = require('chat.mcp.transport')
local config = require('chat.config')

TestMcpInit = {}

--- Install a mock transport under the given name and create a server through
--- the official connect_server flow, driving initialize + tools/list to
--- completion. Returns the created transport handle.
local function mock_transport(name, tools, opts)
  opts = opts or {}
  local created = {}
  transport.register(name, {
    create = function(sname, cfg, cb)
      if opts.fail_create then
        return nil, 'create boom'
      end
      local t = {
        type = name, name = sname, config = cfg, on_message = cb,
        sent = {}, closed = false,
      }
      created[1] = t
      return t, nil
    end,
    send = function(t, msg) table.insert(t.sent, msg) end,
    close = function(t) t.closed = true end,
  })
  return created
end

local function connect_with_tools(server_name, tools, cfg)
  local created = mock_transport('stdio', tools)
  mcp.connect_server(server_name, cfg or { command = 'echo' })
  local t = created[1]
  if not t then
    return nil
  end
  -- respond to initialize
  local init = vim.json.decode(t.sent[1])
  t.on_message({ id = init.id, result = { serverInfo = { name = 'tsrv', version = '1' } } })
  -- flush defer_fn (tools/list after 1000ms)
  vim.wait(2000, function() return #t.sent >= 3 end, 10)
  local last = vim.json.decode(t.sent[#t.sent])
  if last.method == 'tools/list' and tools then
    t.on_message({ id = last.id, result = { tools = tools } })
  end
  return t
end

function TestMcpInit:setUp()
  config.setup({
    storage_dir = vim.fn.tempname(),
    allowed_path = vim.fs.normalize(vim.fn.getcwd()),
  })
end

function TestMcpInit:tearDown()
  mcp.stop()
end

function TestMcpInit:testSetupRegistersTransports()
  mcp.setup()
  lu.assertTrue(transport.exists('stdio'))
  lu.assertTrue(transport.exists('streamable_http'))
end

function TestMcpInit:testIsMcpTool()
  lu.assertTrue(mcp.is_mcp_tool('mcp_srv_tool'))
  lu.assertTrue(mcp.is_mcp_tool('mcp_open_webSearch_search'))
  lu.assertFalse(mcp.is_mcp_tool('plain_tool'))
  lu.assertFalse(mcp.is_mcp_tool('mcp_srv'))
end

function TestMcpInit:testToolInfoInvalidName()
  lu.assertEquals('unknown_tool', mcp.tool_info('unknown_tool', '{}'))
end

function TestMcpInit:testConnectServerUnknownTransport()
  mcp.connect_server('srv', { url = 'http://x' })
  -- url -> streamable_http; not registered => error branch (no crash)
end

function TestMcpInit:testConnectServerNoType()
  mcp.connect_server('srv', {})
  -- no command/url -> unknown transport (no crash)
end

function TestMcpInit:testConnectAndRegisterTools()
  local tools = {
    { name = 'search', description = 'Search', inputSchema = { type = 'object', properties = { q = { type = 'string' } } } },
    { name = 'fetch', description = 'Fetch', inputSchema = {} },
  }
  local t = connect_with_tools('srv', tools)
  lu.assertNotNil(t)
  lu.assertNotNil(t.sent[1])
  lu.assertStrContains(t.sent[1], 'initialize')
end

function TestMcpInit:testAvailableTools()
  local tools = {
    { name = 'search', description = 'Search the web', inputSchema = { type = 'object', properties = {} } },
  }
  connect_with_tools('srv', tools)
  local avail = mcp.available_tools()
  lu.assertTrue(#avail >= 1)
  local names = {}
  for _, t in ipairs(avail) do
    names[t['function'].name] = true
  end
  lu.assertTrue(names['mcp_srv_search'])
end

function TestMcpInit:testToolInfoWithArgs()
  local tools = { { name = 'search', description = 'd', inputSchema = {} } }
  connect_with_tools('srv', tools)
  local info = mcp.tool_info('mcp_srv_search', '{"q":"hello","n":5}')
  lu.assertStrContains(info, 'mcp_srv_search')
  lu.assertStrContains(info, 'q="hello"')
  lu.assertStrContains(info, 'n=5')
end

function TestMcpInit:testSendRequestNotFound()
  local id, err = mcp.send_request('nope', 'x', {}, function() end)
  lu.assertNil(id)
  lu.assertStrContains(err, 'not found')
end

function TestMcpInit:testSendRequestAndHandleResponse()
  local created = mock_transport('stdio')
  mcp.connect_server('srv', { command = 'echo' })
  local t = created[1]
  -- consume the auto initialize request by responding to it
  local init = vim.json.decode(t.sent[1])
  t.on_message({ id = init.id, result = {} })

  local got = nil
  local id = mcp.send_request('srv', 'ping', {}, function(res) got = res end)
  lu.assertNotNil(id)

  t.on_message({ id = id, result = { pong = true } })
  lu.assertEquals(true, got.pong)
end

function TestMcpInit:testHandleMessageNotification()
  local created = mock_transport('stdio')
  mcp.connect_server('srv', { command = 'echo' })
  local t = created[1]
  t.on_message({ method = 'some/notification' })
end

function TestMcpInit:testHandleMessageError()
  local created = mock_transport('stdio')
  mcp.connect_server('srv', { command = 'echo' })
  local t = created[1]
  local id = mcp.send_request('srv', 'boom', {}, function() end)
  t.on_message({ id = id, error = { message = 'boom happened' } })
end

function TestMcpInit:testHandleMessageCancelledRequest()
  mcp.handle_message('srv', { id = 999, result = {} })
end

function TestMcpInit:testSendNotificationNotFound()
  mcp.send_notification('nope', 'x', {})
end

function TestMcpInit:testCallToolInvalidName()
  local r = mcp.call_tool('not_an_mcp_tool', {}, { callback = function() end })
  lu.assertNotNil(r.error)
end

function TestMcpInit:testCallToolAndCancel()
  local tools = { { name = 'search', description = 'd', inputSchema = {} } }
  local t = connect_with_tools('srv', tools)

  local results = {}
  local res = mcp.call_tool('mcp_srv_search', { q = 'hi' }, {
    callback = function(r) table.insert(results, r) end,
  })
  lu.assertNotNil(res.mcp_tool_call_id)
  lu.assertTrue(res.mcp_tool_call_id < 0)

  -- respond to tools/call
  local sent = t.sent[#t.sent]
  local req = vim.json.decode(sent)
  local call_id = req.id
  t.on_message({
    id = call_id,
    result = { content = { { type = 'text', text = 'hello result' } } },
  })
  lu.assertEquals(1, #results)
  lu.assertEquals('hello result', results[1].content)
end

function TestMcpInit:testCallToolError()
  local tools = { { name = 'search', description = 'd', inputSchema = {} } }
  local t = connect_with_tools('srv', tools)

  local results = {}
  local res = mcp.call_tool('mcp_srv_search', {}, {
    callback = function(r) table.insert(results, r) end,
  })
  local req = vim.json.decode(t.sent[#t.sent])
  t.on_message({
    id = req.id,
    result = { isError = true, content = { { type = 'text', text = 'tool broke' } } },
  })
  lu.assertEquals('tool broke', results[1].error)
end

function TestMcpInit:testCancelRequest()
  local tools = { { name = 'search', description = 'd', inputSchema = {} } }
  local t = connect_with_tools('srv', tools)

  local results = {}
  local res = mcp.call_tool('mcp_srv_search', {}, {
    callback = function(r) table.insert(results, r) end,
  })
  local cancelled = mcp.cancel_request(res.mcp_tool_call_id)
  lu.assertTrue(cancelled)
  lu.assertEquals('Request cancelled by user', results[1].error)
end

function TestMcpInit:testCancelRequestUnknown()
  lu.assertFalse(mcp.cancel_request(-123456))
end

function TestMcpInit:testRemoveServer()
  local created = mock_transport('stdio')
  mcp.connect_server('srv', { command = 'echo' })
  mcp.remove_server('srv')
end

function TestMcpInit:testConnectFromConfig()
  config.setup({
    storage_dir = vim.fn.tempname(),
    mcp = { srvcfg = { command = 'echo' } },
  })
  local created = mock_transport('stdio')
  mcp.connect()
  lu.assertNotNil(created[1])
end

function TestMcpInit:testConnectDisabledServer()
  config.setup({
    storage_dir = vim.fn.tempname(),
    mcp = { srvdisabled = { command = 'echo', disabled = true } },
  })
  mcp.connect()
end

function TestMcpInit:testCreateTransportFailure()
  local created = mock_transport('stdio', nil, { fail_create = true })
  mcp.connect_server('srv', { command = 'echo' })
  lu.assertNil(created[1])
end

return TestMcpInit
