local M = {}

local CURL_ERRORS = {
  [6] = "Couldn't resolve host. Check your network connection.",
  [7] = 'Failed to connect to host. Check if the server is reachable.',
  [22] = 'HTTP request failed with error response (>= 400).',
  [28] = 'Operation timeout. The server took too long to respond.',
  [35] = 'SSL/TLS handshake failure. Check your certificates.',
  [52] = 'Empty reply from server. The server returned no data.',
  [56] = 'Failure with receiving network data. Connection interrupted.',
}

local log = require('chat.log')
local sessions = require('chat.sessions')

local sse_buffers = {}
local body_buffers = {}

function M.on_stdout(id, data)
  if not sse_buffers[id] then
    sse_buffers[id] = {}
  end
  if not body_buffers[id] then
    body_buffers[id] = {}
  end

  vim.schedule(function()
    for _, line in ipairs(data) do
      log.debug(line)

      -- Gemini uses JSON lines for streaming
      -- Format: {"candidates":[{"content":{"parts":[{"text":"..."}],"role":"model"},"finishReason":"STOP"}]}
      if line and #line > 0 then
        local ok, chunk = pcall(vim.json.decode, line)
        if not ok then
          -- Try accumulating if incomplete
          table.insert(sse_buffers[id], line)
        elseif chunk then
          if chunk.candidates and #chunk.candidates > 0 then
            local candidate = chunk.candidates[1]

            -- Handle content
            if candidate.content and candidate.content.parts then
              for _, part in ipairs(candidate.content.parts) do
                if part.text and #part.text > 0 then
                  log.info('handle content')
                  sessions.on_progress(id, part.text)
                end
              end
            end

            -- Handle finish reason
            if candidate.finishReason then
              -- Map Gemini finish reasons to standard format
              local finish_reason = candidate.finishReason:lower()
              if finish_reason == 'stop' then
                sessions.set_progress_finish_reason(id, 'stop')
              elseif finish_reason == 'max_tokens' then
                sessions.set_progress_finish_reason(id, 'length')
              elseif finish_reason == 'safety' then
                sessions.set_progress_finish_reason(id, 'content_filter')
              else
                sessions.set_progress_finish_reason(id, finish_reason)
              end
            end
          end

          -- Handle usage metadata
          if chunk.usageMetadata then
            sessions.set_progress_usage(id, {
              prompt_tokens = chunk.usageMetadata.promptTokenCount or 0,
              completion_tokens = chunk.usageMetadata.candidatesTokenCount
                or 0,
              total_tokens = chunk.usageMetadata.totalTokenCount or 0,
            })
          end

          -- Handle errors
          if chunk.error then
            local error_msg = chunk.error.message or 'Unknown error'
            local error_code = chunk.error.code or 'unknown'
            local message = {
              error = string.format(
                'Gemini API Error (%s): %s',
                error_code,
                error_msg
              ),
              created = os.time(),
            }
            local session = sessions.get_progress_session(id)
            sessions.append_message(session, message)
            require('chat.windows').on_message(session, message)
          end
        end
      end
    end
  end)
end

function M.on_stderr(id, data)
  vim.schedule(function()
    for _, line in ipairs(data) do
      log.debug(string.format('jobid %d, stderr %s', id, line))
    end
  end)
end

function M.on_exit(id, code, signal)
  vim.schedule(function()
    local session = sessions.get_progress_session(id)

    -- Handle accumulated buffer
    if #sse_buffers[id] > 0 then
      local text = table.concat(sse_buffers[id], '\n')
      local ok, chunk = pcall(vim.json.decode, text)
      if ok and chunk.error then
        local error_msg = chunk.error.message or 'Unknown error'
        local error_code = chunk.error.code or 'unknown'
        local message = {
          error = string.format(
            'Gemini API Error (%s): %s',
            error_code,
            error_msg
          ),
          created = os.time(),
        }
        sessions.append_message(session, message)
        require('chat.windows').on_message(session, message)
      end
    end

    log.info(string.format('job exit code %d signal %d', code, signal))

    local reason = sessions.get_progress_finish_reason(id)
    if reason == 'stop' then
      sessions.on_progress_done(id)
      sessions.on_complete(session, id)
    end

    sessions.on_progress_exit(id, code, signal)

    if session == require('chat.windows').current_session() then
      require('chat.spinners').stop()
    end

    if signal == 2 then
      local message = {
        error = 'Request cancelled by user. Press r to retry.',
        created = os.time(),
      }
      require('chat.windows').on_message(session, message)
    elseif code ~= 0 and CURL_ERRORS[code] then
      local message = {
        error = CURL_ERRORS[code],
        created = os.time(),
      }
      require('chat.windows').on_message(session, message)
    elseif code ~= 0 then
      local message = {
        error = string.format('Curl failed with exit code %d', code),
        created = os.time(),
      }
      require('chat.windows').on_message(session, message)
    end

    -- Clean up buffers
    sse_buffers[id] = nil
    body_buffers[id] = nil
  end)
end

return M
