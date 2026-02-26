local uv = vim.loop

local M = {}

local config = require('chat.config')

local function parse_headers(raw)
  local headers = {}
  for line in raw:gmatch('([^\r\n]+)') do
    local k, v = line:match('^([^:]+):%s*(.+)$')
    if k then
      headers[k:lower()] = v
    end
  end
  return headers
end

function M.start()
  if M._server then
    return
  end
  local host = config.config.http.host
  local port = config.config.http.port

  local server = uv.new_tcp()

  server:bind(host, port)

  server:listen(128, function(err)
    assert(not err, err)

    local client = uv.new_tcp()
    server:accept(client)

    local buffer = ''

    client:read_start(function(err, chunk)
      assert(not err, err)

      if not chunk then
        client:close()
        return
      end

      buffer = buffer .. chunk

      -- header not complete yet
      if not buffer:find('\r\n\r\n', 1, true) then
        return
      end

      local header_part, body = buffer:match('^(.-)\r\n\r\n(.*)$')
      if not header_part then
        return
      end

      local request_line = header_part:match('([^\r\n]+)')
      local method, path = request_line:match('^(%S+)%s+(%S+)')

      local headers = parse_headers(header_part)

      local content_length = tonumber(headers['content-length'] or '0')
      if #body < content_length then
        return
      end

      --------------------------------------------------
      -- API key check (use header: X-API-Key)
      --------------------------------------------------
      if headers['x-api-key'] ~= config.config.http.api_key then
        local resp = 'HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\n\r\n'
        client:write(resp)
        client:close()
        return
      end

      if method ~= 'POST' or path ~= '/' then
        local resp = 'HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n'
        client:write(resp)
        client:close()
        return
      end

      local ok, obj = pcall(vim.json.decode, body:sub(1, content_length))
      if not ok or type(obj) ~= 'table' then
        local resp = 'HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n'
        client:write(resp)
        client:close()
        return
      end

      local session = obj.session
      local content = obj.content

      if type(session) ~= 'string' or type(content) ~= 'string' then
        local resp = 'HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n'
        client:write(resp)
        client:close()
        return
      end

      require('chat.queue').push(session, content)

      local resp = 'HTTP/1.1 204 No Content\r\nContent-Length: 0\r\n\r\n'
      client:write(resp)
      client:close()
    end)
  end)

  M._server = server
end

function M.stop()
  if M._server then
    M._server:close()
    M._server = nil
  end
end

return M
