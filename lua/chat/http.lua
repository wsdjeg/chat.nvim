local uv = vim.loop

local M = {}

local config = require('chat.config')
local sessions = require('chat.sessions')

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
      if method == 'GET' and path:match('^/session%?') then
        -- GET /session?id=session_id: return HTML preview
        local session_id = path:match('id=([^&]+)')
        if not session_id then
          local resp = 'HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n'
          client:write(resp)
          client:close()
          return
        end

        -- URL decode session_id (simple version)
        session_id = session_id:gsub('%%(%x%x)', function(h)
          return string.char(tonumber(h, 16))
        end)

        local all_sessions = sessions.get()
        local session_data = all_sessions[session_id]

        if not session_data then
          local resp = 'HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n'
          client:write(resp)
          client:close()
          return
        end

        local html = require('chat.preview').generate_html(session_data)
        local resp = string.format(
          'HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: %d\r\n\r\n%s',
          #html,
          html
        )
        client:write(resp)
        client:close()
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

      -- Route handling
      if method == 'GET' and path == '/sessions' then
        -- GET /sessions: return session id list
        local all_sessions = sessions.get()
        local session_ids = {}
        for id, _ in pairs(all_sessions) do
          table.insert(session_ids, id)
        end
        table.sort(session_ids)
        local json_data = vim.json.encode(session_ids)
        local resp = string.format(
          'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %d\r\n\r\n%s',
          #json_data,
          json_data
        )
        client:write(resp)
        client:close()
      elseif method == 'GET' and path:match('^/messages%?') then
        -- GET /messages?session=session_id: return message list
        local session_id = path:match('session=([^&]+)')
        if not session_id then
          local resp = 'HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n'
          client:write(resp)
          client:close()
          return
        end

        -- URL decode session_id
        session_id = session_id:gsub('%%(%x%x)', function(h)
          return string.char(tonumber(h, 16))
        end)

        if not sessions.exists(session_id) then
          local resp = 'HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n'
          client:write(resp)
          client:close()
          return
        end

        local messages = sessions.get_messages(session_id)
        local json_data = vim.json.encode(messages)
        local resp = string.format(
          'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %d\r\n\r\n%s',
          #json_data,
          json_data
        )
        client:write(resp)
        client:close()
      elseif method == 'POST' and path == '/' then
        -- POST /: push message to session (existing behavior)
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
      else
        -- Other routes not found
        local resp = 'HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n'
        client:write(resp)
        client:close()
      end
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
