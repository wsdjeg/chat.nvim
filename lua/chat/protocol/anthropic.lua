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
              -- Handle usage info from message_start
              if chunk.message.usage then
                -- Normalize usage field names to match OpenAI format
                local normalized_usage = {
                  total_tokens = chunk.message.usage.input_tokens
                    + chunk.message.usage.output_tokens,
                  prompt_tokens = chunk.message.usage.input_tokens,
                  completion_tokens = chunk.message.usage.output_tokens,
                }
                sessions.set_progress_usage(id, normalized_usage)
              end
            elseif chunk.type == 'content_block_start' then
              -- Content block starting
              log.info('content_block_start: ' .. chunk.index)
              -- Check if this is a tool_use block
              if
                chunk.content_block
                and chunk.content_block.type == 'tool_use'
              then
                log.info('tool_use start: ' .. chunk.content_block.id)
                -- Initialize tool_use and pass to sessions
                local tool_use = {
                  id = chunk.content_block.id,
                  index = (chunk.content_block.index or chunk.index) - 1,
                  type = 'function',
                  ['function'] = {
                    name = chunk.content_block.name,
                    arguments = '',
                  },
                }
                sessions.on_progress_tool_call(id, tool_use)
              end
            elseif chunk.type == 'content_block_delta' then
              -- Streaming content
              if chunk.delta and chunk.delta.type == 'text_delta' then
                if chunk.delta.text and #chunk.delta.text > 0 then
                  log.info('handle text delta')
                  sessions.on_progress(id, chunk.delta.text)
                end
              elseif chunk.delta and chunk.delta.type == 'thinking_delta' then
                -- Thinking content streaming (similar to reasoning_content in OpenAI)
                if chunk.delta.thinking and #chunk.delta.thinking > 0 then
                  log.info('handle thinking delta')
                  sessions.on_progress_reasoning_content(
                    id,
                    chunk.delta.thinking
                  )
                end
              elseif
                chunk.delta and chunk.delta.type == 'signature_delta'
              then
                -- Signature delta for thinking block (Moonshot/Kimi specific)
                -- This event appears at the end of a thinking block before content_block_stop
                -- No special handling needed, just acknowledge it
                log.debug('received signature_delta for thinking block')
              elseif
                chunk.delta and chunk.delta.type == 'input_json_delta'
              then
                -- Tool use streaming - accumulate JSON input (matching OpenAI protocol)
                log.info('handle tool_input delta')
                if chunk.delta.partial_json then
                  sessions.on_progress_tool_call(id, {
                    index = chunk.index - 1,
                    ['function'] = {
                      arguments = chunk.delta.partial_json,
                    },
                  })
                end
              end
            elseif chunk.type == 'content_block_stop' then
              -- Content block finished
              log.info('content_block_stop: ' .. chunk.index)
              -- Tool use completion is handled in on_exit when reason == 'tool_use'
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
                  total_tokens = chunk.usage.total_tokens
                    or (chunk.usage.input_tokens + chunk.usage.output_tokens),
                  prompt_tokens = chunk.usage.input_tokens,
                  completion_tokens = chunk.usage.output_tokens,
                }
                sessions.set_progress_usage(id, normalized_usage)
              end
            elseif chunk.type == 'message_stop' then
              -- Message complete
              log.info('message_stop')
              -- Only set finish_reason to 'stop' if not already set (e.g., by message_delta with 'tool_use')
              if not sessions.get_progress_finish_reason(id) then
                sessions.set_progress_finish_reason(id, 'stop')
              end
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
    log.info('finish_reason: ' .. tostring(reason))
    if reason == 'end_turn' or reason == 'stop' then
      sessions.on_progress_done(id)
      sessions.on_complete(session, id)
    elseif reason == 'tool_use' then
      sessions.on_complete(session, id)
      sessions.on_progress_tool_call_done(id)
    end

    if session == require('chat.windows').current_session() then
      -- Match OpenAI protocol: only stop spinner if no pending async tools
      if not sessions.has_pending_async_tools(session) then
        require('chat.spinners').stop()
      end
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

    -- Send tool results back to server (same as OpenAI protocol)
    if code == 0 and signal == 0 then
      local session_messages = sessions.get_messages(session)
      if session_messages[#session_messages].error then
        log.info('API error detected, skip sending tool results')
      else
        local messages = sessions.get_request_messages(session)
        if messages[#messages].role == 'tool' then
          if not sessions.has_pending_async_tools(session) then
            sessions.send_tool_results(session)
          end
        end
      end
    end

    -- Clean up buffers
    sse_buffers[id] = nil
    body_buffers[id] = nil
  end)
end

function M.convert_message(messages)
  local system_prompt = nil
  local anthropic_messages = {}
  for _, msg in ipairs(messages) do
    if msg.role == 'system' then
      system_prompt = msg.content
    elseif msg.role == 'user' then
      table.insert(anthropic_messages, {
        role = msg.role,
        content = {
          {
            type = 'text',
            text = msg.content,
          },
        },
      })
    elseif msg.role == 'assistant' then
      local content = {}
      if msg.reasoning_content and msg.reasoning_content ~= '' then
        table.insert(content, {
          type = 'thinking',
          thinking = msg.reasoning_content,
          -- signature = '',
        })
      end
      if msg.tool_calls then
        for _, tool_call in ipairs(msg.tool_calls) do
          table.insert(content, {
            type = 'tool_use',
            id = tool_call.id,
            name = tool_call.name,
            input = tool_call.arguments,
          })
        end
      end
      table.insert(anthropic_messages, {
        role = msg.role,
        content = content,
      })
    elseif msg.role == 'tool' then
      -- Convert tool results
      table.insert(anthropic_messages, {
        role = 'user',
        content = {
          {
            type = 'tool_result',
            tool_use_id = msg.tool_call_id,
            content = { type = 'text', text = msg.content },
          },
        },
      })
    end
  end

  return system_prompt, anthropic_messages
end

return M
