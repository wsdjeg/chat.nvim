local lu = require('luaunit')
local http = require('chat.http')
local config = require('chat.config')
local sessions = require('chat.sessions')

local uv = vim.loop

TestHTTPInit = {}

local function find_free_port()
  local srv = uv.new_tcp()
  srv:bind('127.0.0.1', 0)
  local port = srv:getsockname().port
  srv:close()
  return port
end

--- Send a raw HTTP request over a real socket and collect the full response.
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
  vim.wait(5000, function() return res.done end, 10)
  if not client:is_closing() then
    client:close()
  end
  return res
end

function TestHTTPInit:setUp()
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
end

function TestHTTPInit:tearDown()
  http.stop()
end

function TestHTTPInit:testStartAndStop()
  http.start()
  lu.assertNotNil(http._server)
  http.stop()
  lu.assertNil(http._server)
end

function TestHTTPInit:testStartIdempotent()
  http.start()
  lu.assertNotNil(http._server)
  http.start() -- second call should be a no-op
  lu.assertNotNil(http._server)
end

function TestHTTPInit:testRealGetSessions()
  http.start()
  local raw = 'GET /sessions HTTP/1.1\r\nHost: 127.0.0.1\r\nX-API-Key: my-secret-key\r\n\r\n'
  local res = request(config.config.http.port, raw)
  lu.assertNil(res.err)
  lu.assertStrContains(res.data, 'HTTP/1.1 200')
end

function TestHTTPInit:testRealUnauthorized()
  http.start()
  local raw = 'GET /sessions HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n'
  local res = request(config.config.http.port, raw)
  lu.assertStrContains(res.data, 'HTTP/1.1 401')
end

function TestHTTPInit:testRealNotFound()
  http.start()
  local raw = 'GET /no-such-route HTTP/1.1\r\nHost: 127.0.0.1\r\nX-API-Key: my-secret-key\r\n\r\n'
  local res = request(config.config.http.port, raw)
  lu.assertStrContains(res.data, 'HTTP/1.1 404')
end

function TestHTTPInit:testRealSplitRequest()
  -- The server reads in chunks; send the request split into two writes
  http.start()
  local part1 = 'GET /sessions HTT'
  local part2 = 'P/1.1\r\nHost: 127.0.0.1\r\nX-API-Key: my-secret-key\r\n\r\n'

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
    end, 20)
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
  vim.wait(5000, function() return res.done end, 10)
  if not client:is_closing() then
    client:close()
  end
  lu.assertStrContains(res.data, 'HTTP/1.1 200')
end
return TestHTTPInit
