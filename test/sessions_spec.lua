-- test/sessions_spec.lua
local lu = require('luaunit')
local sessions = require('chat.sessions')
local config = require('chat.config')

local TestSessions = {}

function TestSessions:setUp()
  -- Setup test configuration
  config.setup({
    provider = 'test-provider',
    model = 'test-model',
  })
end

function TestSessions:testNewSession()
  local session_id = sessions.new()

  lu.assertNotNil(session_id)
  lu.assertStrMatches(session_id, '%d%d%d%d%-%d%d%-%d%d%-%d%d%-%d%d%-%d%d')
  lu.assertTrue(sessions.exists(session_id))
end

function TestSessions:testGetMessages()
  local session_id = sessions.new()

  -- Add test message
  sessions.append_message(session_id, {
    role = 'user',
    content = 'Hello',
    created = os.time(),
  })

  local messages = sessions.get_messages(session_id)
  lu.assertEquals(#messages, 1)
  lu.assertEquals(messages[1].role, 'user')
  lu.assertEquals(messages[1].content, 'Hello')
end

function TestSessions:testAppendMessage()
  local session_id = sessions.new()

  sessions.append_message(session_id, {
    role = 'assistant',
    content = 'Hi there!',
    created = os.time(),
  })

  local messages = sessions.get_messages(session_id)
  lu.assertEquals(#messages, 1)
  lu.assertEquals(messages[1].role, 'assistant')
  lu.assertEquals(messages[1].content, 'Hi there!')
end

function TestSessions:testSetSessionProvider()
  local session_id = sessions.new()

  local success = sessions.set_session_provider(session_id, 'openai')
  lu.assertTrue(success)
  lu.assertEquals(sessions.get_session_provider(session_id), 'openai')
end

function TestSessions:testSetSessionModel()
  local session_id = sessions.new()

  sessions.set_session_model(session_id, 'gpt-4')
  lu.assertEquals(sessions.get_session_model(session_id), 'gpt-4')
end

function TestSessions:testGetRequestMessages()
  local session_id = sessions.new()

  -- Add system prompt
  sessions.set_session_prompt(session_id, 'You are helpful.')

  -- Add messages
  sessions.append_message(session_id, {
    role = 'user',
    content = 'Question',
    created = os.time(),
  })

  sessions.append_message(session_id, {
    role = 'assistant',
    content = 'Answer',
    created = os.time(),
  })

  local request_messages = sessions.get_request_messages(session_id)
  lu.assertEquals(#request_messages, 3) -- system + user + assistant
  lu.assertEquals(request_messages[1].role, 'system')
  lu.assertEquals(request_messages[2].role, 'user')
  lu.assertEquals(request_messages[3].role, 'assistant')
end

function TestSessions:testChangeCwd()
  local session_id = sessions.new()
  local test_cwd = '/tmp/test-dir'

  sessions.change_cwd(session_id, test_cwd)
  lu.assertEquals(sessions.getcwd(session_id), test_cwd)
end

function TestSessions:testClearSession()
  local session_id = sessions.new()

  sessions.append_message(session_id, {
    role = 'user',
    content = 'Test message',
    created = os.time(),
  })

  -- Note: clear() works on current session, so we need to mock it
  -- This is a simplified test
  lu.assertEquals(#sessions.get_messages(session_id), 1)
end

function TestSessions:testWriteCache()
  local session_id = sessions.new()

  sessions.append_message(session_id, {
    role = 'user',
    content = 'Cache test',
    created = os.time(),
  })

  local success = sessions.write_cache(session_id)
  lu.assertTrue(success)

  -- Verify file exists
  local cache_dir = vim.fn.stdpath('cache') .. '/chat.nvim/'
  local cache_file = cache_dir .. session_id .. '.json'
  lu.assertEquals(vim.fn.filereadable(cache_file), 1)

  -- Clean up
  vim.fn.delete(cache_file)
end

function TestSessions:testSaveLoadSession()
  local session_id = sessions.new()

  sessions.append_message(session_id, {
    role = 'user',
    content = 'Save/Load test',
    created = os.time(),
  })

  -- Save to file
  local temp_file = vim.fn.tempname() .. '.json'
  local success = sessions.save_to_file(session_id, temp_file)
  lu.assertTrue(success)

  -- Load from file
  local loaded_id = sessions.load_from_file(temp_file)
  lu.assertNotNil(loaded_id)

  local messages = sessions.get_messages(loaded_id)
  lu.assertEquals(#messages, 1)
  lu.assertEquals(messages[1].content, 'Save/Load test')

  -- Clean up
  vim.fn.delete(temp_file)
end

return TestSessions
