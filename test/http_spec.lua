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

--------------------------------------------------
-- Skills endpoint tests
--------------------------------------------------

-- Test /skills response data comes from skills.list()
function TestHTTP:testSkillsListData()
  local skills = require('chat.skills').list()
  lu.assertEquals(type(skills), 'table')
  lu.assertTrue(#skills > 0)

  -- Response shape mirrors handle_list_skills
  local result = {}
  for _, skill in ipairs(skills) do
    table.insert(result, {
      name = skill.name,
      description = skill.description or '',
      builtin = skill.builtin or false,
    })
  end

  -- Every entry must have name/description/builtin
  for _, item in ipairs(result) do
    lu.assertEquals(type(item.name), 'string')
    lu.assertEquals(type(item.description), 'string')
    lu.assertEquals(type(item.builtin), 'boolean')
  end

  -- List must be sorted by name (skills.list() guarantee)
  for i = 2, #result do
    lu.assertTrue(result[i - 1].name < result[i].name)
  end

  -- Built-in skills should be present
  local names = {}
  for _, item in ipairs(result) do
    names[item.name] = true
  end
  lu.assertTrue(names['clear'] ~= nil)
  lu.assertTrue(names['help'] ~= nil)
end

-- Test /skills response is JSON-serializable (no handler functions)
function TestHTTP:testSkillsListJsonSerializable()
  local skills = require('chat.skills').list()

  local result = {}
  for _, skill in ipairs(skills) do
    table.insert(result, {
      name = skill.name,
      description = skill.description or '',
      builtin = skill.builtin or false,
    })
  end

  -- Handler functions must NOT leak into the response
  local ok, encoded = pcall(vim.json.encode, result)
  lu.assertTrue(ok)
  lu.assertEquals(type(encoded), 'string')

  local decoded = vim.json.decode(encoded)
  lu.assertEquals(type(decoded), 'table')
  lu.assertEquals(#decoded, #result)
  lu.assertEquals(decoded[1].name, result[1].name)
end

-- Test user-registered skill appears in /skills response
function TestHTTP:testSkillsListIncludesUserSkill()
  local skills = require('chat.skills')

  skills.register({
    name = 'http-test-skill',
    description = 'temp skill for http test',
    handler = function() end,
  })

  local list = skills.list()
  local found = false
  for _, item in ipairs(list) do
    if item.name == 'http-test-skill' then
      found = true
      lu.assertEquals(item.description, 'temp skill for http test')
      lu.assertEquals(item.builtin, nil)
    end
  end
  lu.assertTrue(found)

  skills.unregister('http-test-skill')
  lu.assertNil(skills.get('http-test-skill'))
end

--------------------------------------------------
-- /skills dispatcher tests (real route invocation)
--------------------------------------------------

local routes = require('chat.http.routes')

--- Create a mock uv tcp client that captures written responses
local function make_mock_client()
  local mock = { written = nil, closed = false }

  function mock:is_closing()
    return self.closed
  end

  function mock:write(data, cb)
    self.written = data
    if cb then
      cb()
    end
    return true
  end

  function mock:close()
    self.closed = true
  end

  return mock
end

--- Parse captured raw response into (status, headers, body)
local function parse_mock_response(raw)
  local status = tonumber(raw:match('^HTTP/1%.1 (%d+)'))
  local header_part, body = raw:match('^(.-)\r\n\r\n(.*)$')
  return status, header_part, body
end

local AUTH_HEADERS = { ['x-api-key'] = 'test-api-key' }

-- Test GET /skills dispatch: 200 + JSON body with all registered skills
function TestHTTP:testSkillsEndpointDispatch()
  local client = make_mock_client()
  routes.handle_request(client, 'GET', '/skills', AUTH_HEADERS, '', 0)

  lu.assertNotNil(client.written)
  lu.assertTrue(client.closed, 'client must be closed after response')

  local status, headers, body = parse_mock_response(client.written)
  lu.assertEquals(status, 200)
  lu.assertNotNil(headers:find('Content%-Type: application/json'))

  local ok, data = pcall(vim.json.decode, body)
  lu.assertTrue(ok)
  lu.assertEquals(type(data), 'table')
  lu.assertTrue(#data > 0)

  local names = {}
  for _, item in ipairs(data) do
    lu.assertEquals(type(item.name), 'string')
    lu.assertEquals(type(item.description), 'string')
    lu.assertEquals(type(item.builtin), 'boolean')
    -- handler function must not leak into JSON response
    lu.assertNil(item.handler)
    lu.assertNil(item.complete)
    names[item.name] = true
  end

  -- Built-in skills must be present
  lu.assertTrue(names['clear'] ~= nil)
  lu.assertTrue(names['help'] ~= nil)

  -- Response must be sorted by name
  for i = 2, #data do
    lu.assertTrue(data[i - 1].name <= data[i].name)
  end
end

-- Test GET /skills without API key: 401
function TestHTTP:testSkillsEndpointNoApiKey()
  local client = make_mock_client()
  routes.handle_request(client, 'GET', '/skills', {}, '', 0)

  lu.assertNotNil(client.written)
  local status = parse_mock_response(client.written)
  lu.assertEquals(status, 401)
end

-- Test GET /skills with wrong API key: 401
function TestHTTP:testSkillsEndpointWrongApiKey()
  local client = make_mock_client()
  routes.handle_request(client, 'GET', '/skills', { ['x-api-key'] = 'wrong-key' }, '', 0)

  lu.assertNotNil(client.written)
  local status = parse_mock_response(client.written)
  lu.assertEquals(status, 401)
end

-- Test POST /skills: method not in routes, 404
function TestHTTP:testSkillsEndpointPostNotAllowed()
  local client = make_mock_client()
  routes.handle_request(client, 'POST', '/skills', AUTH_HEADERS, '{}', 2)

  lu.assertNotNil(client.written)
  local status = parse_mock_response(client.written)
  lu.assertEquals(status, 404)
end

-- Test GET /skills/<sub>: sub-path not routed, 404
function TestHTTP:testSkillsEndpointSubPathNotFound()
  local client = make_mock_client()
  routes.handle_request(client, 'GET', '/skills/extra', AUTH_HEADERS, '', 0)

  lu.assertNotNil(client.written)
  local status = parse_mock_response(client.written)
  lu.assertEquals(status, 404)
end

-- Test /skills reflects a user-registered skill in endpoint response
function TestHTTP:testSkillsEndpointIncludesUserSkill()
  local skills = require('chat.skills')

  skills.register({
    name = 'zzz-endpoint-test-skill',
    description = 'endpoint response test',
    handler = function() end,
  })

  local client = make_mock_client()
  routes.handle_request(client, 'GET', '/skills', AUTH_HEADERS, '', 0)

  local status, _, body = parse_mock_response(client.written)
  lu.assertEquals(status, 200)

  local data = vim.json.decode(body)
  local found = false
  for _, item in ipairs(data) do
    if item.name == 'zzz-endpoint-test-skill' then
      found = true
      lu.assertEquals(item.description, 'endpoint response test')
      lu.assertEquals(item.builtin, false)
    end
  end
  lu.assertTrue(found)

  skills.unregister('zzz-endpoint-test-skill')
end

-- Test /skills response stays consistent across repeated calls
function TestHTTP:testSkillsEndpointStableAcrossCalls()
  local client1 = make_mock_client()
  routes.handle_request(client1, 'GET', '/skills', AUTH_HEADERS, '', 0)
  local client2 = make_mock_client()
  routes.handle_request(client2, 'GET', '/skills', AUTH_HEADERS, '', 0)

  local _, _, body1 = parse_mock_response(client1.written)
  local _, _, body2 = parse_mock_response(client2.written)
  lu.assertEquals(body1, body2)
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

-- Test upload-dir absolute path validation
function TestHTTP:testUploadDirMustBeAbsolute()
  local function is_absolute(path)
    return path:sub(1, 1) == '/'
      or path:match('^%a:[/\\]') ~= nil
      or path:match('^[/\\][/\\]') ~= nil
  end

  -- Absolute paths (valid)
  lu.assertTrue(is_absolute('/tmp/foo'))
  lu.assertTrue(is_absolute('/home/user/images'))
  lu.assertTrue(is_absolute('C:\\Users\\test'))
  lu.assertTrue(is_absolute('C:/Users/test'))
  lu.assertTrue(is_absolute('\\\\server\\share'))

  -- Relative paths (invalid)
  lu.assertFalse(is_absolute('foo/bar'))
  lu.assertFalse(is_absolute('./images'))
  lu.assertFalse(is_absolute('../images'))
  lu.assertFalse(is_absolute('images/'))
  lu.assertFalse(is_absolute('relative/path/to/dir'))
end

-- Test upload-dir must be within session cwd
function TestHTTP:testUploadDirWithinCwd()
  local function is_within(dir, cwd)
    local norm_cwd = vim.fs.normalize(cwd)
    if not norm_cwd:match('[/\\]$') then
      norm_cwd = norm_cwd .. '/'
    end
    local norm_dir = vim.fs.normalize(dir)
    if not norm_dir:match('[/\\]$') then
      norm_dir = norm_dir .. '/'
    end
    return vim.startswith(norm_dir, norm_cwd)
  end

  local cwd = '/home/user/project'

  -- Within cwd (valid)
  lu.assertTrue(is_within('/home/user/project', cwd))
  lu.assertTrue(is_within('/home/user/project/images', cwd))
  lu.assertTrue(is_within('/home/user/project/sub/deep', cwd))

  -- Outside cwd (invalid)
  lu.assertFalse(is_within('/home/user/other', cwd))
  lu.assertFalse(is_within('/tmp', cwd))
  lu.assertFalse(is_within('/etc', cwd))
  lu.assertFalse(is_within('/home/user', cwd))  -- parent, not within
end

--------------------------------------------------
-- Bridge (integrations) endpoint tests
--------------------------------------------------

-- Test bridge route matching
function TestHTTP:testBridgeRouteMatching()
  -- PUT /session/:id/bridge/:platform
  local put_pattern = '^/session/([^/]+)/bridge/([^/]+)$'
  local sid, platform = ('/session/abc/bridge/discord'):match(put_pattern)
  lu.assertEquals(sid, 'abc')
  lu.assertEquals(platform, 'discord')

  -- DELETE /session/:id/bridge/:platform
  local del_pattern = '^/session/([^/]+)/bridge/([^/]+)$'
  local did, dplatform = ('/session/xyz/bridge/lark'):match(del_pattern)
  lu.assertEquals(did, 'xyz')
  lu.assertEquals(dplatform, 'lark')

  -- DELETE /session/:id/bridge (unbridge all)
  local del_all_pattern = '^/session/([^/]+)/bridge$'
  local all_sid = ('/session/abc/bridge'):match(del_all_pattern)
  lu.assertEquals(all_sid, 'abc')

  -- GET /session/:id/bridge (list bridges)
  local get_pattern = '^/session/([^/]+)/bridge$'
  local get_sid = ('/session/test-id/bridge'):match(get_pattern)
  lu.assertEquals(get_sid, 'test-id')
end

-- Test bridge route doesn't false-match other session routes
function TestHTTP:testBridgeRouteNoFalseMatch()
  -- These should NOT match bridge routes
  local bridge_specific = '^/session/[^/]+/bridge/[^/]+$'
  local bridge_all = '^/session/[^/]+/bridge$'

  -- Should not match regular session routes
  lu.assertNil(('/session/abc/stop'):match(bridge_specific))
  lu.assertNil(('/session/abc/clear'):match(bridge_all))
  lu.assertNil(('/session/abc/provider'):match(bridge_all))

  -- DELETE /session/:id should NOT match bridge routes
  local delete_session = '^/session/[^/]+$'
  lu.assertNil(('/session/abc/bridge'):match(delete_session))
  lu.assertNil(('/session/abc/bridge/discord'):match(delete_session))
end

-- Test set_session returns boolean for valid/invalid platform
function TestHTTP:testSetSessionReturnsBoolean()
  local ims = require('chat.integrations')

  -- Invalid platform should return false
  local ok = ims.set_session('nonexistent-platform', self.test_session_id)
  lu.assertEquals(ok, false)
end

-- Test list_platforms returns known integrations
function TestHTTP:testListPlatforms()
  local ims = require('chat.integrations')
  local platforms = ims.list_platforms()

  lu.assertEquals(type(platforms), 'table')
  lu.assertTrue(#platforms > 0)

  -- Should include well-known platforms
  local has_discord = false
  for _, p in ipairs(platforms) do
    if p == 'discord' then
      has_discord = true
    end
  end
  lu.assertTrue(has_discord)
end

-- Test unbridge_session returns false for unknown integration
function TestHTTP:testUnbridgeSessionUnknownIntegration()
  local ims = require('chat.integrations')

  -- Unknown integration should return false
  local result = ims.unbridge_session(self.test_session_id, 'nonexistent-platform')
  lu.assertEquals(result, false)
end

-- Test unbridge_session returns nil when integration not bound
function TestHTTP:testUnbridgeSessionNotBound()
  local ims = require('chat.integrations')

  -- Valid integration but not bound to this session -> nil
  local result = ims.unbridge_session(self.test_session_id, 'discord')
  lu.assertEquals(result, nil)
end

-- Test get_integrations returns empty for session with no bridges
function TestHTTP:testGetIntegrationsEmpty()
  local ims = require('chat.integrations')
  local bridges = ims.get_integrations(self.test_session_id)

  lu.assertEquals(type(bridges), 'table')
  lu.assertEquals(#bridges, 0)
end

return TestHTTP
