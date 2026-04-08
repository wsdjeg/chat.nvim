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
local message_buffers = {} -- Store message start events

function M.on_stdout(id, data)
  if not sse_buffers[id] then
    sse_buffers[id] = {}
  end
  if not body_buffers[id] then
    body_buffers[id] = {}
  end
  if not message_buffers[id] then
    message_buffers[id] = {}
  end

  vim.schedule(function()
    for _, line in ipairs(data) do
      log.debug(line)

      if vim.startswith(line, 'data:') then
        local v = line:sub(6)
        if v:sub(1, 1) == ' ' then
          v = v:sub(2)
        end
        table.insert(sse_buffers[id], v)
      elseif line == '' then
        if #sse_buffers[id] > 0 then
          local text = table.concat(sse_buffers[id], '\n')
          sse_buffers[id] = {}

          if vim.trim(text) == '' then
            return
          end

          local ok, chunk = pcall(vim.json.decode, text)
          if not ok then
            log.error('Failed to decode JSON: ' .. text)
          elseif chunk then
            -- Handle different event types
            if chunk.type == 'message_start' then
              -- Store message info
              message_buffers[id] = chunk.message
              if chunk.message.usage then
                -- Normalize usage field names to match OpenAI format
                local normalized_usage = {
                  total_tokens = chunk.message.usage.input_tokens + chunk.message.usage.output_tokens,
                  prompt_tokens = chunk.message.usage.input_tokens,
                  completion_tokens = chunk.message.usage.output_tokens,
                }
                sessions.set_progress_usage(id, normalized_usage)
              end
            elseif chunk.type == 'content_block_start' then
              -- Content block starting
              log.info('content_block_start: ' .. chunk.index)
            elseif chunk.type == 'content_block_delta' then
              -- Streaming content
              if chunk.delta and chunk.delta.type == 'text_delta' then
                if chunk.delta.text and #chunk.delta.text > 0 then
                  log.info('handle text delta')
                  sessions.on_progress(id, chunk.delta.text)
                end
              elseif
                chunk.delta and chunk.delta.type == 'input_json_delta'
              then
                -- Tool use streaming
                log.info('handle tool_input delta')
                -- Handle partial tool input if needed
              end
            elseif chunk.type == 'content_block_stop' then
              -- Content block finished
              log.info('content_block_stop: ' .. chunk.index)
            elseif chunk.type == 'message_delta' then
              -- Message update
              if chunk.delta and chunk.delta.stop_reason then
                sessions.set_progress_finish_reason(
                  id,
                  chunk.delta.stop_reason
                )
              end
              if chunk.usage then
                -- Normalize usage field names to match OpenAI format
                local normalized_usage = {
                  total_tokens = chunk.usage.total_tokens or (chunk.usage.input_tokens + chunk.usage.output_tokens),
                  prompt_tokens = chunk.usage.input_tokens,
                  completion_tokens = chunk.usage.output_tokens,
                }
                sessions.set_progress_usage(id, normalized_usage)
              end
            elseif chunk.type == 'message_stop' then
              -- Message complete
              log.info('message_stop')
              sessions.set_progress_finish_reason(id, 'stop')
            elseif chunk.type == 'ping' then
              -- Keep-alive ping, ignore
              log.debug('received ping')
            elseif chunk.error then
              local error_msg = chunk.error.message or 'Unknown error'
              local error_type = chunk.error.type or 'unknown'
              local message = {
                error = string.format(
                  'Anthropic API Error (%s): %s',
                  error_type,
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
      else
        table.insert(body_buffers[id], line)
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

    if body_buffers[id] and #body_buffers[id] > 0 then
      local text = table.concat(body_buffers[id], '\n')
      body_buffers[id] = {}
      local ok, chunk = pcall(vim.json.decode, text)
      if ok and chunk.error then
        local error_msg = chunk.error.message or 'Unknown error'
        local error_type = chunk.error.type or 'unknown'
        local message = {
          error = string.format(
            'Anthropic API Error (%s): %s',
            error_type,
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
    if reason == 'end_turn' or reason == 'stop' or reason == 'tool_use' then
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
    message_buffers[id] = nil
  end)
end

return M
