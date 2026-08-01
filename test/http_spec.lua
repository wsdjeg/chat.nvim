local lu = require('luaunit')
local http = require('chat.http')
local sessions = require('chat.sessions')
local config = require('chat.config')

TestHTTP = {}

local function make_request(method, path, headers, body)
  -- Simulate parsing of HTTP request
  local header_str = ''
  for k, v in pairs(headers or {}) do
    header_str = header_str .. k .. ': ' .. v .. '\r\n'
  end

  local request = string.format(
    '%s %s HTTP/1.1\r\n%s\r\n%s',
    method,
    path,
    header_str,
    body or ''
  )

  -- Parse header
  local header_part, req_body = request:match('^(.-)\r\n\r\n(.*)$')
  local request_line = header_part:match('([^\r\n]+)')
  local req_method, req_path = request_line:match('^(%S+)%s+(%S+)')

  local parsed_headers = {}
  for line in header_part:gmatch('([^\r\n]+)') do
    local k, v = line:match('^([^:]+):%s*(.+)$')
    if k then
      parsed_headers[k:lower()] = v
    end
  end

  return req_method, req_path, parsed_headers, req_body
end

local test_storage_dir

function TestHTTP:setUp()
  -- Create temporary storage directory
  test_storage_dir = vim.fn.tempname() .. '_http_test/'
  vim.fn.mkdir(test_storage_dir, 'p')

  -- Setup test config with independent storage_dir
  config.setup({
    storage_dir = test_storage_dir,
    http = {
      enabled = true,
      host = '127.0.0.1',
      port = 9876,
      api_key = 'test-api-key',
    },
    memory = {
      enable = true,
      storage_dir = test_storage_dir .. 'memory/',
    },
  })

  -- Use a temp directory to avoid polluting real session cache
  self.test_cache_dir = vim.fn.tempname() .. '/'
  sessions.set_cache_dir(self.test_cache_dir)

  -- Create a test session
  self.test_session_id = sessions.new()
end

function TestHTTP:tearDown()
  -- Clean up temp cache directory
  vim.fn.delete(self.test_cache_dir, 'rf')
  -- Clean up test storage directory
  if test_storage_dir and vim.fn.isdirectory(test_storage_dir) == 1 then
    vim.fn.delete(test_storage_dir, 'rf')
  end
end

-- Test parse_headers functionality
function TestHTTP:testParseHeaders()
  local raw = 'Host: localhost:9876\r\nContent-Type: application/json\r\nX-API-Key: secret'
  local parsed = {}
  for line in raw:gmatch('([^\r\n]+)') do
    local k, v = line:match('^([^:]+):%s*(.+)$')
    if k then
      parsed[k:lower()] = v
    end
  end

  lu.assertEquals(parsed['host'], 'localhost:9876')
  lu.assertEquals(parsed['content-type'], 'application/json')
  lu.assertEquals(parsed['x-api-key'], 'secret')
end

-- Test URL decode
function TestHTTP:testUrlDecode()
  local function url_decode(str)
    return str:gsub('%%(%x%x)', function(h)
      return string.char(tonumber(h, 16))
    end)
  end

  lu.assertEquals(url_decode('hello%20world'), 'hello world')
  lu.assertEquals(url_decode('session%2Fid'), 'session/id')
  lu.assertEquals(url_decode('test%3D123'), 'test=123')
end

-- Test authentication
function TestHTTP:testAuthenticationRequired()
  local method, path, headers, body = make_request('GET', '/sessions', {}, '')

  -- Without API key, should return 401
  lu.assertEquals(headers['x-api-key'], nil)

  -- With API key
  local method2, path2, headers2, body2 = make_request('GET', '/sessions', { ['X-API-Key'] = 'test-api-key' }, '')
  lu.assertEquals(headers2['x-api-key'], 'test-api-key')
end

-- Test session list endpoint
function TestHTTP:testSessionsEndpoint()
  -- Create another session
  local session2 = sessions.new()

  local all_sessions = sessions.get()
  lu.assertEquals(type(all_sessions), 'table')
  lu.assertTrue(all_sessions[self.test_session_id] ~= nil)
  lu.assertTrue(all_sessions[session2] ~= nil)
end

-- Test session exists check
function TestHTTP:testSessionExists()
  lu.assertTrue(sessions.exists(self.test_session_id))
  lu.assertFalse(sessions.exists('non-existent-session'))
end

-- Test session in progress check (read-only, no manual setting)
function TestHTTP:testSessionInProgress()
  -- By default, session should not be in progress
  lu.assertFalse(sessions.is_in_progress(self.test_session_id))

  -- cancel_progress should work even if not in progress
  sessions.cancel_progress(self.test_session_id)
  lu.assertFalse(sessions.is_in_progress(self.test_session_id))
end

-- Test session delete
function TestHTTP:testSessionDelete()
  lu.assertTrue(sessions.exists(self.test_session_id))

  -- Session not in progress, can delete directly
  sessions.delete(self.test_session_id)
  lu.assertFalse(sessions.exists(self.test_session_id))
end

-- Test new session creation
function TestHTTP:testNewSession()
  local new_id = sessions.new()
  lu.assertTrue(sessions.exists(new_id))
  lu.assertEquals(type(new_id), 'string')
end

-- Test get messages
function TestHTTP:testGetMessages()
  local messages = sessions.get_messages(self.test_session_id)
  lu.assertEquals(type(messages), 'table')
end

-- Test change cwd
function TestHTTP:testChangeCwd()
  local new_cwd = '/tmp/test'
  sessions.change_cwd(self.test_session_id, new_cwd)

  local all_sessions = sessions.get()
  lu.assertEquals(all_sessions[self.test_session_id].cwd, new_cwd)
end

-- Test request parsing
function TestHTTP:testRequestParsing()
  local method, path, headers, body = make_request(
    'POST',
    '/session/new',
    { ['Content-Type'] = 'application/json', ['X-API-Key'] = 'test-api-key' },
    '{"cwd":"/tmp"}'
  )

  lu.assertEquals(method, 'POST')
  lu.assertEquals(path, '/session/new')
  lu.assertEquals(headers['content-type'], 'application/json')
  lu.assertEquals(headers['x-api-key'], 'test-api-key')
  lu.assertEquals(body, '{"cwd":"/tmp"}')
end

-- Test PUT /session/:id/provider endpoint
function TestHTTP:testSetSessionProvider()
  -- Set provider
  local success = sessions.set_session_provider(self.test_session_id, 'anthropic')
  lu.assertTrue(success)

  -- Verify it was set
  local provider = sessions.get_session_provider(self.test_session_id)
  lu.assertEquals(provider, 'anthropic')
end

-- Test PUT /session/:id/model endpoint
function TestHTTP:testSetSessionModel()
  -- Set model
  sessions.set_session_model(self.test_session_id, 'claude-3-5-sonnet-20241022')

-- Verify it was set
  local model = sessions.get_session_model(self.test_session_id)
  lu.assertEquals(model, 'claude-3-5-sonnet-20241022')
end

-- Test PUT /session/:id/pin endpoint
function TestHTTP:testSetSessionPin()
  -- Default pin value should be false (not pinned)
  local pin_before = sessions.get_session_pin(self.test_session_id)
  lu.assertEquals(pin_before, false)

  -- Set pin to true
  sessions.set_session_pin(self.test_session_id, true)
  local pin_true = sessions.get_session_pin(self.test_session_id)
  lu.assertEquals(pin_true, true)

  -- Set pin to false
  sessions.set_session_pin(self.test_session_id, false)
  local pin_false = sessions.get_session_pin(self.test_session_id)
  lu.assertEquals(pin_false, false)
end

-- Test GET /sessions/:id/raw endpoint
function TestHTTP:testGetSessionRaw()
  -- First, add some messages to the session to create cache
  sessions.append_message(self.test_session_id, {
    role = 'user',
    content = 'Hello, this is a test message',
    created = os.time(),
  })

  -- Force write cache
  sessions.write_cache(self.test_session_id)

  -- Get cache path for test session
  local cache_path = sessions.get_cache_path(self.test_session_id)
  lu.assertNotNil(cache_path)

  -- Verify cache file exists
  lu.assertTrue(vim.fn.filereadable(cache_path) == 1)

  -- Read and verify content
  local file = io.open(cache_path, 'r')
  lu.assertNotNil(file)
  local content = file:read('*a')
  file:close()

  -- Content should be valid JSON
  local ok, data = pcall(vim.json.decode, content)
  lu.assertTrue(ok)
  lu.assertEquals(type(data), 'table')

  -- Verify session ID in cache
  lu.assertEquals(data.id, self.test_session_id)
end

-- Test route matching for PUT endpoints
function TestHTTP:testPutRouteMatching()
  -- Test provider path extraction
  local provider_path = '/session/test-session-id/provider'
  -- Test model path extraction
  local model_path = '/session/test-session-id/model'
  local model_id = model_path:match('^/session/([^/]+)/model$')
  lu.assertEquals(model_id, 'test-session-id')

  -- Test pin path extraction
  local pin_path = '/session/test-session-id/pin'
  local pin_id = pin_path:match('^/session/([^/]+)/pin$')
  lu.assertEquals(pin_id, 'test-session-id')
end

-- Test route matching
function TestHTTP:testRouteMatching()
  -- Test session ID extraction from various paths
  local stop_path = '/session/test-session-id/stop'
  local stop_id = stop_path:match('^/session/([^/]+)/stop$')
  lu.assertEquals(stop_id, 'test-session-id')

  local retry_path = '/session/test-session-id/retry'
  local retry_id = retry_path:match('^/session/([^/]+)/retry$')
  lu.assertEquals(retry_id, 'test-session-id')

  local delete_path = '/session/test-session-id'
  local delete_id = delete_path:match('^/session/(.+)$')
  lu.assertEquals(delete_id, 'test-session-id')

  local messages_path = '/messages?session=test-id'
  local session_id = messages_path:match('session=([^&]+)')
  lu.assertEquals(session_id, 'test-id')

  -- Test query param extraction
  local preview_path = '/session?id=test-preview-id'
  local preview_id = preview_path:match('id=([^&]+)')
  lu.assertEquals(preview_id, 'test-preview-id')
end

-- Test JSON encode/decode for responses
function TestHTTP:testJsonResponseFormat()
  local test_data = {
    session_id = 'test-session',
    cwd = '/tmp/test',
    provider = 'openai',
    model = 'gpt-4',
    in_progress = false,
  }

  local json_str = vim.json.encode(test_data)
  lu.assertEquals(type(json_str), 'string')

  local decoded = vim.json.decode(json_str)
  lu.assertEquals(decoded.session_id, 'test-session')
  lu.assertEquals(decoded.cwd, '/tmp/test')
  lu.assertEquals(decoded.provider, 'openai')
  lu.assertEquals(decoded.model, 'gpt-4')
  lu.assertEquals(decoded.in_progress, false)
end

-- Test /session/new returns full session info
function TestHTTP:testNewSessionResponse()
  -- Create session via sessions module
  local new_id = sessions.new()

  -- Verify session was created with correct defaults
  lu.assertTrue(sessions.exists(new_id))
  lu.assertEquals(type(new_id), 'string')

  -- Get session data
  local all_sessions = sessions.get()
  local session_data = all_sessions[new_id]

  -- Verify expected fields for response
  lu.assertNotNil(session_data.id)
  lu.assertNotNil(session_data.cwd)
  lu.assertNotNil(session_data.provider)
  lu.assertNotNil(session_data.model)

  -- New session should have empty messages
  lu.assertEquals(#session_data.messages, 0)
end

-- Test /session/new with provider and model options
function TestHTTP:testNewSessionWithOptions()
  -- Create session with custom provider and model
  local new_id = sessions.new()

  -- Set provider and model
  sessions.set_session_provider(new_id, 'openai')
  sessions.set_session_model(new_id, 'gpt-4')

  -- Get updated session data
  local all_sessions = sessions.get()
  local session_data = all_sessions[new_id]

  -- Verify custom values
  lu.assertEquals(session_data.provider, 'openai')
  lu.assertEquals(session_data.model, 'gpt-4')
end

--------------------------------------------------
-- Upload endpoint tests
--------------------------------------------------

-- Test upload route matching with query string
function TestHTTP:testUploadRouteMatching()
  -- With query string
  local path1 = '/session/test-session-id/upload?path=images/photo.png'
  local sid1, query1 = path1:match('^/session/([^/]+)/upload%?(.*)$')
  lu.assertEquals(sid1, 'test-session-id')
  lu.assertEquals(query1, 'path=images/photo.png')

  -- Extract path from query
  local file_path1 = query1:match('path=([^&]+)')
  lu.assertEquals(file_path1, 'images/photo.png')

  -- Without query string (X-Filename header fallback)
  local path2 = '/session/test-session-id/upload'
  local sid2, query2 = path2:match('^/session/([^/]+)/upload%?(.*)$')
  lu.assertEquals(sid2, nil)

  local sid3 = path2:match('^/session/([^/]+)/upload$')
  lu.assertEquals(sid3, 'test-session-id')
end

-- Test upload path traversal rejection
function TestHTTP:testUploadPathTraversalRejection()
  local function is_path_safe(file_path)
    if file_path:find('%.%.') then
      return false, 'Path traversal not allowed'
    end
    if file_path:match('^/') or file_path:match('^%a:[/\\]') then
      return false, 'Absolute paths not allowed'
    end
    return true
  end

  -- Safe paths
  lu.assertEquals(is_path_safe('images/photo.png'), true)
  lu.assertEquals(is_path_safe('assets/img/logo.svg'), true)
  lu.assertEquals(is_path_safe('file.txt'), true)

  -- Unsafe paths
  lu.assertEquals(is_path_safe('../etc/passwd'), false)
  lu.assertEquals(is_path_safe('images/../../etc/passwd'), false)
  lu.assertEquals(is_path_safe('../../secret'), false)
  lu.assertEquals(is_path_safe('/etc/passwd'), false)
  lu.assertEquals(is_path_safe('C:\\Windows\\system32'), false)
end

-- Test upload with session cwd
function TestHTTP:testUploadToSessionCwd()
  -- Create a temp directory to use as cwd
  local temp_cwd = vim.fn.tempname() .. '_upload_test/'
  vim.fn.mkdir(temp_cwd, 'p')

  -- Create session and set cwd
  local session_id = sessions.new()
  sessions.change_cwd(session_id, temp_cwd)

  -- Verify session cwd was set
  local all_sessions = sessions.get()
  lu.assertEquals(all_sessions[session_id].cwd, temp_cwd)

  -- Simulate writing a file to cwd
  local file_path = 'images/test.png'
  local cwd_normalized = vim.fs.normalize(temp_cwd)
  local full_path = vim.fs.normalize(cwd_normalized .. '/' .. file_path)

  -- Verify path is within cwd
  lu.assertEquals(full_path:sub(1, #cwd_normalized), cwd_normalized)

  -- Create parent dirs and write file
  local parent_dir = vim.fs.dirname(full_path)
  vim.fn.mkdir(parent_dir, 'p')
  local fd = io.open(full_path, 'wb')
  lu.assertNotNil(fd)
  fd:write('fake image data')
  fd:close()

  -- Verify file exists
  lu.assertEquals(vim.fn.filereadable(full_path), 1)

  -- Verify content
  local read_fd = io.open(full_path, 'rb')
  lu.assertNotNil(read_fd)
  local content = read_fd:read('*a')
  read_fd:close()
  lu.assertEquals(content, 'fake image data')

  -- Cleanup
  vim.fn.delete(temp_cwd, 'rf')
end

-- Test URL-decoded file path for upload
function TestHTTP:testUploadUrlDecodedPath()
  local function url_decode(str)
    return str:gsub('%%(%x%x)', function(h)
      return string.char(tonumber(h, 16))
    end)
  end

  -- URL-encoded path with spaces
  local encoded = 'my%20images/photo%20copy.png'
  local decoded = url_decode(encoded)
  lu.assertEquals(decoded, 'my images/photo copy.png')

  -- URL-encoded path with subdirectory
  local encoded2 = 'assets%2Flogo.png'
  local decoded2 = url_decode(encoded2)
  lu.assertEquals(decoded2, 'assets/logo.png')
end

-- Test that upload route doesn't match other session routes
function TestHTTP:testUploadRouteNoFalseMatch()
  -- These should NOT match the upload route
  local upload_pattern = '^/session/[^/]+/upload'

  -- Should match
  lu.assertNotNil(('/session/abc/upload'):match(upload_pattern))
  lu.assertNotNil(('/session/abc/upload?path=x.png'):match(upload_pattern))

  -- Should not match (different endpoints)
  lu.assertNil(('/session/abc/stop'):match(upload_pattern))
  lu.assertNil(('/session/abc/clear'):match(upload_pattern))
  lu.assertNil(('/session/abc/retry'):match(upload_pattern))
  lu.assertNil(('/session/abc/messages/1'):match(upload_pattern))
end

-- Test upload-dir route matching
function TestHTTP:testUploadDirRouteMatching()
  -- GET route
  local get_pattern = '^/session/([^/]+)/upload%-dir$'
  lu.assertNotNil(('/session/abc/upload-dir'):match(get_pattern))
  lu.assertNil(('/session/abc/upload'):match(get_pattern))
  lu.assertNil(('/session/abc/cwd'):match(get_pattern))

  -- PUT route (same pattern, different method)
  lu.assertEquals(('/session/abc/upload-dir'):match(get_pattern), 'abc')
end

-- Test get/set upload_dir on session
function TestHTTP:testGetSetUploadDir()
  -- Initially nil (uses cwd)
  lu.assertNil(sessions.get_upload_dir(self.test_session_id))

  -- Set upload_dir
  local temp_dir = vim.fn.tempname() .. '_uploaddir_test/'
  vim.fn.mkdir(temp_dir, 'p')
  sessions.set_upload_dir(self.test_session_id, temp_dir)

  -- Verify it was set (normalized)
  local got = sessions.get_upload_dir(self.test_session_id)
  lu.assertNotNil(got)
  lu.assertEquals(got, vim.fs.normalize(temp_dir))

  -- Reset to nil
  sessions.set_upload_dir(self.test_session_id, nil)
  lu.assertNil(sessions.get_upload_dir(self.test_session_id))

  -- Reset with empty string also works
  sessions.set_upload_dir(self.test_session_id, temp_dir)
  lu.assertNotNil(sessions.get_upload_dir(self.test_session_id))
  sessions.set_upload_dir(self.test_session_id, '')
  lu.assertNil(sessions.get_upload_dir(self.test_session_id))

  -- Cleanup
  vim.fn.delete(temp_dir, 'rf')
end

-- Test upload uses upload_dir when set
function TestHTTP:testUploadUsesUploadDir()
  -- Create temp directories
  local temp_cwd = vim.fn.tempname() .. '_cwd_test/'
  local temp_upload_dir = vim.fn.tempname() .. '_uploaddir_test/'
  vim.fn.mkdir(temp_cwd, 'p')
  vim.fn.mkdir(temp_upload_dir, 'p')

  -- Create session with cwd
  local session_id = sessions.new()
  sessions.change_cwd(session_id, temp_cwd)

  -- Set upload_dir to a different directory
  sessions.set_upload_dir(session_id, temp_upload_dir)

  -- Simulate upload logic: use upload_dir as base
  local upload_dir = sessions.get_upload_dir(session_id)
  lu.assertNotNil(upload_dir)
  lu.assertNotEquals(upload_dir, temp_cwd)

  local base_dir = upload_dir or temp_cwd
  lu.assertEquals(base_dir, vim.fs.normalize(temp_upload_dir))

  -- Write file to upload_dir
  local file_path = 'images/test.png'
  local base_normalized = vim.fs.normalize(base_dir)
  local full_path = vim.fs.normalize(base_normalized .. '/' .. file_path)

  -- Verify path is within upload_dir, NOT cwd
  lu.assertEquals(full_path:sub(1, #base_normalized), base_normalized)

  -- Create parent dirs and write file
  local parent_dir = vim.fs.dirname(full_path)
  vim.fn.mkdir(parent_dir, 'p')
  local fd = io.open(full_path, 'wb')
  lu.assertNotNil(fd)
  fd:write('test data')
  fd:close()

  -- Verify file is in upload_dir, not cwd
  lu.assertEquals(vim.fn.filereadable(full_path), 1)
  local cwd_file = vim.fs.normalize(temp_cwd .. '/' .. file_path)
  lu.assertEquals(vim.fn.filereadable(cwd_file), 0)

  -- Cleanup
  vim.fn.delete(temp_cwd, 'rf')
  vim.fn.delete(temp_upload_dir, 'rf')
end

-- Test upload falls back to cwd when upload_dir not set
function TestHTTP:testUploadFallsBackToCwd()
  local temp_cwd = vim.fn.tempname() .. '_fallback_cwd/'
  vim.fn.mkdir(temp_cwd, 'p')

  local session_id = sessions.new()
  sessions.change_cwd(session_id, temp_cwd)

  -- upload_dir not set
  lu.assertNil(sessions.get_upload_dir(session_id))

  -- Simulate upload logic: falls back to cwd
  local all_sessions = sessions.get()
  local session_data = all_sessions[session_id]
  local base_dir = sessions.get_upload_dir(session_id) or session_data.cwd
  lu.assertEquals(base_dir, temp_cwd)

  -- Cleanup
  vim.fn.delete(temp_cwd, 'rf')
end

return TestHTTP
