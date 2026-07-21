local uv = vim.loop

local M = {}

local config = require('chat.config')
local routes = require('chat.http.routes')
local response = require('chat.http.response')

-- Connection timeout in milliseconds (120s for idle/incomplete connections)
-- Longer timeout for Termux background where event loop may be throttled
local CONNECTION_TIMEOUT_MS = 120000

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
    local accept_ok, accept_err = server:accept(client)
    if not accept_ok then
      -- accept failed (e.g. too many open files), close client and continue
      client:close()
      return
    end

    -- Disable Nagle's algorithm for lower latency
    pcall(client.nodelay, client, true)

    -- Enable TCP keepalive to prevent Android from silently killing
    -- idle connections in background (delay=10s)
    pcall(client.keepalive, client, true, 10000)

    -- Buffer management: accumulate chunks, track state to avoid
    -- re-concatenating entire buffer on every read callback
    local chunks = {}
    local total_len = 0
    local header_parsed = false
    local content_length = 0
    local header_end_pos = 0 -- position after \r\n\r\n
    local saved_method, saved_path, saved_headers
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

    local function close_client()
      cleanup()
      if not client:is_closing() then
        client:close()
      end
    end

    timer:start(CONNECTION_TIMEOUT_MS, 0, function()
      if not handled then
        close_client()
      end
    end)

    client:read_start(function(read_err, chunk)
      if read_err or not chunk then
        if not handled then
          close_client()
        end
        return
      end

      table.insert(chunks, chunk)
      total_len = total_len + #chunk

      if not header_parsed then
        -- Need to find \r\n\r\n, concat to search
        local buffer = table.concat(chunks)
        local sep_pos = buffer:find('\r\n\r\n', 1, true)

        if not sep_pos then
          return -- headers not complete yet
        end

        local header_part = buffer:sub(1, sep_pos - 1)
        header_end_pos = sep_pos + 4
        header_parsed = true

        local request_line = header_part:match('([^\r\n]+)')
        if not request_line then
          close_client()
          return
        end

        saved_method, saved_path = request_line:match('^(%S+)%s+(%S+)')
        saved_headers = response.parse_headers(header_part)
        content_length = tonumber(saved_headers['content-length'] or '0')

        local body = buffer:sub(header_end_pos)

        if #body < content_length then
          return -- body not complete yet
        end

        -- Full request received
        handled = true
        client:read_stop()
        cleanup()

        vim.schedule_wrap(function()
          local ok, route_err = pcall(
            routes.handle_request,
            client, saved_method, saved_path, saved_headers, body, content_length
          )
          if not ok then
            if not client:is_closing() then
              response.send_json(client, 500, { error = 'Internal Server Error' })
            end
          end
        end)()
      else
        -- Headers already parsed, check if body is complete
        -- body_len = total_len - (header_end_pos - 1)
        -- header_end_pos is relative to the full concatenated buffer
        -- so we need to concat to get actual body
        local buffer = table.concat(chunks)
        local body = buffer:sub(header_end_pos)

        if #body >= content_length then
          handled = true
          client:read_stop()
          cleanup()

          vim.schedule_wrap(function()
            local ok, route_err = pcall(
              routes.handle_request,
              client, saved_method, saved_path, saved_headers, body, content_length
            )
            if not ok then
              if not client:is_closing() then
                response.send_json(client, 500, { error = 'Internal Server Error' })
              end
            end
          end)()
        end
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

