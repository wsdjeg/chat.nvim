-- lua/chat/tools/fetch_web.lua
local M = {}

local job = require('job')
local util = require('chat.util')
local config = require('chat.config')

-- Cache curl availability check
local curl_available = nil
local function is_curl_available()
  if curl_available == nil then
    curl_available = vim.fn.executable('curl') == 1
  end
  return curl_available
end

---@class ChatToolsFetchWebAction
---@field url string
---@field timeout? integer
---@field user_agent? string
---@field headers? string[]
---@field method? string
---@field data? string
---@field max_redirects? integer
---@field insecure? boolean
---@field output? string

---@param action ChatToolsFetchWebAction
---@param ctx ChatToolContext
function M.fetch_web(action, ctx)
  -- Parameter validation
  if not action.url or type(action.url) ~= 'string' then
    return {
      error = 'URL is required and must be a non-empty string.',
    }
  end

  -- Security: only allow HTTP/HTTPS URLs
  if not (action.url:match('^https?://')) then
    return {
      error = 'Only HTTP/HTTPS URLs are allowed. URL must start with http:// or https://',
    }
  end

  -- Check if curl is available
  if not is_curl_available() then
    return {
      error = 'curl is not installed or not in PATH. Please install curl first.',
    }
  end

  -- Build curl command
  local cmd = { 'curl' }

  -- Basic options
  table.insert(cmd, '-s') -- Silent mode
  table.insert(cmd, '-L') -- Follow redirects
  table.insert(cmd, '--compressed') -- Request compressed response

  -- Timeout (validate range: 1-300)
  local timeout = action.timeout or 30
  if type(timeout) ~= 'number' or timeout < 1 or timeout > 300 then
    return {
      error = 'Timeout must be between 1 and 300 seconds.',
    }
  end
  table.insert(cmd, '--max-time')
  table.insert(cmd, tostring(timeout))

  -- User agent
  local user_agent = action.user_agent
    or 'Mozilla/5.0 (compatible; chat.nvim)'
  table.insert(cmd, '--user-agent')
  table.insert(cmd, user_agent)

  -- Max redirects (validate range: 0-20)
  local max_redirects = action.max_redirects or 5
  if type(max_redirects) ~= 'number' or max_redirects < 0 or max_redirects > 20 then
    return {
      error = 'Max redirects must be between 0 and 20.',
    }
  end
  table.insert(cmd, '--max-redirs')
  table.insert(cmd, tostring(max_redirects))

  -- SSL verification
  if action.insecure then
    table.insert(cmd, '--insecure')
  end

  -- Custom headers
  if action.headers and type(action.headers) == 'table' then
    for _, header in ipairs(action.headers) do
      if type(header) == 'string' and header ~= '' then
        table.insert(cmd, '-H')
        table.insert(cmd, header)
      end
    end
  end

  -- HTTP method (validate allowed methods)
  local allowed_methods = { GET = true, POST = true, PUT = true, DELETE = true, PATCH = true, HEAD = true }
  local method = (action.method or 'GET'):upper()
  if not allowed_methods[method] then
    return {
      error = string.format('Invalid HTTP method: %s. Allowed methods: GET, POST, PUT, DELETE, PATCH, HEAD', method),
    }
  end
  if method ~= 'GET' then
    table.insert(cmd, '-X')
    table.insert(cmd, method)
  end

  -- POST data
  if action.data and type(action.data) == 'string' then
    table.insert(cmd, '--data')
    table.insert(cmd, action.data)
  end

  -- Add URL at the end
  table.insert(cmd, action.url)

  -- Output file path validation
  local output_path = nil
  if action.output then
    output_path = util.resolve(action.output, ctx.cwd)

    local is_allowed_path = false

    if type(config.config.allowed_path) == 'table' then
      for _, v in ipairs(config.config.allowed_path) do
        if type(v) == 'string' and #v > 0 then
          if vim.startswith(output_path, vim.fs.normalize(v)) then
            is_allowed_path = true
            break
          end
        end
      end
    elseif
      type(config.config.allowed_path) == 'string'
      and #config.config.allowed_path > 0
    then
      is_allowed_path =
        vim.startswith(output_path, vim.fs.normalize(config.config.allowed_path))
    end

    if not is_allowed_path then
      return {
        error = 'output file path is not allowed path',
      }
    else
      table.insert(cmd, '-o')
      table.insert(cmd, output_path)
    end
  end

  local stdout = {}
  local stderr = {}

  local jobid = job.start(cmd, {
    on_stdout = function(_, data)
      for _, v in ipairs(data) do
        table.insert(stdout, v)
      end
    end,
    on_stderr = function(_, data)
      for _, v in ipairs(data) do
        table.insert(stderr, v)
      end
    end,
    on_exit = function(id, code, signal)
      require('chat.log').debug(
        'fetch_web job '
          .. id
          .. ' exit code '
          .. code
          .. ' signal '
          .. signal
      )
      if signal ~= 0 then
        ctx.callback({
          error = string.format(
            'fetch_web cancelled by user (signal: %d)',
            signal
          ),
          jobid = id,
        })
        return
      end

      if code == 0 then
        if output_path then
          -- Output mode: check if file was saved successfully
          local stat = vim.uv.fs_stat(output_path)
          if stat then
            ctx.callback({
              content = string.format(
                'Successfully fetched content from: %s\n'
                  .. 'Method: %s\n'
                  .. 'Timeout: %d seconds\n'
                  .. 'Output file: %s\n'
                  .. 'File size: %d bytes\n',
                action.url,
                method,
                timeout,
                output_path,
                stat.size
              ),
              jobid = id,
            })
          else
            ctx.callback({
              error = string.format(
                'curl exited successfully but output file was not created: %s',
                output_path
              ),
              jobid = id,
            })
          end
        else
          -- Display mode: show content
          local result = table.concat(stdout, '\n')
          -- Try to detect content type
          local content_type = 'text/plain'
          if result:match('<!DOCTYPE') or result:match('<html') then
            content_type = 'text/html'
          elseif result:match('^{') or result:match('^%[') then
            content_type = 'application/json'
          end

          local summary = string.format(
            'Successfully fetched content from: %s\n'
              .. 'Method: %s\n'
              .. 'Timeout: %d seconds\n'
              .. 'Content-Type: %s\n'
              .. 'Content-Length: %d characters\n\n',
            action.url,
            method,
            timeout,
            content_type,
            #result
          )

          -- Truncate very large responses
          local max_content_length = 10000
          local display_result = result
          local truncation_note = ''

          if #result > max_content_length then
            display_result = result:sub(1, max_content_length)
            truncation_note = string.format(
              '\n\n[Content truncated from %d to %d characters. Use output parameter to save to file for full content.]',
              #result,
              max_content_length
            )
          end

          ctx.callback({
            content = summary .. display_result .. truncation_note,
            jobid = id,
          })
        end
      else
        -- Error handling
        local result = table.concat(stdout, '\n')
        if result ~= '' then
          result = result .. '\n\n' .. table.concat(stderr, '\n')
        else
          result = table.concat(stderr, '\n')
        end
        local error_msg = string.format(
          'Failed to fetch URL (exit code: %d): %s\n\n'
            .. 'Command: %s\n\n'
            .. 'Error output: %s',
          code,
          action.url,
          table.concat(cmd, ' '),
          result
        )

        -- Provide troubleshooting tips
        if code == 6 then
          error_msg = error_msg
            .. '\n\nTroubleshooting: Could not resolve host. Check URL and network connection.'
        elseif code == 7 then
          error_msg = error_msg
            .. '\n\nTroubleshooting: Failed to connect to host. Check if the server is accessible.'
        elseif code == 28 then
          error_msg = error_msg
            .. '\n\nTroubleshooting: Operation timeout. Try increasing timeout value.'
        elseif code == 60 then
          error_msg = error_msg
            .. '\n\nTroubleshooting: SSL certificate problem. Try using insecure=true for testing.'
        end

        ctx.callback({
          error = error_msg,
          jobid = id,
        })
      end
    end,
  })
  return {
    jobid = jobid,
  }
end

function M.scheme()
  return {
    type = 'function',
    ['function'] = {
      name = 'fetch_web',
      description = [[
         Fetch content from web URLs using curl with comprehensive HTTP support.
         
         This tool retrieves content from HTTP/HTTPS URLs with configurable options
         for timeouts, headers, HTTP methods, and SSL verification.
         
         DEPENDENCIES:
         - Requires curl to be installed and available in PATH
         - Uses vim.system() on Neovim 0.10+, falls back to vim.fn.system()
         
         EXAMPLES:
         
         1. Basic URL fetch:
            @fetch_web url="https://example.com"
         
         2. With custom timeout and user agent:
            @fetch_web url="https://api.github.com/repos/neovim/neovim" timeout=60 user_agent="MyApp/1.0"
         
         3. With custom headers (API authentication):
            @fetch_web url="https://api.github.com/user" headers=["Authorization: Bearer token123"]
         
         4. POST request with JSON data:
            @fetch_web url="https://api.example.com/data" method="POST" data='{"key":"value"}' headers=["Content-Type: application/json"]
         
         5. Disable SSL verification for testing:
            @fetch_web url="https://self-signed.example.com" insecure=true
         
         6. Limit redirects:
            @fetch_web url="https://example.com/redirect" max_redirects=2
         
         SECURITY NOTES:
         - Only HTTP/HTTPS URLs are allowed (no file://, ftp://, etc.)
         - SSL verification is enabled by default
         - Timeout defaults to 30 seconds to prevent hanging
         - User agent identifies as chat.nvim by default
         
         PERFORMANCE NOTES:
         - Responses are limited to 10,000 characters for display
         - For large responses, consider using output parameter to save to file
         - Compression is automatically requested (--compressed)
         
         TROUBLESHOOTING:
         - If curl is not installed, you'll get an error
         - For SSL issues, try insecure=true (for testing only)
         - For timeout issues, increase timeout value
         - Check network connectivity if host cannot be resolved
         
         VERSION COMPATIBILITY:
         - Uses vim.system() on Neovim 0.10+ for better control
         - Falls back to vim.fn.system() on older versions
         ]],
      parameters = {
        type = 'object',
        properties = {
          url = {
            type = 'string',
            description = 'URL to fetch (must start with http:// or https://)',
          },
          timeout = {
            type = 'integer',
            description = 'Timeout in seconds (default: 30, minimum: 1, maximum: 300)',
            minimum = 1,
            maximum = 300,
          },
          user_agent = {
            type = 'string',
            description = 'Custom User-Agent header string (default: "Mozilla/5.0 (compatible; chat.nvim)")',
          },
          headers = {
            type = 'array',
            description = 'Additional HTTP headers as strings (e.g., ["Authorization: Bearer token", "Accept: application/json"])',
            items = { type = 'string' },
          },
          method = {
            type = 'string',
            description = 'HTTP method (default: "GET", options: GET, POST, PUT, DELETE, PATCH, HEAD)',
            enum = { 'GET', 'POST', 'PUT', 'DELETE', 'PATCH', 'HEAD' },
          },
          data = {
            type = 'string',
            description = 'Request body data for POST/PUT requests',
          },
          max_redirects = {
            type = 'integer',
            description = 'Maximum number of redirects to follow (default: 5, set to 0 to disable)',
            minimum = 0,
            maximum = 20,
          },
          insecure = {
            type = 'boolean',
            description = 'Disable SSL certificate verification (use with caution, for testing only)',
          },
          output = {
            type = 'string',
            description = 'Save response to file instead of displaying (e.g., "./response.html")',
          },
        },
        required = { 'url' },
      },
    },
  }
end

function M.info(action, ctx)
  local ok, arguments = pcall(vim.json.decode, action)
  if ok then
    local info_parts = {
      string.format('fetch_web "%s"', arguments.url),
    }

    if arguments.method and arguments.method ~= 'GET' then
      table.insert(info_parts, string.format('method=%s', arguments.method))
    end

    if arguments.timeout then
      table.insert(info_parts, string.format('timeout=%d', arguments.timeout))
    end

    if arguments.output then
      table.insert(info_parts, string.format('output=%s', arguments.output))
    end

    return table.concat(info_parts, ' ')
  else
    return 'fetch_web'
  end
end

return M
