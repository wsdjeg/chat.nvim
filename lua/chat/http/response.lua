local uv = vim.loop

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

--- Safely close a uv handle, checking is_closing first
local function safe_close(client)
  if client and not client:is_closing() then
    client:close()
  end
end

--- Write data then close client after write completes
--- If write fails (e.g. client already closing), close immediately
local function write_and_close(client, resp)
  if not client or client:is_closing() then
    return
  end
  local ok = pcall(client.write, client, resp, function()
    safe_close(client)
  end)
  if not ok then
    -- write threw an error (client may be closing), close to avoid hang
    safe_close(client)
  end
end

--- Send raw response with given content type
--- @param client table uv tcp handle
--- @param status number HTTP status code
--- @param content_type string Content-Type header value
--- @param data string response body
function M.send_raw(client, status, content_type, data)
  local resp = string.format(
    'HTTP/1.1 %d OK\r\nContent-Type: %s\r\nContent-Length: %d\r\n\r\n%s',
    status,
    content_type,
    #data,
    data
  )
  write_and_close(client, resp)
end

--- Send JSON response
--- @param client table uv tcp handle
--- @param status number HTTP status code
--- @param data table|string response data (table will be JSON-encoded)
function M.send_json(client, status, data)
  local json_data = vim.json.encode(data)
  local resp = string.format(
    'HTTP/1.1 %d OK\r\nContent-Type: application/json\r\nContent-Length: %d\r\n\r\n%s',
    status,
    #json_data,
    json_data
  )
  write_and_close(client, resp)
end

--- Send error response
--- @param client table uv tcp handle
--- @param status number HTTP status code
--- @param message string error message
function M.send_error(client, status, message)
  local body = string.format('{"error":"%s"}', message)
  local resp = string.format(
    'HTTP/1.1 %d %s\r\nContent-Type: application/json\r\nContent-Length: %d\r\n\r\n%s',
    status,
    message,
    #body,
    body
  )
  write_and_close(client, resp)
end

--- Send simple response (no body)
--- @param client table uv tcp handle
--- @param status number HTTP status code
--- @param message string status text
function M.send_response(client, status, message)
  local resp = string.format(
    'HTTP/1.1 %d %s\r\nContent-Length: 0\r\n\r\n',
    status,
    message
  )
  write_and_close(client, resp)
end

return M

