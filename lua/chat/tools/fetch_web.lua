-- lua/chat/tools/fetch_web.lua
local M = {}

local job = require('job')
local util = require('chat.util')
local config = require('chat.config')
local curl = require('chat.curl')

---@class ChatToolsFetchWebAction
---@field url string
---@field timeout? integer
---@field user_agent? string
---@field headers? string[]
---@field method? string
---@field data? string
---@field max_redirects? integer
---@field max_length? integer
---@field insecure? boolean
---@field markdown? boolean
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
  if not curl.is_available() then
    return {
      error = 'curl is not installed or not in PATH. Please install curl first.',
    }
  end

  -- Timeout (validate range: 1-300)
  -- Models sometimes send numbers as JSON strings, so coerce defensively.
  local timeout = action.timeout or 30
  if type(timeout) == 'string' then
    timeout = tonumber(timeout)
  end
  if type(timeout) ~= 'number' or timeout < 1 or timeout > 300 then
    return {
      error = 'Timeout must be between 1 and 300 seconds.',
    }
  end

  -- Max redirects (validate range: 0-20)
  local max_redirects = action.max_redirects or 5
  if type(max_redirects) == 'string' then
    max_redirects = tonumber(max_redirects)
  end
  if type(max_redirects) ~= 'number' or max_redirects < 0 or max_redirects > 20 then
    return {
      error = 'Max redirects must be between 0 and 20.',
    }
  end

  -- Max display length (0 or negative disables truncation; default 10000)
  -- Same defensive coercion: without it a string like "10000" crashes the
  -- on_exit comparison (`attempt to compare number with string`).
  local max_length = action.max_length
  if max_length == nil then
    max_length = 10000
  end
  if type(max_length) == 'string' then
    max_length = tonumber(max_length)
  end
  if type(max_length) ~= 'number' then
    return {
      error = 'max_length must be an integer (set 0 or negative to disable truncation).',
    }
  end

  -- Markdown conversion flag (defensive: some models send "true" as string)
  local to_markdown = action.markdown == true or action.markdown == 'true'

  -- User agent
  local user_agent = action.user_agent
    or 'Mozilla/5.0 (compatible; chat.nvim)'

  -- Normalize headers (defensive: handle string->array)
  local headers_list = {}
  if action.headers then
    if type(action.headers) == 'string' then
      action.headers = { action.headers }
    end
    if type(action.headers) == 'table' then
      for _, header in ipairs(action.headers) do
        if type(header) == 'string' and header ~= '' then
          table.insert(headers_list, header)
        end
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

  -- Output file path validation
  local output_path = nil
  if action.output then
    output_path = util.resolve(action.output, ctx.cwd)

    if not util.is_allowed_path(output_path) then
      return {
        error = 'output file path is not allowed path',
      }
    end
  end

  -- html2markdown CLI availability check.
  -- Only needed in display mode: with the output parameter the raw
  -- response is saved to a file and markdown conversion is ignored.
  if to_markdown and not output_path and vim.fn.executable('html2markdown') ~= 1 then
    return {
      error = 'markdown=true requires the html2markdown CLI to be installed and in PATH. '
        .. 'Install: https://github.com/JohannesKaufmann/html-to-markdown '
        .. '(brew install JohannesKaufmann/tap/html2markdown, '
        .. 'or go install github.com/JohannesKaufmann/html-to-markdown/v2/cli/html2markdown@latest). '
        .. 'Or omit the markdown parameter to return raw HTML.',
    }
  end

  -- Build curl command via unified module
  local cmd = curl.build_request({
    url = action.url,
    method = method ~= 'GET' and method or nil,
    headers = headers_list,
    body = action.data,
    follow_redirects = true,
    max_redirects = max_redirects,
    compressed = true,
    max_time = timeout,
    insecure = action.insecure,
    user_agent = user_agent,
    output = output_path,
  })

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
          -- Sanitize to ensure valid UTF-8 (prevents NonUTF8Body API errors)
          local had_invalid
          result, had_invalid = util.sanitize_utf8(result)
          -- Try to detect content type
          local content_type = 'text/plain'
          if result:match('<!DOCTYPE') or result:match('<html') then
            content_type = 'text/html'
          elseif result:match('^{') or result:match('^%[') then
            content_type = 'application/json'
          end

          -- Build summary + truncation and emit the final tool result.
          -- Shared by the raw response and the html2markdown output.
          local function emit_content(raw, ct, note)
            local summary = string.format(
              'Successfully fetched content from: %s\n'
                .. 'Method: %s\n'
                .. 'Timeout: %d seconds\n'
                .. 'Content-Type: %s\n'
                .. 'Content-Length: %d characters\n\n',
              action.url,
              method,
              timeout,
              ct,
              #raw
            )

            if had_invalid then
              summary = summary
                .. '[Warning: Non-UTF-8 bytes detected and replaced with U+FFFD. '
                .. 'The original content may use a different encoding (e.g., GBK, Big5).]\n\n'
            end

            -- Truncate very large responses
            -- max_length: 0 or negative means no truncation (normalized
            -- to a number during validation above)
            local display_result = raw
            local truncation_note = ''
            if max_length > 0 and #raw > max_length then
              display_result = util.utf8_truncate(raw, max_length)
              truncation_note = string.format(
                '\n\n[Content truncated from %d to %d characters. Use output parameter to save to file for full content.]',
                #raw,
                max_length
              )
            end

            ctx.callback({
              content = summary .. (note or '') .. display_result .. truncation_note,
              jobid = id,
            })
          end

          -- markdown=true: pipe the HTML through the html2markdown CLI
          -- so the result returned to the LLM is clean Markdown instead
          -- of raw HTML. The HTML is fed via stdin; the final tool result
          -- is emitted from the html2markdown job exit.
          if to_markdown and content_type == 'text/html' then
            local md_stdout = {}
            local md_stderr = {}
            local md_jobid = job.start({ 'html2markdown' }, {
              on_stdout = function(_, data)
                for _, v in ipairs(data) do
                  table.insert(md_stdout, v)
                end
              end,
              on_stderr = function(_, data)
                for _, v in ipairs(data) do
                  table.insert(md_stderr, v)
                end
              end,
              on_exit = function(md_id, md_code, md_signal)
                if md_signal ~= 0 then
                  ctx.callback({
                    error = string.format(
                      'html2markdown cancelled by user (signal: %d)',
                      md_signal
                    ),
                    jobid = id,
                  })
                  return
                end

                if md_code ~= 0 then
                  local err_result = util.sanitize_utf8(table.concat(md_stderr, '\n'))
                  ctx.callback({
                    error = string.format(
                      'html2markdown failed to convert the response (exit code: %d): %s',
                      md_code,
                      err_result ~= '' and err_result or 'no error output'
                    ),
                    jobid = id,
                  })
                  return
                end

                emit_content(
                  util.sanitize_utf8(table.concat(md_stdout, '\n')),
                  'text/markdown'
                )
              end,
            })

            if md_jobid and md_jobid > 0 then
              -- Pipe the HTML via stdin, then close it (nil sends EOF)
              job.send(md_jobid, result)
              job.send(md_jobid, nil)
            else
              ctx.callback({
                error = 'failed to start html2markdown job',
                jobid = id,
              })
            end
            return
          end

          emit_content(result, content_type, to_markdown
            and '[Note: markdown conversion skipped, response is not HTML.]\n\n')
        end
      else
        -- Error handling
        local result = util.sanitize_utf8(table.concat(stdout, '\n'))
        local err_result = util.sanitize_utf8(table.concat(stderr, '\n'))
        if result ~= '' then
          result = result .. '\n\n' .. err_result
        else
          result = err_result
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

        -- Provide troubleshooting tips via unified curl error messages
        local curl_hint = curl.get_error_message(code)
        if curl_hint then
          error_msg = error_msg
            .. '\n\nTroubleshooting: ' .. curl_hint
        end

        ctx.callback({
          error = error_msg,
          jobid = id,
        })
      end
    end,
  })

  if jobid and jobid > 0 then
    return {
      jobid = jobid,
    }
  end

  -- job.start failed to spawn the curl process (e.g. not executable):
  -- on_exit will never fire, so fail fast instead of leaving a pending
  -- async tool whose callback would never arrive.
  return {
    error = string.format(
      'Failed to start curl process (jobid: %s). Please verify curl is installed and executable.',
      tostring(jobid)
    ),
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
         - Optional: html2markdown CLI (https://github.com/JohannesKaufmann/html-to-markdown)
           required only when markdown=true
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
         
         7. No truncation (full content):
            @fetch_web url="https://example.com" max_length=0
         
         8. Custom truncation limit:
            @fetch_web url="https://example.com" max_length=50000
         
         9. Convert HTML pages to Markdown before returning:
            @fetch_web url="https://example.com" markdown=true
         
         SECURITY NOTES:
         - Only HTTP/HTTPS URLs are allowed (no file://, ftp://, etc.)
         - SSL verification is enabled by default
         - Timeout defaults to 30 seconds to prevent hanging
         - User agent identifies as chat.nvim by default
         
         PERFORMANCE NOTES:
         - Responses are limited to 10,000 characters for display by default
         - Use max_length=0 to disable truncation and get full content
         - For large responses, consider using output parameter to save to file
         - Compression is automatically requested (--compressed)
         - Use markdown=true to convert HTML to clean Markdown, greatly reducing
           tokens compared to raw HTML
         
         TROUBLESHOOTING:
         - If curl is not installed, you'll get an error
         - If html2markdown is not installed, markdown=true returns an error
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
          max_length = {
            type = 'integer',
            description = 'Maximum characters to display (default: 10000, set to 0 or -1 to disable truncation)',
          },
          insecure = {
            type = 'boolean',
            description = 'Disable SSL certificate verification (use with caution, for testing only)',
          },
          markdown = {
            type = 'boolean',
            description = 'Convert HTML response to Markdown via the html2markdown CLI before returning (requires html2markdown in PATH). Ignored when output is set or the response is not HTML.',
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
    -- Format an argument that may be a number or a numeric string safely.
    local function fmt_int(v)
      local n = tonumber(v)
      if n ~= nil then
        return string.format('%d', n)
      end
      return tostring(v)
    end

    local info_parts = {
      string.format('fetch_web "%s"', arguments.url),
    }

    if arguments.method and arguments.method ~= 'GET' then
      table.insert(info_parts, string.format('method=%s', arguments.method))
    end

    if arguments.timeout ~= nil then
      table.insert(info_parts, string.format('timeout=%s', fmt_int(arguments.timeout)))
    end

    if arguments.max_length ~= nil then
      table.insert(info_parts, string.format('max_length=%s', fmt_int(arguments.max_length)))
    end

    if arguments.markdown then
      table.insert(info_parts, 'markdown=true')
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

