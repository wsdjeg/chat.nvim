local uv = vim.loop

local M = {}

local config = require('chat.config')
local routes = require('chat.http.routes')

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

      local headers = routes.parse_headers(header_part)

      local content_length = tonumber(headers['content-length'] or '0')
      if #body < content_length then
        return
      end

      -- Use vim.schedule_wrap to handle request in main loop
      -- This allows safe use of vim.fn functions
      vim.schedule_wrap(routes.handle_request)(client, method, path, headers, body, content_length)
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
