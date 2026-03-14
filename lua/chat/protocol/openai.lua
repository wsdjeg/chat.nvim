local M = {}

-- Define curl error codes and messages
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
          if vim.trim(text) == '[DONE]' then
            log.info('handle data DONE')
          else
            local ok, chunk = pcall(vim.json.decode, text)
            if not ok then
              log.error('Failed to decode JSON: ' .. text)
            elseif chunk and chunk.choices and #chunk.choices > 0 then
              local choice = chunk.choices[1]
              if choice.delta then
                if
                  choice.delta.tool_calls
                  and choice.delta.tool_calls ~= vim.NIL
                then
                  log.info('handle tool_calls chunk')
                  for _, tool_call in ipairs(choice.delta.tool_calls) do
                    sessions.on_progress_tool_call(id, tool_call)
                  end
                elseif
                  choice.delta.reasoning_content
                  and choice.delta.reasoning_content ~= vim.NIL
                  and #choice.delta.reasoning_content > 0
                then
                  log.info('handle reasoning_content')
                  sessions.on_progress_reasoning_content(
                    id,
                    choice.delta.reasoning_content
                  )
                elseif
                  choice.delta.content
                  and choice.delta.content ~= vim.NIL
                  and #choice.delta.content > 0
                then
                  log.info('handle content')
                  sessions.on_progress(id, choice.delta.content)
                end
              end
              if choice.finish_reason and choice.finish_reason ~= vim.NIL then
                sessions.set_progress_finish_reason(id, choice.finish_reason)
              end
            elseif chunk.error then
              local error_msg = chunk.error.message or 'Unknown error'
              local error_code = chunk.error.code or chunk.type or 'unknown'
              local message = {
                error = string.format(
                  'API Error (%s): %s',
                  error_code,
                  error_msg
                ),
                created = os.time(),
              }
              local session = sessions.get_progress_session(id)
              sessions.append_message(session, message)
              require('chat.windows').on_message(session, message)
            else
              log.debug('Received chunk without choices: ' .. text)
            end

            if chunk and chunk.usage and chunk.usage ~= vim.NIL then
              log.info('handle usage')
              sessions.set_progress_usage(id, chunk.usage)
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
        local error_code = chunk.error.code or chunk.type or 'unknown'
        local message = {
          error = string.format('API Error (%s): %s', error_code, error_msg),
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
    elseif reason == 'tool_calls' then
      sessions.on_complete(session, id)
      sessions.on_progress_tool_call_done(id)
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
        error = 'Curl failed with exit code %d. Run `curl --help` for details.',
        created = os.time(),
      }
      require('chat.windows').on_message(session, message)
    end
    if code == 0 and signal == 0 then
      local messages = sessions.get_request_messages(session)
      if messages[#messages].role == 'tool' then
        if not sessions.has_pending_async_tools(session) then
          sessions.send_tool_results(session)
        end
      end
    end
  end)
end

return M
