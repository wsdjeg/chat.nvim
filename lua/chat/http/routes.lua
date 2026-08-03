local sessions = require('chat.sessions')
local queue = require('chat.queue')
local response = require('chat.http.response')
local config = require('chat.config')
local util = require('chat.util')
local uv = vim.loop

local M = {}

local url_decode = response.url_decode

--------------------------------------------------
-- Helpers
--------------------------------------------------

--- Build session info object (shared by GET /sessions and GET /sessions/:id)
local function build_session_info(id, data)
  local messages = sessions.get_messages(id)
  local message_count = #messages
  local last_message = nil

  -- Use stored title first, fallback to auto-extract from first user message
  local title = sessions.get_session_title(id) or ''
  if title == '' and message_count > 0 then
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
  end

  return {
    id = id,
    title = title,
    cwd = data.cwd or vim.fn.getcwd(),
    provider = data.provider,
    model = data.model,
    pin = sessions.get_session_pin(id),
    in_progress = sessions.is_in_progress(id) or queue.has_pending(id),
    message_count = message_count,
    last_message = last_message,
    cleared_at = data.cleared_at,
  }
end

--- Parse JSON body, return (ok, obj). Sends 400 on failure.
local function parse_json_body(client, body, content_length)
  local ok, obj = pcall(vim.json.decode, body:sub(1, content_length))
  if not ok or type(obj) ~= 'table' then
    response.send_response(client, 400)
    return false, nil
  end
  return true, obj
end

--- Ensure session exists. Sends 404 and returns false if not.
local function ensure_session_exists(client, session_id)
  if not sessions.exists(session_id) then
    response.send_json(client, 404, { error = 'Session not found' })
    return false
  end
  return true
end

--------------------------------------------------
-- Endpoint handlers
--------------------------------------------------

--- GET /session?id=session_id: HTML preview (no auth required)
local function handle_session_preview(client, path)
  local session_id = path:match('id=([^&]+)')
  if not session_id then
    response.send_response(client, 400)
    return
  end

  session_id = url_decode(session_id)

  local all_sessions = sessions.get()
  local session_data = all_sessions[session_id]

  if not session_data then
    response.send_response(client, 404)
    return
  end

  local html = require('chat.preview').generate_html(session_data)
  response.send_raw(client, 200, 'text/html; charset=utf-8', html)
end

--- GET /sessions: list sessions with details
local function handle_list_sessions(client)
  local all_sessions = sessions.get()
  local session_list = {}
  for id, data in pairs(all_sessions) do
    table.insert(session_list, build_session_info(id, data))
  end
  response.send_json(client, 200, session_list)
end

--- GET /sessions/:id/raw: return raw cache content
local function handle_get_session_raw(client, path)
  local session_id = path:match('^/sessions/([^/]+)/raw$')
  session_id = url_decode(session_id)

  local cache_path = sessions.get_cache_path(session_id)
  if not cache_path then
    response.send_json(client, 404, { error = 'Session cache not found' })
    return
  end

  uv.fs_open(cache_path, 'r', 438, function(open_err, fd)
    if open_err or not fd then
      response.send_json(client, 500, { error = 'Failed to read cache' })
      return
    end
    uv.fs_fstat(fd, function(stat_err, stat)
      if stat_err or not stat then
        uv.fs_close(fd)
        response.send_json(client, 500, { error = 'Failed to read cache' })
        return
      end
      uv.fs_read(fd, stat.size, 0, function(read_err, data)
        uv.fs_close(fd)
        if read_err or not data then
          response.send_json(client, 500, { error = 'Failed to read cache' })
          return
        end
        response.send_raw(client, 200, 'application/json', data)
      end)
    end)
  end)
end

--- GET /sessions/:id: return single session info
local function handle_get_session(client, path)
  local session_id = path:match('^/sessions/([^/]+)$')
  if not session_id then
    response.send_response(client, 400)
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
end

--- GET /providers: list available providers and their models
local function handle_list_providers(client)
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
end

--- POST /session/new: create new session
local function handle_new_session(client, body, content_length)
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
end

--- DELETE /session/:id: delete session
local function handle_delete_session(client, path)
  local session_id = path:match('^/session/([^/]+)$')
  if not session_id then
    response.send_response(client, 400)
    return
  end

  session_id = url_decode(session_id)

  if not ensure_session_exists(client, session_id) then
    return
  end

  if sessions.is_in_progress(session_id) then
    response.send_json(client, 409, { error = 'Session is in progress' })
    return
  end

  local next_session = sessions.delete(session_id)

  -- If the deleted session was the current TUI session, switch to next
  -- (mirrors :Chat delete behavior)
  if next_session then
    local windows = require('chat.windows')
    if windows.is_open() then
      windows.open({ session = next_session })
    end
  end

  response.send_response(client, 204)
end

--- POST /session/:id/stop: stop generation
local function handle_stop_session(client, path)
  local session_id = path:match('^/session/([^/]+)/stop$')
  if not session_id then
    response.send_response(client, 400)
    return
  end

  session_id = url_decode(session_id)

  if not ensure_session_exists(client, session_id) then
    return
  end

  sessions.cancel_progress(session_id)
  response.send_response(client, 204)
end

--- POST /session/:id/clear: clear session messages
local function handle_clear_session(client, path)
  local session_id = path:match('^/session/([^/]+)/clear$')
  if not session_id then
    response.send_response(client, 400)
    return
  end

  session_id = url_decode(session_id)

  if not ensure_session_exists(client, session_id) then
    return
  end

  if sessions.is_in_progress(session_id) then
    response.send_json(client, 409, { error = 'Session is in progress' })
    return
  end

  local success = sessions.clear(session_id)
  if success then
    response.send_response(client, 204)
  else
    response.send_json(client, 500, { error = 'Failed to clear session' })
  end
end

--- PUT /session/:id/provider: set provider for session
local function handle_set_provider(client, path, body, content_length)
  local session_id = path:match('^/session/([^/]+)/provider$')
  if not session_id then
    response.send_response(client, 400)
    return
  end

  session_id = url_decode(session_id)

  if not ensure_session_exists(client, session_id) then
    return
  end

  local ok, obj = parse_json_body(client, body, content_length)
  if not ok then
    return
  end

  local provider = obj.provider
  if type(provider) ~= 'string' or provider == '' then
    response.send_json(client, 400, { error = 'Missing or invalid provider' })
    return
  end

  sessions.set_session_provider(session_id, provider)
  response.send_response(client, 204)
end

--- PUT /session/:id/model: set model for session
local function handle_set_model(client, path, body, content_length)
  local session_id = path:match('^/session/([^/]+)/model$')
  if not session_id then
    response.send_response(client, 400)
    return
  end

  session_id = url_decode(session_id)

  if not ensure_session_exists(client, session_id) then
    return
  end

  local ok, obj = parse_json_body(client, body, content_length)
  if not ok then
    return
  end

  local model = obj.model
  if type(model) ~= 'string' or model == '' then
    response.send_json(client, 400, { error = 'Missing or invalid model' })
    return
  end

  sessions.set_session_model(session_id, model)
  response.send_response(client, 204)
end

--- PUT /session/:id/cwd: set working directory for session
local function handle_set_cwd(client, path, body, content_length)
  local session_id = path:match('^/session/([^/]+)/cwd$')
  if not session_id then
    response.send_response(client, 400)
    return
  end

  session_id = url_decode(session_id)

  if not ensure_session_exists(client, session_id) then
    return
  end

  local ok, obj = parse_json_body(client, body, content_length)
  if not ok then
    return
  end

  local cwd = obj.cwd
  if type(cwd) ~= 'string' or cwd == '' then
    response.send_json(client, 400, { error = 'Missing or invalid cwd' })
    return
  end

  cwd = vim.fs.normalize(cwd)
  sessions.change_cwd(session_id, cwd)
  response.send_response(client, 204)
end

--- GET /session/:id/upload-dir: get upload directory for session
local function handle_get_upload_dir(client, path)
  local session_id = path:match('^/session/([^/]+)/upload%-dir$')
  if not session_id then
    response.send_response(client, 400)
    return
  end

  session_id = url_decode(session_id)

  if not ensure_session_exists(client, session_id) then
    return
  end

  local upload_dir = sessions.get_upload_dir(session_id)
  response.send_json(client, 200, { upload_dir = upload_dir })
end

--- PUT /session/:id/upload-dir: set upload directory for session
--- Body: { "upload_dir": "/path/to/dir" } or { "upload_dir": null } to reset
local function handle_set_upload_dir(client, path, body, content_length)
  local session_id = path:match('^/session/([^/]+)/upload%-dir$')
  if not session_id then
    response.send_response(client, 400)
    return
  end

  session_id = url_decode(session_id)

  if not ensure_session_exists(client, session_id) then
    return
  end

  local ok, obj = parse_json_body(client, body, content_length)
  if not ok then
    return
  end

  local upload_dir = obj.upload_dir
  if upload_dir == nil or (type(upload_dir) == 'string' and upload_dir == '') then
    -- Reset to default (use cwd)
    sessions.set_upload_dir(session_id, nil)
    response.send_response(client, 204)
    return
  end

  if type(upload_dir) ~= 'string' then
    response.send_json(client, 400, { error = 'Invalid upload_dir (must be string or null)' })
    return
  end

  -- 1. Must be absolute path
  local is_abs = upload_dir:sub(1, 1) == '/'
    or upload_dir:match('^%a:[/\\]')
    or upload_dir:match('^[/\\][/\\]')
  if not is_abs then
    response.send_json(client, 400, {
      error = 'upload_dir must be an absolute path: ' .. upload_dir,
    })
    return
  end

  local normalized = vim.fs.normalize(upload_dir)

  -- 2. Must be within allowed_path
  if not util.is_allowed_path(normalized) then
    response.send_json(client, 400, {
      error = 'upload_dir is not in allowed_path: ' .. normalized,
    })
    return
  end

  -- 3. Must be within session cwd
  local session_cwd = sessions.getcwd(session_id)
  if session_cwd then
    local norm_cwd = vim.fs.normalize(session_cwd)
    if not norm_cwd:match('[/\\]$') then
      norm_cwd = norm_cwd .. '/'
    end
    local norm_dir = normalized
    if not norm_dir:match('[/\\]$') then
      norm_dir = norm_dir .. '/'
    end
    if not vim.startswith(norm_dir, norm_cwd) then
      response.send_json(client, 400, {
        error = 'upload_dir must be within session cwd: ' .. norm_cwd,
      })
      return
    end
  end

  -- Validate directory exists
  if vim.fn.isdirectory(normalized) ~= 1 then
    response.send_json(client, 400, { error = 'Directory does not exist: ' .. normalized })
    return
  end

  sessions.set_upload_dir(session_id, normalized)
  response.send_response(client, 204)
end

--- PUT /session/:id/pin: set pin status for session
local function handle_set_pin(client, path, body, content_length)
  local session_id = path:match('^/session/([^/]+)/pin$')
  if not session_id then
    response.send_response(client, 400)
    return
  end

  session_id = url_decode(session_id)

  if not ensure_session_exists(client, session_id) then
    return
  end

  local ok, obj = parse_json_body(client, body, content_length)
  if not ok then
    return
  end

  local pin = obj.pin
  if type(pin) ~= 'boolean' then
    response.send_json(client, 400, { error = 'Missing or invalid pin value' })
    return
  end

  sessions.set_session_pin(session_id, pin)
  response.send_response(client, 204)
end

--- PUT /session/:id/title: set title for session
local function handle_set_title(client, path, body, content_length)
  local session_id = path:match('^/session/([^/]+)/title$')
  if not session_id then
    response.send_response(client, 400)
    return
  end

  session_id = url_decode(session_id)

  if not ensure_session_exists(client, session_id) then
    return
  end

  local ok, obj = parse_json_body(client, body, content_length)
  if not ok then
    return
  end

  local title = obj.title
  if type(title) ~= 'string' then
    response.send_json(client, 400, { error = 'Missing or invalid title value' })
    return
  end

  sessions.set_session_title(session_id, title)
  response.send_response(client, 204)
end

--- POST /session/:id/retry: retry last message
local function handle_retry_session(client, path)
  local session_id = path:match('^/session/([^/]+)/retry$')
  if not session_id then
    response.send_response(client, 400)
    return
  end

  session_id = url_decode(session_id)

  if not ensure_session_exists(client, session_id) then
    return
  end

  if sessions.is_in_progress(session_id) then
    response.send_json(client, 409, { error = 'Session is in progress' })
    return
  end

  local ok, err = sessions.retry(session_id)
  if not ok then
    response.send_json(client, 400, { error = err or 'Retry failed' })
    return
  end

  response.send_response(client, 204)
end

--- DELETE /session/:id/messages/:index: delete a specific message
local function handle_delete_message(client, path)
  local session_id, index_str = path:match('^/session/([^/]+)/messages/(%d+)$')
  if not session_id then
    response.send_response(client, 400)
    return
  end

  session_id = url_decode(session_id)

  if not ensure_session_exists(client, session_id) then
    return
  end

  if sessions.is_in_progress(session_id) then
    response.send_json(client, 409, { error = 'Session is in progress' })
    return
  end

  local index = tonumber(index_str)
  local success = sessions.delete_message(session_id, index)
  if not success then
    response.send_json(client, 400, { error = 'Message index out of range' })
    return
  end

  require('chat.sessions.storage').write_cache(session_id)

  -- Update UI if this is the current window session
  local windows = require('chat.windows')
  if session_id == windows.current_session() then
    local result_win = require('chat.windows.result')
    if result_win.is_buf_valid() then
      result_win.render(session_id)
    end
  end

  response.send_response(client, 204)
end

--- GET /messages?session=session_id&since=index: return message list
local function handle_get_messages(client, path)
  local session_id = path:match('session=([^&]+)')
  if not session_id then
    response.send_response(client, 400)
    return
  end

  session_id = url_decode(session_id)

  if not sessions.exists(session_id) then
    response.send_response(client, 404)
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
end

--- POST /: push message to session (existing behavior)
local function handle_push_message(client, body, content_length)
  local ok, obj = pcall(vim.json.decode, body:sub(1, content_length))
  if not ok or type(obj) ~= 'table' then
    response.send_response(client, 400)
    return
  end

  local session = obj.session
  local content = obj.content

  if type(session) ~= 'string' or type(content) ~= 'string' then
    response.send_response(client, 400)
    return
  end

  require('chat.queue').push(session, content)
  response.send_response(client, 204)
end

--- POST /session/:id/upload: upload file to session upload_dir (or cwd as fallback)
--- Query: ?path=relative/path/to/file.png
--- Or use X-Filename header for the file path
--- Body: raw file content (binary safe)
local function handle_upload_file(client, path, headers, body, content_length)
  -- Extract session ID and optional query string
  local session_id, query = path:match('^/session/([^/]+)/upload%?(.*)$')
  if not session_id then
    session_id = path:match('^/session/([^/]+)/upload$')
    if not session_id then
      response.send_response(client, 400)
      return
    end
  end

  session_id = url_decode(session_id)

  if not ensure_session_exists(client, session_id) then
    return
  end

  -- Get the upload directory: use upload_dir if set, otherwise cwd
  local upload_dir = sessions.get_upload_dir(session_id)
  local all_sessions = sessions.get()
  local session_data = all_sessions[session_id]
  local base_dir = upload_dir or session_data.cwd or vim.fn.getcwd()

  -- Parse file path from query param or X-Filename header
  local file_path = nil
  if query then
    file_path = query:match('path=([^&]+)')
    if file_path then
      file_path = url_decode(file_path)
    end
  end

  -- Fallback to X-Filename header
  if not file_path or file_path == '' then
    file_path = headers['x-filename']
  end

  if not file_path or file_path == '' then
    response.send_json(client, 400, { error = 'Missing file path (use ?path= or X-Filename header)' })
    return
  end

  -- Security: reject path traversal
  if file_path:find('%.%.') then
    response.send_json(client, 403, { error = 'Path traversal not allowed' })
    return
  end

  -- Reject absolute paths (Unix / or Windows C:\)
  if file_path:match('^/') or file_path:match('^%a:[/\\]') then
    response.send_json(client, 403, { error = 'Absolute paths not allowed' })
    return
  end

  -- Build full path and verify it's within base_dir
  local base_normalized = vim.fs.normalize(base_dir)
  local full_path = vim.fs.normalize(base_normalized .. '/' .. file_path)

  -- Verify the full path starts with base_dir (prevents symlink/traversal escape)
  if full_path:sub(1, #base_normalized) ~= base_normalized then
    response.send_json(client, 403, { error = 'Path must be within session upload directory' })
    return
  end

  -- Create parent directories if needed
  local parent_dir = vim.fs.dirname(full_path)
  vim.fn.mkdir(parent_dir, 'p')

  -- Write the file (binary-safe, only content_length bytes)
  local file_data = body:sub(1, content_length)
  local fd, err = io.open(full_path, 'wb')
  if not fd then
    response.send_json(client, 500, { error = 'Failed to write file: ' .. (err or 'unknown') })
    return
  end
  fd:write(file_data)
  fd:close()

  response.send_json(client, 200, {
    path = file_path,
    full_path = full_path,
    size = #file_data,
  })
end

--------------------------------------------------
-- Main dispatcher
--------------------------------------------------

--- Handle HTTP request (separated for vim.schedule_wrap)
function M.handle_request(client, method, path, headers, body, content_length)
  -- GET /session?id=...: HTML preview (no auth required)
  if method == 'GET' and path:match('^/session%?') then
    handle_session_preview(client, path)
    return
  end

  -- API key check (use header: X-API-Key)
  if headers['x-api-key'] ~= config.config.http.api_key then
    response.send_response(client, 401)
    return
  end

  -- Route handling
  if method == 'GET' and path == '/sessions' then
    handle_list_sessions(client)
  elseif method == 'GET' and path:match('^/sessions/[^/]+/raw$') then
    handle_get_session_raw(client, path)
  elseif method == 'GET' and path:match('^/sessions/[^/]+$') then
    handle_get_session(client, path)
  elseif method == 'GET' and path == '/providers' then
    handle_list_providers(client)
  elseif method == 'POST' and path == '/session/new' then
    handle_new_session(client, body, content_length)
  elseif method == 'DELETE' and path:match('^/session/[^/]+$') then
    handle_delete_session(client, path)
  elseif method == 'POST' and path:match('^/session/[^/]+/stop$') then
    handle_stop_session(client, path)
  elseif method == 'POST' and path:match('^/session/[^/]+/clear$') then
    handle_clear_session(client, path)
  elseif method == 'PUT' and path:match('^/session/[^/]+/provider$') then
    handle_set_provider(client, path, body, content_length)
  elseif method == 'PUT' and path:match('^/session/[^/]+/model$') then
    handle_set_model(client, path, body, content_length)
  elseif method == 'PUT' and path:match('^/session/[^/]+/cwd$') then
    handle_set_cwd(client, path, body, content_length)
  elseif method == 'GET' and path:match('^/session/[^/]+/upload%-dir$') then
    handle_get_upload_dir(client, path)
  elseif method == 'PUT' and path:match('^/session/[^/]+/upload%-dir$') then
    handle_set_upload_dir(client, path, body, content_length)
  elseif method == 'PUT' and path:match('^/session/[^/]+/pin$') then
    handle_set_pin(client, path, body, content_length)
  elseif method == 'PUT' and path:match('^/session/[^/]+/title$') then
    handle_set_title(client, path, body, content_length)
  elseif method == 'POST' and path:match('^/session/[^/]+/retry$') then
    handle_retry_session(client, path)
  elseif method == 'DELETE' and path:match('^/session/[^/]+/messages/%d+$') then
    handle_delete_message(client, path)
  elseif method == 'GET' and path:match('^/messages%?') then
    handle_get_messages(client, path)
  elseif method == 'POST' and path:match('^/session/[^/]+/upload') then
    handle_upload_file(client, path, headers, body, content_length)
  elseif method == 'POST' and path == '/' then
    handle_push_message(client, body, content_length)
  else
    response.send_response(client, 404)
  end
end

return M

