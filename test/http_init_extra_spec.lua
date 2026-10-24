-- Coverage for chat/http/init.lua request lifecycle over real sockets:
-- bind failure, client disconnects before a request completes, POST body
-- streamed in a single write and split across writes (header-parsed branch
-- with incremental body), and route handler panics surfacing as HTTP 500.

local lu = require('luaunit')
local http = require('chat.http')
local config = require('chat.config')
local sessions = require('chat.sessions')
local routes = require('chat.http.routes')

local uv = vim.loop

TestHTTPInitExtra = {}

local function find_free_port()
  local srv = uv.new_tcp()
  srv:bind('127.0.0.1', 0)
  local port = srv:getsockname().port
  srv:close()
  return port
end

--- Send a raw HTTP request over a real socket and collect the response.
local function request(port, raw)
  local res = { done = false, data = '', err = nil }
  local client = uv.new_tcp()
  client:connect('127.0.0.1', port, function(err)
    if err then
      res.err = err
      res.done = true
      return
    end
    client:write(raw, function() end)
    client:read_start(function(rerr, chunk)
      if chunk then
        res.data = res.data .. chunk
      end
      if rerr or not chunk then
        res.err = rerr
        res.done = true
      end
    end)
  end)
  vim.wait(5000, function()
    return res.done
  end, 10)
  if not client:is_closing() then
    client:close()
  end
  return res
end

function TestHTTPInitExtra:setUp()
  config.setup({
    storage_dir = vim.fn.tempname(),
    allowed_path = vim.fs.normalize(vim.fn.getcwd()),
    http = {
      enabled = true,
      host = '127.0.0.1',
      port = find_free_port(),
      api_key = 'my-secret-key',
    },
  })
  sessions.set_cache_dir(vim.fn.tempname() .. '/')
  self.handle_request_orig = routes.handle_request
end

function TestHTTPInitExtra:tearDown()
  routes.handle_request = self.handle_request_orig
  http.stop()
end

function TestHTTPInitExtra:testBindFailureRaises()
  -- an unresolvable bind address makes uv bind raise
  local host_orig = config.config.http.host
  config.config.http.host = '999.999.999.999'
  local ok, err = pcall(http.start)
  config.config.http.host = host_orig
  http.stop()
  lu.assertFalse(ok)
  lu.assertStrContains(tostring(err), 'Invalid IP')
end

function TestHTTPInitExtra:testClientDisconnectBeforeRequest()
  http.start()
  -- connect and drop the connection without sending anything
  local client = uv.new_tcp()
  client:connect('127.0.0.1', config.config.http.port, function()
    client:close()
  end)
  vim.wait(300, function()
    return false
  end, 10)
  -- the server must survive: a follow-up request still works
  local raw = 'GET /sessions HTTP/1.1\r\nHost: x\r\nX-API-Key: my-secret-key\r\n\r\n'
  local res = request(config.config.http.port, raw)
  lu.assertStrContains(res.data, 'HTTP/1.1 200')
end

function TestHTTPInitExtra:testRealPostBodySingleWrite()
  http.start()
  local body = vim.json.encode({ provider = 'openai', model = 'gpt-x' })
  local raw = table.concat({
    'POST /session/new HTTP/1.1\r\n',
    'Host: 127.0.0.1\r\n',
    'X-API-Key: my-secret-key\r\n',
    'Content-Type: application/json\r\n',
    'Content-Length: ' .. #body .. '\r\n\r\n',
    body,
  })
  local res = request(config.config.http.port, raw)
  lu.assertStrContains(res.data, 'HTTP/1.1 2')
  -- the created session is listed afterwards
  local list = request(
    config.config.http.port,
    'GET /sessions HTTP/1.1\r\nHost: x\r\nX-API-Key: my-secret-key\r\n\r\n'
  )
  lu.assertStrContains(list.data, 'HTTP/1.1 200')
end

function TestHTTPInitExtra:testRealPostBodySplitAcrossWrites()
  http.start()
  local body = vim.json.encode({ provider = 'openai', model = 'split-body' })
  local part1 = table.concat({
    'POST /session/new HTTP/1.1\r\n',
    'Host: 127.0.0.1\r\n',
    'X-API-Key: my-secret-key\r\n',
    'Content-Type: application/json\r\n',
    'Content-Length: ' .. #body .. '\r\n\r\n',
    body:sub(1, 5),
  })
  local part2 = body:sub(6)

  local res = { done = false, data = '', err = nil }
  local client = uv.new_tcp()
  client:connect('127.0.0.1', config.config.http.port, function(err)
    if err then
      res.err = err
      res.done = true
      return
    end
    client:write(part1, function() end)
    vim.defer_fn(function()
      client:write(part2, function() end)
    end, 30)
    client:read_start(function(rerr, chunk)
      if chunk then
        res.data = res.data .. chunk
      end
      if rerr or not chunk then
        res.err = rerr
        res.done = true
      end
    end)
  end)
  vim.wait(5000, function()
    return res.done
  end, 10)
  if not client:is_closing() then
    client:close()
  end
  lu.assertStrContains(res.data, 'HTTP/1.1 2')
end

function TestHTTPInitExtra:testRouteHandlerPanicReturns500()
  routes.handle_request = function()
    error('route blew up')
  end
  http.start()
  local raw = 'GET /sessions HTTP/1.1\r\nHost: x\r\nX-API-Key: my-secret-key\r\n\r\n'
  local res = request(config.config.http.port, raw)
  lu.assertStrContains(res.data, 'HTTP/1.1 500')
end

return TestHTTPInitExtra

