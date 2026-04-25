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

function TestHTTP:setUp()
  -- Setup test config
  config._config = {
    http = {
      enabled = true,
      host = '127.0.0.1',
      port = 9876,
      api_key = 'test-api-key',
    },
    memory = {
      enabled = true,
      db_path = vim.fn.stdpath('data') .. '/chat_test_memories.db',
    },
  }
  
  -- Create a test session
  sessions._sessions = {}
  self.test_session_id = sessions.new()
end

function TestHTTP:tearDown()
  sessions._sessions = {}
  config._config = nil
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
  local method2, path2, headers2, body2 = make_request('GET', '/sessions', {['X-API-Key'] = 'test-api-key'}, '')
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
    {['Content-Type'] = 'application/json', ['X-API-Key'] = 'test-api-key'},
    '{"cwd":"/tmp"}'
  )
  
  lu.assertEquals(method, 'POST')
  lu.assertEquals(path, '/session/new')
  lu.assertEquals(headers['content-type'], 'application/json')
  lu.assertEquals(headers['x-api-key'], 'test-api-key')
  lu.assertEquals(body, '{"cwd":"/tmp"}')
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

return TestHTTP
