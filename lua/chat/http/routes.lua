local sessions = require('chat.sessions')
local response = require('chat.http.response')

local M = {}

--- Build session info object (shared by GET /sessions and GET /sessions/:id)
local function build_session_info(id, data)
  local messages = sessions.get_messages(id)
  local message_count = #messages
  local last_message = nil
  local title = ''
  if message_count > 0 then
    local last = messages[message_count]
    local content = last.content or ''
    if #content > 100 then
      content = content:sub(1, 100) .. '...'
    end
    last_message = {
      role = last.role,
      content = content,
      created = last.created,
    }
    for _, msg in ipairs(messages) do
      if msg.role == 'user' then
        title = msg.content or ''
        if #title > 50 then
          title = title:sub(1, 50) .. '...'
        end
        break
      end
    end
  end
  return {
    id = id,
    title = title,
    cwd = data.cwd or vim.fn.getcwd(),
    provider = data.provider,
    model = data.model,
    pin = sessions.get_session_pin(id),
    in_progress = sessions.is_in_progress(id),
    message_count = message_count,
    last_message = last_message,
  }
end

--- Handle HTTP request (separated for vim.schedule_wrap)
function M.handle_request(client, method, path, headers, body, content_length)
  local config = require('chat.config')
  local url_decode = response.url_decode

  -- GET /session?id=session_id: return HTML preview (no auth required)
  if method == 'GET' and path:match('^/session%?') then
    local session_id = path:match('id=([^&]+)')
    if not session_id then
      response.send_response(client, 400, 'Bad Request')
      return
    end

    session_id = url_decode(session_id)

    local all_sessions = sessions.get()
    local session_data = all_sessions[session_id]

    if not session_data then
      response.send_response(client, 404, 'Not Found')
      return
    end

    local html = require('chat.preview').generate_html(session_data)
    local resp = string.format(
      'HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: %d\r\n\r\n%s',
      #html,
      html
    )
    client:write(resp)
    client:close()
    return
  end

  --------------------------------------------------
  -- API key check (use header: X-API-Key)
  --------------------------------------------------
  if headers['x-api-key'] ~= config.config.http.api_key then
    response.send_response(client, 401, 'Unauthorized')
    return
  end

  -- Route handling
  if method == 'GET' and path == '/sessions' then
    -- GET /sessions: return session list with details
    local all_sessions = sessions.get()
    local session_list = {}
    for id, data in pairs(all_sessions) do
      table.insert(session_list, build_session_info(id, data))
    end
    response.send_json(client, 200, session_list)

  elseif method == 'GET' and path:match('^/sessions/[^/]+$') then
    -- GET /sessions/:id: return single session info
    local session_id = path:match('^/sessions/(.+)$')
    if not session_id then
      response.send_response(client, 400, 'Bad Request')
      return
    end

    session_id = url_decode(session_id)

    local all_sessions = sessions.get()
    local session_data = all_sessions[session_id]

    if not session_data then
      response.send_json(client, 404, { error = 'Session not found' })
      return
    end

    response.send_json(client, 200, build_session_info(session_id, session_data))

  elseif method == 'GET' and path == '/providers' then
    local provider_files = vim.api.nvim_get_runtime_file('lua/chat/providers/*.lua', true)
    local providers = {}
    for _, file in ipairs(provider_files) do
      local name = vim.fn.fnamemodify(file, ':t:r')
      local ok, provider = pcall(require, 'chat.providers.' .. name)
      if ok and provider then
        local models = {}
        if provider.available_models then
          models = provider.available_models() or {}
        end
        table.insert(providers, {
          name = name,
          models = models,
        })
      end
    end
    table.sort(providers, function(a, b)
      return a.name < b.name
    end)
    response.send_json(client, 200, providers)
  elseif method == 'POST' and path == '/session/new' then
    -- POST /session/new: create new session
    local new_id = sessions.new()

    -- Parse optional body for provider and model
    if content_length and content_length > 0 then
      local ok, obj = pcall(vim.json.decode, body:sub(1, content_length))
      if ok and type(obj) == 'table' then
        if obj.provider and type(obj.provider) == 'string' and obj.provider ~= '' then
          sessions.set_session_provider(new_id, obj.provider)
        end
        if obj.model and type(obj.model) == 'string' and obj.model ~= '' then
          sessions.set_session_model(new_id, obj.model)
        end
      end
    end

    -- Get updated session data
    local all_sessions = sessions.get()
    local session_data = all_sessions[new_id]

    response.send_json(client, 200, {
      id = new_id,
      title = '',
      cwd = session_data.cwd or vim.fn.getcwd(),
      provider = session_data.provider,
      model = session_data.model,
      in_progress = false,
      message_count = 0,
      last_message = nil,
    })
  elseif method == 'DELETE' and path:match('^/session/') then
    -- DELETE /session/:id: delete session
    local session_id = path:match('^/session/(.+)$')
    if not session_id then
      response.send_response(client, 400, 'Bad Request')
      return
    end

    session_id = url_decode(session_id)

    -- Check if session exists
    if not sessions.exists(session_id) then
      response.send_json(client, 404, { error = 'Session not found' })
      return
    end

    -- Check if session is in progress
    if sessions.is_in_progress(session_id) then
      response.send_json(client, 409, { error = 'Session is in progress' })
      return
    end

    -- Delete session
    sessions.delete(session_id)

    response.send_response(client, 204, 'No Content')

  elseif method == 'POST' and path:match('^/session/[^/]+/stop$') then
    -- POST /session/:id/stop: stop generation
    local session_id = path:match('^/session/([^/]+)/stop$')
    if not session_id then
      response.send_response(client, 400, 'Bad Request')
      return
    end

    session_id = url_decode(session_id)

    -- Check if session exists
    if not sessions.exists(session_id) then
      response.send_json(client, 404, { error = 'Session not found' })
      return
    end

    -- Cancel progress
    sessions.cancel_progress(session_id)

    response.send_response(client, 204, 'No Content')
  elseif method == 'POST' and path:match('^/session/[^/]+/clear$') then
    -- POST /session/:id/clear: clear session messages
    local session_id = path:match('^/session/([^/]+)/clear$')
    if not session_id then
      response.send_response(client, 400, 'Bad Request')
      return
    end

    session_id = url_decode(session_id)

    -- Check if session exists
    if not sessions.exists(session_id) then
      response.send_json(client, 404, { error = 'Session not found' })
      return
    end

    -- Check if session is in progress
    if sessions.is_in_progress(session_id) then
      response.send_json(client, 409, { error = 'Session is in progress' })
      return
    end

    -- Clear session
    local success = sessions.clear(session_id)
    if success then
      response.send_response(client, 204, 'No Content')
    else
      response.send_json(client, 500, { error = 'Failed to clear session' })
    end
  elseif method == 'PUT' and path:match('^/session/[^/]+/provider$') then
    -- PUT /session/:id/provider: set provider for session
    local session_id = path:match('^/session/([^/]+)/provider$')
    if not session_id then
      response.send_response(client, 400, 'Bad Request')
      return
    end

    session_id = url_decode(session_id)

    -- Check if session exists
    if not sessions.exists(session_id) then
      response.send_json(client, 404, { error = 'Session not found' })
      return
    end

    -- Parse body
    local ok, obj = pcall(vim.json.decode, body:sub(1, content_length))
    if not ok or type(obj) ~= 'table' then
      response.send_response(client, 400, 'Bad Request')
      return
    end

    local provider = obj.provider
    if type(provider) ~= 'string' or provider == '' then
      response.send_json(client, 400, { error = 'Missing or invalid provider' })
      return
    end

    -- Set provider
    sessions.set_session_provider(session_id, provider)

    response.send_response(client, 204, 'No Content')

  elseif method == 'PUT' and path:match('^/session/[^/]+/model$') then
    -- PUT /session/:id/model: set model for session
    local session_id = path:match('^/session/([^/]+)/model$')
    if not session_id then
      response.send_response(client, 400, 'Bad Request')
      return
    end

    session_id = url_decode(session_id)

    -- Check if session exists
    if not sessions.exists(session_id) then
      response.send_json(client, 404, { error = 'Session not found' })
      return
    end

    -- Parse body
    local ok, obj = pcall(vim.json.decode, body:sub(1, content_length))
    if not ok or type(obj) ~= 'table' then
      response.send_response(client, 400, 'Bad Request')
      return
    end

    local model = obj.model
    if type(model) ~= 'string' or model == '' then
      response.send_json(client, 400, { error = 'Missing or invalid model' })
      return
    end

    -- Set model
    sessions.set_session_model(session_id, model)

    response.send_response(client, 204, 'No Content')

  elseif method == 'PUT' and path:match('^/session/[^/]+/cwd$') then
    -- PUT /session/:id/cwd: set working directory for session
    local session_id = path:match('^/session/([^/]+)/cwd$')
    if not session_id then
      response.send_response(client, 400, 'Bad Request')
      return
    end

    session_id = url_decode(session_id)

    -- Check if session exists
    if not sessions.exists(session_id) then
      response.send_json(client, 404, { error = 'Session not found' })
      return
    end

    -- Parse body
    local ok, obj = pcall(vim.json.decode, body:sub(1, content_length))
    if not ok or type(obj) ~= 'table' then
      response.send_response(client, 400, 'Bad Request')
      return
    end

    local cwd = obj.cwd
    if type(cwd) ~= 'string' or cwd == '' then
      response.send_json(client, 400, { error = 'Missing or invalid cwd' })
      return
    end

    -- Normalize path
    cwd = vim.fs.normalize(cwd)

    -- Set cwd
    sessions.change_cwd(session_id, cwd)
    response.send_response(client, 204, 'No Content')

  elseif method == 'PUT' and path:match('^/session/[^/]+/pin$') then
    -- PUT /session/:id/pin: set pin status for session
    local session_id = path:match('^/session/([^/]+)/pin$')
    if not session_id then
      response.send_response(client, 400, 'Bad Request')
      return
    end

    session_id = url_decode(session_id)

    -- Check if session exists
    if not sessions.exists(session_id) then
      response.send_json(client, 404, { error = 'Session not found' })
      return
    end

    -- Parse body
    local ok, obj = pcall(vim.json.decode, body:sub(1, content_length))
    if not ok or type(obj) ~= 'table' then
      response.send_response(client, 400, 'Bad Request')
      return
    end

    local pin = obj.pin
    if type(pin) ~= 'boolean' then
      response.send_json(client, 400, { error = 'Missing or invalid pin value' })
      return
    end

    -- Set pin status
    sessions.set_session_pin(session_id, pin)

    response.send_response(client, 204, 'No Content')

  elseif method == 'POST' and path:match('^/session/[^/]+/retry$') then
    -- POST /session/:id/retry: retry last message
    local session_id = path:match('^/session/([^/]+)/retry$')
    if not session_id then
      response.send_response(client, 400, 'Bad Request')
      return
    end

    session_id = url_decode(session_id)

    -- Check if session exists
    if not sessions.exists(session_id) then
      response.send_json(client, 404, { error = 'Session not found' })
      return
    end

    -- Check if session is in progress
    if sessions.is_in_progress(session_id) then
      response.send_json(client, 409, { error = 'Session is in progress' })
      return
    end

    -- Retry
    local ok, err = sessions.retry(session_id)
    if not ok then
      response.send_json(client, 400, { error = err or 'Retry failed' })
      return
    end

    response.send_response(client, 204, 'No Content')

  elseif method == 'GET' and path:match('^/messages%?') then
    -- GET /messages?session=session_id&since=index: return message list
    local session_id = path:match('session=([^&]+)')
    if not session_id then
      response.send_response(client, 400, 'Bad Request')
      return
    end

    session_id = url_decode(session_id)

    if not sessions.exists(session_id) then
      response.send_response(client, 404, 'Not Found')
      return
    end

    local messages = sessions.get_messages(session_id)

    -- Support since parameter (1-indexed, returns messages[since..#messages])
    local since = path:match('since=(%d+)')
    if since then
      since = tonumber(since)
      if since and since >= 1 and since <= #messages then
        messages = vim.list_slice(messages, since)
      elseif since and since > #messages then
        messages = {} -- Return empty if since is beyond range
      end
    end

    response.send_json(client, 200, messages)

  elseif method == 'POST' and path == '/' then
    -- POST /: push message to session (existing behavior)
    local ok, obj = pcall(vim.json.decode, body:sub(1, content_length))
    if not ok or type(obj) ~= 'table' then
      response.send_response(client, 400, 'Bad Request')
      return
    end

    local session = obj.session
    local content = obj.content

    if type(session) ~= 'string' or type(content) ~= 'string' then
      response.send_response(client, 400, 'Bad Request')
      return
    end

    require('chat.queue').push(session, content)

    response.send_response(client, 204, 'No Content')

  else
    -- Other routes not found
    response.send_response(client, 404, 'Not Found')
  end
end

return M
