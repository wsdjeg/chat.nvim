local uv = vim.loop

local M = {}

local config = require('chat.config')
local routes = require('chat.http.routes')
local response = require('chat.http.response')

-- Connection timeout in milliseconds (30s for idle/incomplete connections)
local CONNECTION_TIMEOUT_MS = 30000

function M.start()
  if M._server then
    return
  end
  local host = config.config.http.host
  local port = config.config.http.port

  local server = uv.new_tcp()

  local ok, err = server:bind(host, port)
  if not ok then
    server:close()
    error('Failed to bind ' .. host .. ':' .. port .. ' - ' .. (err or 'unknown error'))
  end

  server:listen(128, function(listen_err)
    if listen_err then
      vim.schedule(function()
        vim.notify('HTTP server listen error: ' .. listen_err, vim.log.levels.ERROR)
      end)
      return
    end

    local client = uv.new_tcp()
    server:accept(client)

    -- Use table-based buffer for O(1) append instead of O(n) string concat
    local chunks = {}
    local handled = false

    -- Connection timeout timer: closes connection if request is not
    -- fully received and handled within CONNECTION_TIMEOUT_MS
    local timer = uv.new_timer()
    local function cleanup()
      if timer and not timer:is_closing() then
        timer:stop()
        timer:close()
      end
    end
    timer:start(CONNECTION_TIMEOUT_MS, 0, function()
      cleanup()
      if not handled and not client:is_closing() then
        client:close()
      end
    end)

    client:read_start(function(read_err, chunk)
      if read_err then
        cleanup()
        if not handled and not client:is_closing() then
          client:close()
        end
        return
      end

      if not chunk then
        cleanup()
        if not handled and not client:is_closing() then
          client:close()
        end
        return
      end

      table.insert(chunks, chunk)
      local buffer = table.concat(chunks)

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
      cleanup()

      -- Use vim.schedule_wrap to handle request in main loop
      -- This allows safe use of vim.fn functions
      vim.schedule_wrap(function()
        local ok, route_err = pcall(routes.handle_request, client, method, path, headers, body, content_length)
        if not ok then
          -- Route handler threw an error: send 500 to prevent client hang
          if not client:is_closing() then
            response.send_json(client, 500, { error = 'Internal Server Error' })
          end
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

