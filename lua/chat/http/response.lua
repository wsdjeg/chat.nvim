--- HTTP response utilities
local M = {}

--- Parse HTTP headers from raw string
function M.parse_headers(raw)
  local headers = {}
  for line in raw:gmatch('([^\r\n]+)') do
    local k, v = line:match('^([^:]+):%s*(.+)$')
    if k then
      headers[k:lower()] = v
    end
  end
  return headers
end

--- URL decode helper
function M.url_decode(str)
  return str:gsub('%%(%x%x)', function(h)
    return string.char(tonumber(h, 16))
  end)
end

--- Send JSON response
function M.send_json(client, status, data)
  local json_data = vim.json.encode(data)
  local resp = string.format(
    'HTTP/1.1 %d OK\r\nContent-Type: application/json\r\nContent-Length: %d\r\n\r\n%s',
    status,
    #json_data,
    json_data
  )
  client:write(resp)
  client:close()
end

--- Send error response
function M.send_error(client, status, message)
  local resp = string.format(
    'HTTP/1.1 %d %s\r\nContent-Type: application/json\r\nContent-Length: %d\r\n\r\n{"error":"%s"}',
    status,
    message,
    #string.format('{"error":"%s"}', message),
    message
  )
  client:write(resp)
  client:close()
end

--- Send simple response
function M.send_response(client, status, message)
  local resp = string.format(
    'HTTP/1.1 %d %s\r\nContent-Length: 0\r\n\r\n',
    status,
    message
  )
  client:write(resp)
  client:close()
end

return M
