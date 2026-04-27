local uv = vim.loop

local M = {}

local config = require('chat.config')
local sessions = require('chat.sessions')

local function parse_headers(raw)
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
local function url_decode(str)
  return str:gsub('%%(%x%x)', function(h)
    return string.char(tonumber(h, 16))
  end)
end

--- Send JSON response
local function send_json(client, status, data)
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
local function send_error(client, status, message)
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
local function send_response(client, status, message)
  local resp = string.format(
    'HTTP/1.1 %d %s\r\nContent-Length: 0\r\n\r\n',
    status,
    message
  )
  client:write(resp)
  client:close()
end

--- Handle HTTP request (separated for vim.schedule_wrap)
local function handle_request(client, method, path, headers, body, content_length)
  -- GET /session?id=session_id: return HTML preview (no auth required)
  if method == 'GET' and path:match('^/session%?') then
    local session_id = path:match('id=([^&]+)')
    if not session_id then
      send_response(client, 400, 'Bad Request')
      return
    end

    session_id = url_decode(session_id)

    local all_sessions = sessions.get()
    local session_data = all_sessions[session_id]

    if not session_data then
      send_response(client, 404, 'Not Found')
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
    send_response(client, 401, 'Unauthorized')
    return
  end

  -- Route handling
  if method == 'GET' and path == '/sessions' then
    -- GET /sessions: return session list with details
    local all_sessions = sessions.get()
    local session_list = {}
    for id, data in pairs(all_sessions) do
      -- Get message count and last message
      local messages = sessions.get_messages(id)
      local message_count = #messages
      local last_message = nil
      local title = ''
      if message_count > 0 then
        local last = messages[message_count]
        local content = last.content or ''
        -- Truncate content to 100 characters
        if #content > 100 then
          content = content:sub(1, 100) .. '...'
        end
        last_message = {
          role = last.role,
          content = content,
          created = last.created,
        }
        -- Extract title from first user message
        for _, msg in ipairs(messages) do
          if msg.role == 'user' then
            title = msg.content or ''
            -- Truncate title to 50 characters
            if #title > 50 then
              title = title:sub(1, 50) .. '...'
            end
            break
          end
        end
      end

      table.insert(session_list, {
        id = id,
        title = title,
        cwd = data.cwd or vim.fn.getcwd(),
        provider = data.provider,
        model = data.model,
        in_progress = sessions.is_in_progress(id),
        message_count = message_count,
        last_message = last_message,
      })
    end
    send_json(client, 200, session_list)

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
    send_json(client, 200, providers)

  elseif method == 'POST' and path == '/session/new' then
    -- POST /session/new: create new session
    local new_id = sessions.new()
    send_json(client, 200, { session_id = new_id })

  elseif method == 'DELETE' and path:match('^/session/') then
    -- DELETE /session/:id: delete session
    local session_id = path:match('^/session/(.+)$')
    if not session_id then
      send_response(client, 400, 'Bad Request')
      return
    end

    session_id = url_decode(session_id)

    -- Check if session exists
    if not sessions.exists(session_id) then
      send_json(client, 404, { error = 'Session not found' })
      return
    end

    -- Check if session is in progress
    if sessions.is_in_progress(session_id) then
      send_json(client, 409, { error = 'Session is in progress' })
      return
    end

    -- Delete session
    sessions.delete(session_id)

    send_response(client, 204, 'No Content')

  elseif method == 'POST' and path:match('^/session/[^/]+/stop$') then
    -- POST /session/:id/stop: stop generation
    local session_id = path:match('^/session/([^/]+)/stop$')
    if not session_id then
      send_response(client, 400, 'Bad Request')
      return
    end

    session_id = url_decode(session_id)

    -- Check if session exists
    if not sessions.exists(session_id) then
      send_json(client, 404, { error = 'Session not found' })
      return
    end

    -- Cancel progress
    sessions.cancel_progress(session_id)

    send_response(client, 204, 'No Content')
  elseif method == 'POST' and path:match('^/session/[^/]+/clear$') then
    -- POST /session/:id/clear: clear session messages
    local session_id = path:match('^/session/([^/]+)/clear$')
    if not session_id then
      send_response(client, 400, 'Bad Request')
      return
    end

    session_id = url_decode(session_id)

    -- Check if session exists
    if not sessions.exists(session_id) then
      send_json(client, 404, { error = 'Session not found' })
      return
    end

    -- Check if session is in progress
    if sessions.is_in_progress(session_id) then
      send_json(client, 409, { error = 'Session is in progress' })
      return
    end

    -- Clear session
    local success = sessions.clear(session_id)
    if success then
      send_response(client, 204, 'No Content')
    else
      send_json(client, 500, { error = 'Failed to clear session' })
    end
  elseif method == 'PUT' and path:match('^/session/[^/]+/provider$') then
    -- PUT /session/:id/provider: set provider for session
    local session_id = path:match('^/session/([^/]+)/provider$')
    if not session_id then
      send_response(client, 400, 'Bad Request')
      return
    end

    session_id = url_decode(session_id)

    -- Check if session exists
    if not sessions.exists(session_id) then
      send_json(client, 404, { error = 'Session not found' })
      return
    end

    -- Parse body
    local ok, obj = pcall(vim.json.decode, body:sub(1, content_length))
    if not ok or type(obj) ~= 'table' then
      send_response(client, 400, 'Bad Request')
      return
    end

    local provider = obj.provider
    if type(provider) ~= 'string' or provider == '' then
      send_json(client, 400, { error = 'Missing or invalid provider' })
      return
    end

    -- Set provider
    sessions.set_session_provider(session_id, provider)

    send_response(client, 204, 'No Content')

  elseif method == 'PUT' and path:match('^/session/[^/]+/model$') then
    -- PUT /session/:id/model: set model for session
    local session_id = path:match('^/session/([^/]+)/model$')
    if not session_id then
      send_response(client, 400, 'Bad Request')
      return
    end

    session_id = url_decode(session_id)

    -- Check if session exists
    if not sessions.exists(session_id) then
      send_json(client, 404, { error = 'Session not found' })
      return
    end

    -- Parse body
    local ok, obj = pcall(vim.json.decode, body:sub(1, content_length))
    if not ok or type(obj) ~= 'table' then
      send_response(client, 400, 'Bad Request')
      return
    end

    local model = obj.model
    if type(model) ~= 'string' or model == '' then
      send_json(client, 400, { error = 'Missing or invalid model' })
      return
    end

    -- Set model
    sessions.set_session_model(session_id, model)

    send_response(client, 204, 'No Content')

  elseif method == 'POST' and path:match('^/session/[^/]+/retry$') then
    -- POST /session/:id/retry: retry last message
    local session_id = path:match('^/session/([^/]+)/retry$')
    if not session_id then
      send_response(client, 400, 'Bad Request')
      return
    end

    session_id = url_decode(session_id)

    -- Check if session exists
    if not sessions.exists(session_id) then
      send_json(client, 404, { error = 'Session not found' })
      return
    end

    -- Check if session is in progress
    if sessions.is_in_progress(session_id) then
      send_json(client, 409, { error = 'Session is in progress' })
      return
    end

    -- Retry
    local ok, err = sessions.retry(session_id)
    if not ok then
      send_json(client, 400, { error = err or 'Retry failed' })
      return
    end

    send_response(client, 204, 'No Content')

  elseif method == 'GET' and path:match('^/messages%?') then
    -- GET /messages?session=session_id&since=index: return message list
    local session_id = path:match('session=([^&]+)')
    if not session_id then
      send_response(client, 400, 'Bad Request')
      return
    end

    session_id = url_decode(session_id)

    if not sessions.exists(session_id) then
      send_response(client, 404, 'Not Found')
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

    send_json(client, 200, messages)

  elseif method == 'POST' and path == '/' then
    -- POST /: push message to session (existing behavior)
    local ok, obj = pcall(vim.json.decode, body:sub(1, content_length))
    if not ok or type(obj) ~= 'table' then
      send_response(client, 400, 'Bad Request')
      return
    end

    local session = obj.session
    local content = obj.content

    if type(session) ~= 'string' or type(content) ~= 'string' then
      send_response(client, 400, 'Bad Request')
      return
    end

    require('chat.queue').push(session, content)

    send_response(client, 204, 'No Content')

  else
    -- Other routes not found
    send_response(client, 404, 'Not Found')
  end
end

function M.start()
  if M._server then
    return
  end
  local host = config.config.http.host
  local port = config.config.http.port

  local server = uv.new_tcp()

  server:bind(host, port)

  server:listen(128, function(err)
    assert(not err, err)

    local client = uv.new_tcp()
    server:accept(client)

    local buffer = ''

    client:read_start(function(err, chunk)
      assert(not err, err)

      if not chunk then
        client:close()
        return
      end

      buffer = buffer .. chunk

      -- header not complete yet
      if not buffer:find('\r\n\r\n', 1, true) then
        return
      end

      local header_part, body = buffer:match('^(.-)\r\n\r\n(.*)$')
      if not header_part then
        return
      end

      local request_line = header_part:match('([^\r\n]+)')
      local method, path = request_line:match('^(%S+)%s+(%S+)')

      local headers = parse_headers(header_part)

      local content_length = tonumber(headers['content-length'] or '0')
      if #body < content_length then
        return
      end

      -- Use vim.schedule_wrap to handle request in main loop
      -- This allows safe use of vim.fn functions
      vim.schedule_wrap(handle_request)(client, method, path, headers, body, content_length)
    end)
  end)

  M._server = server
end

function M.stop()
  if M._server then
    M._server:close()
    M._server = nil
  end
end

return M
