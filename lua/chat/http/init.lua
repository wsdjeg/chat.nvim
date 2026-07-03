local uv = vim.loop

local M = {}

local config = require('chat.config')
local routes = require('chat.http.routes')
local response = require('chat.http.response')

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
    local handled = false

    client:read_start(function(err, chunk)
      if err then
        if not handled and not client:is_closing() then
          client:close()
        end
        return
      end

      if not chunk then
        if not handled and not client:is_closing() then
          client:close()
        end
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

      local headers = response.parse_headers(header_part)

      local content_length = tonumber(headers['content-length'] or '0')
      if #body < content_length then
        return
      end

      -- Mark as handled and stop reading to prevent further callbacks
      handled = true
      client:read_stop()

      -- Use vim.schedule_wrap to handle request in main loop
      -- This allows safe use of vim.fn functions
      vim.schedule_wrap(function()
        local ok, err = pcall(routes.handle_request, client, method, path, headers, body, content_length)
        if not ok then
          -- Route handler threw an error: send 500 to prevent client hang
          response.send_json(client, 500, { error = 'Internal Server Error' })
        end
      end)()
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

