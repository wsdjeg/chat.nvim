--- Unified curl wrapper: availability check, command building, error mapping
-- Replaces 3 duplicate `is_curl_available()` in tools and centralizes error tables
local M = {}

local available = nil

--- Curl exit code -> human readable message
M.ERRORS = {
  [6] = "Couldn't resolve host. Check your network connection.",
  [7] = 'Failed to connect to host. Check if the server is reachable.',
  [22] = 'HTTP request failed with error response (>= 400).',
  [28] = 'Operation timeout. The server took too long to respond.',
  [35] = 'SSL/TLS handshake failure. Check your certificates.',
  [52] = 'Empty reply from server. The server returned no data.',
  [56] = 'Failure with receiving network data. Connection interrupted.',
}

--- Retryable curl exit codes (connection failures, timeouts)
M.RETRYABLE_ERRORS = {
  [6] = true,
  [7] = true,
  [28] = true,
  [35] = true,
  [52] = true,
  [56] = true,
}

--- Check if curl is installed and in PATH
--- @return boolean
function M.is_available()
  if available == nil then
    available = vim.fn.executable('curl') == 1
  end
  return available
end

--- Get error message for a curl exit code
--- @param code integer Curl exit code
--- @return string|nil
function M.get_error_message(code)
  return M.ERRORS[code]
end

--- Check if a curl exit code is retryable
--- @param code integer Curl exit code
--- @return boolean
function M.is_retryable_error(code)
  return M.RETRYABLE_ERRORS[code] == true
end

--- Build a curl command array from options
--- @param opts table Request options
---   url              string   (required) target URL
---   method           string   HTTP method (GET, POST, DELETE, ...)
---   headers          string[] array of "Key: Value" strings
---   body             string   request body (sent via stdin with -d @-)
---   body_inline      boolean  if true, embed body in command (-d body) instead of stdin
---   body_binary      boolean  use --data-binary instead of -d
---   silent           boolean  default true, add -s
---   follow_redirects boolean  add -L
---   max_redirects    integer  add -L --max-redirs N
---   compressed       boolean  add --compressed
---   max_time         integer  add --max-time N
---   insecure         boolean  add -k
---   no_proxy         boolean  add --noproxy *
---   user_agent       string   add -A
---   include_headers  boolean  add -i (include response headers in output)
---   output           string   add -o file
---   write_out        string   add -w format
--- @return table cmd Command array for job.start()
--- @return string|nil body_to_send Body to send via job.send() (nil if no stdin body)
function M.build_request(opts)
  if not M.is_available() then
    error('curl is not installed or not in PATH')
  end

  local cmd = { 'curl' }

  if opts.silent ~= false then
    table.insert(cmd, '-s')
  end

  if opts.include_headers then
    table.insert(cmd, '-i')
  end

  if opts.compressed then
    table.insert(cmd, '--compressed')
  end

  if opts.follow_redirects or opts.max_redirects then
    table.insert(cmd, '-L')
  end

  if opts.max_redirects then
    table.insert(cmd, '--max-redirs')
    table.insert(cmd, tostring(opts.max_redirects))
  end

  if opts.max_time then
    table.insert(cmd, '--max-time')
    table.insert(cmd, tostring(opts.max_time))
  end

  if opts.insecure then
    table.insert(cmd, '-k')
  end

  if opts.no_proxy then
    table.insert(cmd, '--noproxy')
    table.insert(cmd, '*')
  end

  if opts.user_agent then
    table.insert(cmd, '-A')
    table.insert(cmd, opts.user_agent)
  end

  if opts.method then
    table.insert(cmd, '-X')
    table.insert(cmd, opts.method)
  end

  for _, h in ipairs(opts.headers or {}) do
    table.insert(cmd, '-H')
    table.insert(cmd, h)
  end

  if opts.output then
    table.insert(cmd, '-o')
    table.insert(cmd, opts.output)
  end

  if opts.write_out then
    table.insert(cmd, '-w')
    table.insert(cmd, opts.write_out)
  end

  local body_to_send
  if opts.body then
    if opts.body_binary then
      table.insert(cmd, '--data-binary')
    else
      table.insert(cmd, '-d')
    end
    if opts.body_inline then
      table.insert(cmd, opts.body)
    else
      table.insert(cmd, '@-')
      body_to_send = opts.body
    end
  end

  table.insert(cmd, opts.url)

  return cmd, body_to_send
end

return M

