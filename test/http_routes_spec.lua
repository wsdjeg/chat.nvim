-- Direct dispatch coverage for lua/chat/http/routes.lua
-- Calls routes.handle_request with a fake uv client.
local lu = require('luaunit')
local routes = require('chat.http.routes')
local sessions = require('chat.sessions')
local config = require('chat.config')

local real_windows = package.loaded['chat.windows'] or require('chat.windows')
local real_protocol = package.loaded['chat.protocol'] or require('chat.protocol')

local function make_client()
  return {
    written = {},
    closed = false,
    is_closing = function()
      return false
    end,
    write = function(self, data, cb)
      self.written[#self.written + 1] = data
      if cb then
        cb()
      end
      return true
    end,
    close = function(self)
      self.closed = true
    end,
  }
end

--- Dispatch a request, return (client, status_code, body_text)
local function req(method, path, body, extra_headers)
  body = body or ''
  local headers = vim.tbl_extend('force', {
    ['x-api-key'] = 'routes-test-key',
  }, extra_headers or {})
  local c = make_client()
  routes.handle_request(c, method, path, headers, body, #body)
  if #c.written == 0 then
    return c, nil, nil
  end
  local head, body_text = c.written[1]:match('^(.-)\r\n\r\n(.*)$')
  local status = tonumber(head:match('^HTTP/1%.1 (%d+)'))
  return c, status, body_text
end

TestHTTPRoutes = {}

local test_storage_dir
local test_cache_dir
local upload_root

function TestHTTPRoutes:setUp()
  test_storage_dir = vim.fn.tempname() .. '_routes_test/'
  vim.fn.mkdir(test_storage_dir, 'p')
  config.setup({
    storage_dir = test_storage_dir,
    http = {
      enabled = true,
      host = '127.0.0.1',
      port = 9877,
      api_key = 'routes-test-key',
    },
    memory = {
      enable = true,
      storage_dir = test_storage_dir .. 'memory/',
    },
  })

  test_cache_dir = vim.fn.tempname() .. '/'
  sessions.set_cache_dir(test_cache_dir)

  -- upload area inside cwd (allowed_path) for upload tests
  upload_root = vim.fn.getcwd() .. '/.tmp_upload_test_' .. os.time() .. '_' .. math.random(1000, 9999)
  vim.fn.mkdir(upload_root, 'p')
  config.config.allowed_path = vim.fn.getcwd()

  -- Stub windows so session ops don't touch real UI
  package.loaded['chat.windows'] = {
    is_open = function()
      return false
    end,
    open = function() end,
    current_session = function()
      return ''
    end,
    render_result_buf = function() end,
    set_result_win_title = function() end,
    send_message = function()
      return true -- treat queue pushes as handled
    end,
    on_message = function() end,
  }

  self.sid = sessions.new()
end

function TestHTTPRoutes:tearDown()
  package.loaded['chat.windows'] = real_windows
  package.loaded['chat.protocol'] = real_protocol
  config.config.allowed_path = vim.fn.getcwd()
  vim.fn.delete(test_cache_dir, 'rf')
  if test_storage_dir and vim.fn.isdirectory(test_storage_dir) == 1 then
    vim.fn.delete(test_storage_dir, 'rf')
  end
  if upload_root and vim.fn.isdirectory(upload_root) == 1 then
    vim.fn.delete(upload_root, 'rf')
  end
end

local function wait_for_write(c)
  vim.wait(1000, function()
    return #c.written > 0
  end, 20)
end

-- ─── auth ───────────────────────────────────────────────

function TestHTTPRoutes:test_auth_required()
  local c = make_client()
  routes.handle_request(c, 'GET', '/sessions', {}, '', 0)
  lu.assertTrue(#c.written > 0)
  lu.assertStrContains(c.written[1], '401')
end

function TestHTTPRoutes:test_unknown_route_404()
  local _, status = req('GET', '/nope')
  lu.assertEquals(status, 404)
end

-- ─── GET /sessions ──────────────────────────────────────

function TestHTTPRoutes:test_list_sessions()
  sessions.set_session_title(self.sid, 'My Title')
  sessions.append_message(self.sid, {
    role = 'user',
    content = string.rep('x', 200),
    created = os.time(),
  })
  local _, status, body = req('GET', '/sessions')
  lu.assertEquals(status, 200)
  local data = vim.json.decode(body)
  local mine = vim.tbl_filter(function(s)
    return s.id == self.sid
  end, data)
  lu.assertEquals(#mine, 1)
  lu.assertEquals(mine[1].title, 'My Title')
  lu.assertEquals(mine[1].message_count, 1)
  lu.assertStrContains(mine[1].last_message.content, '...')
  -- pin defaults to false; in_progress is nil-or-boolean
  lu.assertFalse(mine[1].pin)
  lu.assertNil(mine[1].in_progress)
end

function TestHTTPRoutes:test_list_sessions_title_from_first_user()
  local sid2 = sessions.new()
  sessions.append_message(sid2, {
    role = 'user',
    content = string.rep('y', 80),
    created = os.time(),
  })
  local _, status, body = req('GET', '/sessions')
  lu.assertEquals(status, 200)
  local data = vim.json.decode(body)
  local mine = vim.tbl_filter(function(s)
    return s.id == sid2
  end, data)
  lu.assertEquals(#mine[1].title, 53, 'title truncated to 50 + ...')
  lu.assertStrContains(mine[1].title, '...')
end

-- ─── GET /sessions/:id ──────────────────────────────────

function TestHTTPRoutes:test_get_session()
  local _, status, body = req('GET', '/sessions/' .. self.sid)
  lu.assertEquals(status, 200)
  local data = vim.json.decode(body)
  lu.assertEquals(data.id, self.sid)
  lu.assertEquals(data.message_count, 0)
  lu.assertNil(data.last_message)
end

function TestHTTPRoutes:test_get_session_404()
  local _, status = req('GET', '/sessions/does-not-exist')
  lu.assertEquals(status, 404)
end

-- ─── GET /sessions/:id/raw ──────────────────────────────

function TestHTTPRoutes:test_get_session_raw()
  sessions.append_message(self.sid, {
    role = 'user',
    content = 'cached',
    created = os.time(),
  })
  sessions.write_cache(self.sid)
  local c = make_client()
  routes.handle_request(c, 'GET', '/sessions/' .. self.sid .. '/raw', {
    ['x-api-key'] = 'routes-test-key',
  }, '', 0)
  wait_for_write(c)
  lu.assertTrue(#c.written > 0, 'async read should respond')
  lu.assertStrContains(c.written[1], '200')
  lu.assertStrContains(c.written[1], 'cached')
end

function TestHTTPRoutes:test_get_session_raw_missing_file()
  -- session exists but cache file was never written -> 404
  local c = make_client()
  routes.handle_request(c, 'GET', '/sessions/' .. self.sid .. '/raw', {
    ['x-api-key'] = 'routes-test-key',
  }, '', 0)
  wait_for_write(c)
  lu.assertTrue(#c.written > 0)
  lu.assertStrContains(c.written[1], '404')
end

-- ─── GET /providers and /skills ─────────────────────────

function TestHTTPRoutes:test_list_providers()
  local _, status, body = req('GET', '/providers')
  lu.assertEquals(status, 200)
  local data = vim.json.decode(body)
  lu.assertTrue(#data > 0, 'provider files found')
  -- sorted
  for i = 2, #data do
    lu.assertTrue(data[i - 1].name <= data[i].name, 'sorted by name')
  end
end

function TestHTTPRoutes:test_list_skills()
  local _, status, body = req('GET', '/skills')
  lu.assertEquals(status, 200)
  local data = vim.json.decode(body)
  lu.assertTrue(#data > 0)
  lu.assertEquals(type(data[1].name), 'string')
end

-- ─── POST /session/new ──────────────────────────────────

function TestHTTPRoutes:test_new_session_default()
  local _, status, body = req('POST', '/session/new', '')
  lu.assertEquals(status, 200)
  local data = vim.json.decode(body)
  lu.assertTrue(sessions.exists(data.id))
  lu.assertEquals(data.message_count, 0)
end

function TestHTTPRoutes:test_new_session_with_provider_model()
  local _, status, body = req(
    'POST',
    '/session/new',
    '{"provider":"openai","model":"gpt-4o"}'
  )
  lu.assertEquals(status, 200)
  local data = vim.json.decode(body)
  lu.assertEquals(data.provider, 'openai')
  lu.assertEquals(data.model, 'gpt-4o')
end

function TestHTTPRoutes:test_new_session_invalid_body_ignored()
  local _, status, body = req('POST', '/session/new', 'not-json{')
  lu.assertEquals(status, 200)
  local data = vim.json.decode(body)
  lu.assertTrue(sessions.exists(data.id))
end

function TestHTTPRoutes:test_new_session_empty_fields_ignored()
  local _, status, body = req('POST', '/session/new', '{"provider":"","model":42}')
  lu.assertEquals(status, 200)
  local data = vim.json.decode(body)
  -- empty/wrong-typed fields ignored, default provider retained
  lu.assertEquals(data.provider, 'test-provider')
end

-- ─── DELETE /session/:id ────────────────────────────────

function TestHTTPRoutes:test_delete_session()
  local sid = sessions.new()
  local _, status = req('DELETE', '/session/' .. sid)
  lu.assertEquals(status, 204)
  lu.assertFalse(sessions.exists(sid))
end

function TestHTTPRoutes:test_delete_session_404()
  local _, status = req('DELETE', '/session/ghost')
  lu.assertEquals(status, 404)
end

function TestHTTPRoutes:test_delete_session_in_progress_409()
  local progress = require('chat.sessions.progress')
  progress.set_session_jobid(self.sid, 99999)
  local _, status, body = req('DELETE', '/session/' .. self.sid)
  lu.assertEquals(status, 409)
  lu.assertStrContains(body, 'in progress')
  progress.on_progress_exit(99999, 0, 0)
end

-- ─── POST /session/:id/stop ─────────────────────────────

function TestHTTPRoutes:test_stop_session()
  local _, status = req('POST', '/session/' .. self.sid .. '/stop', '')
  lu.assertEquals(status, 204)
end

function TestHTTPRoutes:test_stop_session_404()
  local _, status = req('POST', '/session/ghost/stop', '')
  lu.assertEquals(status, 404)
end

-- ─── POST /session/:id/clear ────────────────────────────

function TestHTTPRoutes:test_clear_session()
  sessions.append_message(self.sid, {
    role = 'user',
    content = 'x',
    created = os.time(),
  })
  local _, status = req('POST', '/session/' .. self.sid .. '/clear', '')
  lu.assertEquals(status, 204)
  lu.assertEquals(#sessions.get_messages(self.sid), 0)
end

function TestHTTPRoutes:test_clear_session_404()
  local _, status = req('POST', '/session/ghost/clear', '')
  lu.assertEquals(status, 404)
end

function TestHTTPRoutes:test_clear_session_in_progress_409()
  local progress = require('chat.sessions.progress')
  progress.set_session_jobid(self.sid, 99998)
  local _, status = req('POST', '/session/' .. self.sid .. '/clear', '')
  lu.assertEquals(status, 409)
  progress.on_progress_exit(99998, 0, 0)
end

-- ─── PUT /session/:id/provider ──────────────────────────

function TestHTTPRoutes:test_set_provider()
  local _, status = req(
    'PUT',
    '/session/' .. self.sid .. '/provider',
    '{"provider":"anthropic"}'
  )
  lu.assertEquals(status, 204)
  lu.assertEquals(sessions.get_session_provider(self.sid), 'anthropic')
end

function TestHTTPRoutes:test_set_provider_404()
  local _, status = req('PUT', '/session/ghost/provider', '{"provider":"x"}')
  lu.assertEquals(status, 404)
end

function TestHTTPRoutes:test_set_provider_invalid_json()
  local _, status = req('PUT', '/session/' .. self.sid .. '/provider', '{bad')
  lu.assertEquals(status, 400)
end

function TestHTTPRoutes:test_set_provider_missing()
  local _, status = req('PUT', '/session/' .. self.sid .. '/provider', '{}')
  lu.assertEquals(status, 400)
end

function TestHTTPRoutes:test_set_provider_wrong_type()
  local _, status = req(
    'PUT',
    '/session/' .. self.sid .. '/provider',
    '{"provider":123}'
  )
  lu.assertEquals(status, 400)
end

-- ─── PUT /session/:id/model ─────────────────────────────

function TestHTTPRoutes:test_set_model()
  local _, status = req(
    'PUT',
    '/session/' .. self.sid .. '/model',
    '{"model":"gpt-4o-mini"}'
  )
  lu.assertEquals(status, 204)
  lu.assertEquals(sessions.get_session_model(self.sid), 'gpt-4o-mini')
end

function TestHTTPRoutes:test_set_model_missing()
  local _, status = req('PUT', '/session/' .. self.sid .. '/model', '{}')
  lu.assertEquals(status, 400)
end

-- ─── PUT /session/:id/cwd ───────────────────────────────

function TestHTTPRoutes:test_set_cwd()
  local target = upload_root
  local _, status = req(
    'PUT',
    '/session/' .. self.sid .. '/cwd',
    vim.json.encode({ cwd = target })
  )
  lu.assertEquals(status, 204)
  lu.assertEquals(sessions.getcwd(self.sid), vim.fs.normalize(target))
end

function TestHTTPRoutes:test_set_cwd_missing()
  local _, status = req('PUT', '/session/' .. self.sid .. '/cwd', '{}')
  lu.assertEquals(status, 400)
end

-- ─── upload-dir ─────────────────────────────────────────

function TestHTTPRoutes:test_get_upload_dir_default()
  local _, status, body = req('GET', '/session/' .. self.sid .. '/upload-dir')
  lu.assertEquals(status, 200)
  local data = vim.json.decode(body)
  -- documented behavior: null when not set (uploads use cwd)
  lu.assertNil(data.upload_dir)
end

function TestHTTPRoutes:test_set_upload_dir_ok()
  local dir = upload_root .. '/sub'
  vim.fn.mkdir(dir, 'p')
  sessions.change_cwd(self.sid, upload_root)
  local _, status = req(
    'PUT',
    '/session/' .. self.sid .. '/upload-dir',
    vim.json.encode({ upload_dir = dir })
  )
  lu.assertEquals(status, 204)
  lu.assertEquals(sessions.get_upload_dir(self.sid), vim.fs.normalize(dir))
end

function TestHTTPRoutes:test_set_upload_dir_reset_null()
  local _, status = req(
    'PUT',
    '/session/' .. self.sid .. '/upload-dir',
    '{"upload_dir":null}'
  )
  lu.assertEquals(status, 204)
end

function TestHTTPRoutes:test_set_upload_dir_wrong_type()
  local _, status = req(
    'PUT',
    '/session/' .. self.sid .. '/upload-dir',
    '{"upload_dir":42}'
  )
  lu.assertEquals(status, 400)
end

function TestHTTPRoutes:test_set_upload_dir_relative_rejected()
  local _, status, body = req(
    'PUT',
    '/session/' .. self.sid .. '/upload-dir',
    '{"upload_dir":"relative/path"}'
  )
  lu.assertEquals(status, 400)
  lu.assertStrContains(body, 'absolute')
end

function TestHTTPRoutes:test_set_upload_dir_outside_allowed()
  local outside = vim.fn.tempname() .. '_outside'
  vim.fn.mkdir(outside, 'p')
  local _, status, body = req(
    'PUT',
    '/session/' .. self.sid .. '/upload-dir',
    vim.json.encode({ upload_dir = outside })
  )
  lu.assertEquals(status, 400)
  lu.assertStrContains(body, 'allowed_path')
  vim.fn.delete(outside, 'rf')
end

function TestHTTPRoutes:test_set_upload_dir_outside_session_cwd()
  -- inside allowed_path (repo cwd) but outside the session cwd
  local other = vim.fn.getcwd() .. '/.tmp_other_dir_' .. os.time()
  vim.fn.mkdir(other, 'p')
  sessions.change_cwd(self.sid, upload_root)
  local _, status, body = req(
    'PUT',
    '/session/' .. self.sid .. '/upload-dir',
    vim.json.encode({ upload_dir = other })
  )
  lu.assertEquals(status, 400)
  lu.assertStrContains(body, 'session cwd')
  vim.fn.delete(other, 'rf')
end

function TestHTTPRoutes:test_set_upload_dir_not_a_directory()
  local fake = upload_root .. '/missing-dir'
  sessions.change_cwd(self.sid, upload_root)
  local _, status, body = req(
    'PUT',
    '/session/' .. self.sid .. '/upload-dir',
    vim.json.encode({ upload_dir = fake })
  )
  lu.assertEquals(status, 400)
  lu.assertStrContains(body, 'does not exist')
end

-- ─── pin / title ────────────────────────────────────────

function TestHTTPRoutes:test_set_pin()
  local _, status = req('PUT', '/session/' .. self.sid .. '/pin', '{"pin":true}')
  lu.assertEquals(status, 204)
  lu.assertTrue(sessions.get_session_pin(self.sid))
end

function TestHTTPRoutes:test_set_pin_invalid()
  local _, status = req('PUT', '/session/' .. self.sid .. '/pin', '{"pin":"yes"}')
  lu.assertEquals(status, 400)
end

function TestHTTPRoutes:test_set_title()
  local _, status = req(
    'PUT',
    '/session/' .. self.sid .. '/title',
    '{"title":"Chat about tests"}'
  )
  lu.assertEquals(status, 204)
  lu.assertEquals(sessions.get_session_title(self.sid), 'Chat about tests')
end

function TestHTTPRoutes:test_set_title_invalid()
  local _, status = req('PUT', '/session/' .. self.sid .. '/title', '{"title":1}')
  lu.assertEquals(status, 400)
end

-- ─── POST /session/:id/retry ────────────────────────────

function TestHTTPRoutes:test_retry_success()
  package.loaded['chat.protocol'] = {
    request = function()
      return 77
    end,
  }
  sessions.append_message(self.sid, {
    role = 'user',
    content = 'retry me',
    created = os.time(),
  })
  local _, status = req('POST', '/session/' .. self.sid .. '/retry', '')
  lu.assertEquals(status, 204)
end

function TestHTTPRoutes:test_retry_empty_messages_400()
  local _, status, body = req('POST', '/session/' .. self.sid .. '/retry', '')
  lu.assertEquals(status, 400)
  lu.assertStrContains(body, 'Retry failed')
end

-- ─── DELETE /session/:id/messages/:index ────────────────

function TestHTTPRoutes:test_delete_message()
  sessions.append_message(self.sid, { role = 'user', content = 'a', created = os.time() })
  sessions.append_message(self.sid, { role = 'assistant', content = 'b', created = os.time() })
  local _, status = req('DELETE', '/session/' .. self.sid .. '/messages/1')
  lu.assertEquals(status, 204)
  lu.assertEquals(#sessions.get_messages(self.sid), 1)
end

function TestHTTPRoutes:test_delete_message_out_of_range()
  local _, status, body = req('DELETE', '/session/' .. self.sid .. '/messages/9')
  lu.assertEquals(status, 400)
  lu.assertStrContains(body, 'out of range')
end

function TestHTTPRoutes:test_delete_message_404()
  local _, status = req('DELETE', '/session/ghost/messages/1')
  lu.assertEquals(status, 404)
end

-- ─── GET /messages ──────────────────────────────────────

function TestHTTPRoutes:test_get_messages()
  sessions.append_message(self.sid, { role = 'user', content = 'm1', created = os.time() })
  sessions.append_message(self.sid, { role = 'assistant', content = 'm2', created = os.time() })
  local _, status, body = req('GET', '/messages?session=' .. self.sid)
  lu.assertEquals(status, 200)
  local data = vim.json.decode(body)
  lu.assertEquals(#data, 2)
end

function TestHTTPRoutes:test_get_messages_since()
  sessions.append_message(self.sid, { role = 'user', content = 'm1', created = os.time() })
  sessions.append_message(self.sid, { role = 'assistant', content = 'm2', created = os.time() })
  local _, status, body = req('GET', '/messages?session=' .. self.sid .. '&since=2')
  lu.assertEquals(status, 200)
  local data = vim.json.decode(body)
  lu.assertEquals(#data, 1)
  lu.assertEquals(data[1].content, 'm2')
end

function TestHTTPRoutes:test_get_messages_since_beyond_range()
  sessions.append_message(self.sid, { role = 'user', content = 'm1', created = os.time() })
  local _, status, body = req('GET', '/messages?session=' .. self.sid .. '&since=99')
  lu.assertEquals(status, 200)
  lu.assertEquals(vim.json.decode(body), {})
end

function TestHTTPRoutes:test_get_messages_since_invalid_ignored()
  sessions.append_message(self.sid, { role = 'user', content = 'm1', created = os.time() })
  -- since=0 fails %d+ -> no since param -> all messages
  local _, status, body = req('GET', '/messages?session=' .. self.sid .. '&since=0')
  lu.assertEquals(status, 200)
  lu.assertEquals(#vim.json.decode(body), 1)
end

function TestHTTPRoutes:test_get_messages_404()
  local _, status = req('GET', '/messages?session=ghost')
  lu.assertEquals(status, 404)
end

-- ─── POST / push message ────────────────────────────────

function TestHTTPRoutes:test_push_message()
  local push_sid = 'push-target-' .. tostring(math.random(100000))
  local _, status = req('POST', '/', '{"session":"' .. push_sid .. '","content":"hi"}')
  lu.assertEquals(status, 204)
  vim.wait(200, function()
    return false
  end, 20)
end

function TestHTTPRoutes:test_push_message_invalid_json()
  local _, status = req('POST', '/', 'garbage')
  lu.assertEquals(status, 400)
end

function TestHTTPRoutes:test_push_message_missing_fields()
  local _, status = req('POST', '/', '{"session":"x"}')
  lu.assertEquals(status, 400)
end

-- ─── GET /session?id= (preview) ─────────────────────────

function TestHTTPRoutes:test_session_preview()
  sessions.append_message(self.sid, { role = 'user', content = 'preview me', created = os.time() })
  local _, status, body = req('GET', '/session?id=' .. self.sid, '', {})
  lu.assertEquals(status, 200)
  lu.assertStrContains(body, '<!DOCTYPE html>')
  lu.assertStrContains(body, 'preview me')
end

function TestHTTPRoutes:test_session_preview_no_id_400()
  local _, status = req('GET', '/session?', '', {})
  lu.assertEquals(status, 400)
end

function TestHTTPRoutes:test_session_preview_unknown_404()
  local _, status = req('GET', '/session?id=ghost-session', '', {})
  lu.assertEquals(status, 404)
end

-- ─── POST /session/:id/upload ───────────────────────────

function TestHTTPRoutes:test_upload_file_query_path()
  sessions.change_cwd(self.sid, upload_root)
  local _, status, body = req(
    'POST',
    '/session/' .. self.sid .. '/upload?path=sub/hello.txt',
    'file-content'
  )
  lu.assertEquals(status, 200)
  local data = vim.json.decode(body)
  lu.assertEquals(data.size, #'file-content')
  lu.assertTrue(vim.fn.filereadable(upload_root .. '/sub/hello.txt') == 1)
end

function TestHTTPRoutes:test_upload_file_header_path()
  sessions.change_cwd(self.sid, upload_root)
  local _, status = req(
    'POST',
    '/session/' .. self.sid .. '/upload',
    'data',
    { ['x-filename'] = 'hdr.bin' }
  )
  lu.assertEquals(status, 200)
  lu.assertTrue(vim.fn.filereadable(upload_root .. '/hdr.bin') == 1)
end

function TestHTTPRoutes:test_upload_file_404()
  local _, status = req('POST', '/session/ghost/upload?path=a.txt', 'x')
  lu.assertEquals(status, 404)
end

function TestHTTPRoutes:test_upload_missing_path_400()
  sessions.change_cwd(self.sid, upload_root)
  local _, status, body = req('POST', '/session/' .. self.sid .. '/upload', 'x')
  lu.assertEquals(status, 400)
  lu.assertStrContains(body, 'Missing file path')
end

function TestHTTPRoutes:test_upload_traversal_403()
  sessions.change_cwd(self.sid, upload_root)
  local _, status, body = req(
    'POST',
    '/session/' .. self.sid .. '/upload?path=../evil.txt',
    'x'
  )
  lu.assertEquals(status, 403)
  lu.assertStrContains(body, 'traversal')
end

function TestHTTPRoutes:test_upload_absolute_path_403()
  sessions.change_cwd(self.sid, upload_root)
  local _, status, body = req(
    'POST',
    '/session/' .. self.sid .. '/upload?path=' .. vim.fn.tempname() .. '/evil.txt',
    'x'
  )
  lu.assertEquals(status, 403)
  lu.assertStrContains(body, 'Absolute')
end

-- ─── bridge routes ──────────────────────────────────────

function TestHTTPRoutes:test_bridge_unknown_platform_400()
  local _, status, body = req('PUT', '/session/' .. self.sid .. '/bridge/nosuch')
  lu.assertEquals(status, 400)
  lu.assertStrContains(body, 'Unknown integration')
end

function TestHTTPRoutes:test_get_bridges_empty()
  local _, status, body = req('GET', '/session/' .. self.sid .. '/bridge')
  lu.assertEquals(status, 200)
  local data = vim.json.decode(body)
  lu.assertEquals(data.bridges, {})
end

function TestHTTPRoutes:test_unbridge_unknown_platform_400()
  local _, status = req('DELETE', '/session/' .. self.sid .. '/bridge/nosuch')
  lu.assertEquals(status, 400)
end

function TestHTTPRoutes:test_unbridge_specific_not_bound_404()
  local _, status = req('DELETE', '/session/' .. self.sid .. '/bridge/nosuch2')
  lu.assertEquals(status, 400)
end

function TestHTTPRoutes:test_unbridge_all_204()
  local _, status = req('DELETE', '/session/' .. self.sid .. '/bridge')
  lu.assertEquals(status, 204)
end

function TestHTTPRoutes:test_get_bridges_404()
  local _, status = req('GET', '/session/ghost/bridge')
  lu.assertEquals(status, 404)
end

-- ─── weixin routes ──────────────────────────────────────

function TestHTTPRoutes:test_weixin_login_status_starts_flow()
  -- No credentials + no state -> starts login flow via job mock, returns init
  local _, status, body = req('GET', '/weixin/login/status')
  lu.assertEquals(status, 200)
  lu.assertStrContains(body, 'status')
end

function TestHTTPRoutes:test_weixin_logout()
  local _, status, body = req('DELETE', '/weixin/credentials')
  lu.assertEquals(status, 200)
  lu.assertStrContains(body, 'logged_out')
end

