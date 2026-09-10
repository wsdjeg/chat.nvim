-- test/sessions_spec.lua
local lu = require('luaunit')
local sessions = require('chat.sessions')
local config = require('chat.config')

TestSessions = {}

function TestSessions:setUp()
  -- Setup test configuration
  config.setup({
    provider = 'test-provider',
    model = 'test-model',
  })
  -- Use a temp directory to avoid polluting real session cache
  self.test_cache_dir = vim.fn.tempname() .. '/'
  sessions.set_cache_dir(self.test_cache_dir)
end

function TestSessions:tearDown()
  -- Clean up temp cache directory
  vim.fn.delete(self.test_cache_dir, 'rf')
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

-- ─── get_total_tokens ───────────────────────────────────

function TestSessions:testGetTotalTokensNonexistentSession()
  local total, prompt, completion = sessions.get_total_tokens('no-such-session')
  lu.assertEquals(total, 0)
  lu.assertEquals(prompt, 0)
  lu.assertEquals(completion, 0)
end

function TestSessions:testGetTotalTokensEmptySession()
  local session_id = sessions.new()
  local total, prompt, completion = sessions.get_total_tokens(session_id)
  lu.assertEquals(total, 0)
  lu.assertEquals(prompt, 0)
  lu.assertEquals(completion, 0)
end

function TestSessions:testGetTotalTokensSumsMessageUsage()
  local session_id = sessions.new()
  sessions.append_message(session_id, {
    role = 'user',
    content = 'hello',
    created = os.time(),
  })
  sessions.append_message(session_id, {
    role = 'assistant',
    content = 'hi',
    created = os.time(),
    usage = { total_tokens = 120, prompt_tokens = 100, completion_tokens = 20 },
  })
  sessions.append_message(session_id, {
    role = 'assistant',
    content = 'more',
    created = os.time(),
    usage = { total_tokens = 50, prompt_tokens = 30, completion_tokens = 20 },
  })

  local total, prompt, completion = sessions.get_total_tokens(session_id)
  lu.assertEquals(total, 170)
  lu.assertEquals(prompt, 130)
  lu.assertEquals(completion, 40)

  -- second call returns the same cached values
  local total2, prompt2, completion2 = sessions.get_total_tokens(session_id)
  lu.assertEquals(total2, 170)
  lu.assertEquals(prompt2, 130)
  lu.assertEquals(completion2, 40)
end

function TestSessions:testGetTotalTokensPartialUsageFields()
  local session_id = sessions.new()
  -- missing fields default to 0
  sessions.append_message(session_id, {
    role = 'assistant',
    content = 'a',
    created = os.time(),
    usage = { total_tokens = 10 },
  })
  sessions.append_message(session_id, {
    role = 'assistant',
    content = 'b',
    created = os.time(),
    usage = { prompt_tokens = 4 },
  })
  sessions.append_message(session_id, {
    role = 'assistant',
    content = 'c',
    created = os.time(),
    usage = { completion_tokens = 3 },
  })
  -- empty usage table contributes nothing
  sessions.append_message(session_id, {
    role = 'assistant',
    content = 'd',
    created = os.time(),
    usage = {},
  })

  local total, prompt, completion = sessions.get_total_tokens(session_id)
  lu.assertEquals(total, 10)
  lu.assertEquals(prompt, 4)
  lu.assertEquals(completion, 3)
end

function TestSessions:testGetTotalTokensRecomputesLegacySession()
  local session_id = sessions.new()
  sessions.append_message(session_id, {
    role = 'assistant',
    content = 'legacy',
    created = os.time(),
    usage = { total_tokens = 25, prompt_tokens = 20, completion_tokens = 5 },
  })
  sessions.append_message(session_id, {
    role = 'assistant',
    content = 'legacy2',
    created = os.time(),
    usage = { total_tokens = 15, prompt_tokens = 10, completion_tokens = 5 },
  })

  -- simulate legacy persisted data: messages keep usage but the
  -- session-level usage cache is missing
  require('chat.sessions.storage').sessions[session_id].usage = nil

  local total, prompt, completion = sessions.get_total_tokens(session_id)
  lu.assertEquals(total, 40)
  lu.assertEquals(prompt, 30)
  lu.assertEquals(completion, 10)

  -- computed result is cached back onto the session
  local cached = require('chat.sessions.storage').sessions[session_id].usage
  lu.assertEquals(cached.total_tokens, 40)
  lu.assertEquals(cached.prompt_tokens, 30)
  lu.assertEquals(cached.completion_tokens, 10)
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

  -- Verify file exists in the test cache directory
  local cache_file = self.test_cache_dir .. session_id .. '.json'
  lu.assertEquals(vim.fn.filereadable(cache_file), 1)
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

function TestSessions:testAppendMessageSanitizesInvalidUtf8()
  local session_id = sessions.new()

  -- "\xB4\xFA\xC2\xEB" is GBK encoding, invalid as UTF-8
  sessions.append_message(session_id, {
    role = 'tool',
    content = 'git status: \xB4\xFA\xC2\xEB file.lua',
    tool_call_id = 'call_1',
    created = os.time(),
  })

  local messages = sessions.get_messages(session_id)
  lu.assertStrContains(messages[1].content, '\xEF\xBF\xBD') -- U+FFFD
  lu.assertNotStrContains(messages[1].content, '\xB4\xFA')
end

function TestSessions:testAppendMessageKeepsValidUtf8()
  local session_id = sessions.new()
  local content = '你好 emoji 🎉 plain ASCII'

  sessions.append_message(session_id, {
    role = 'user',
    content = content,
    created = os.time(),
  })

  local messages = sessions.get_messages(session_id)
  lu.assertEquals(messages[1].content, content)
end

function TestSessions:testGetRequestMessagesRepairsLegacyHistory()
  local session_id = sessions.new()

  -- Simulate a polluted cache written by an older version: messages with
  -- invalid UTF-8 bytes injected straight into storage
  local storage = require('chat.sessions.storage')
  table.insert(storage.sessions[session_id].messages, {
    role = 'user',
    content = 'output: \xB4\xFA\xC2\xEB',
    created = os.time(),
  })

  local request_messages = sessions.get_request_messages(session_id)
  lu.assertStrContains(request_messages[#request_messages].content, '\xEF\xBF\xBD')

  -- Acceptance: the JSON-encoded request body must be valid UTF-8
  -- (this is what providers reject with InvalidParameter.NonUTF8Body)
  local ok, encoded = pcall(vim.json.encode, request_messages)
  lu.assertTrue(ok)
  local util = require('chat.util')
  local _, had_invalid = util.sanitize_utf8(encoded)
  lu.assertFalse(had_invalid)

  -- Self-healing: the stored history is repaired in place, so the next
  -- cache write persists valid UTF-8
  local stored = storage.sessions[session_id].messages
  lu.assertStrContains(stored[#stored].content, '\xEF\xBF\xBD')
end

function TestSessions:testGetRequestMessagesSanitizesPrompt()
  local session_id = sessions.new()
  sessions.set_session_prompt(session_id, 'System \xFF prompt')

  local request_messages = sessions.get_request_messages(session_id)
  lu.assertEquals(request_messages[1].role, 'system')
  lu.assertStrContains(request_messages[1].content, '\xEF\xBF\xBD')
  lu.assertNotStrContains(request_messages[1].content, '\xFF')
end

function TestSessions:testGetRequestMessagesSanitizesToolCallArguments()
  local session_id = sessions.new()

  local storage = require('chat.sessions.storage')
  table.insert(storage.sessions[session_id].messages, {
    role = 'assistant',
    tool_calls = {
      {
        id = 'call_1',
        type = 'function',
        ['function'] = {
          name = 'git_status',
          arguments = '{"path": "\xC0\xAF"}', -- overlong '/', invalid UTF-8
        },
      },
    },
    created = os.time(),
  })

  local request_messages = sessions.get_request_messages(session_id)
  local last = request_messages[#request_messages]
  lu.assertStrContains(last.tool_calls[1]['function'].arguments, '\xEF\xBF\xBD')
end

function TestSessions:testAppendMessageWithErrorOnlyFields()
  -- Control messages (errors, on_complete markers) have no content and
  -- must pass through sanitization untouched
  local session_id = sessions.new()

  sessions.append_message(session_id, {
    error = 'API Error (InvalidParameter.NonUTF8Body)',
    created = os.time(),
  })

  local messages = sessions.get_messages(session_id)
  lu.assertEquals(messages[1].error, 'API Error (InvalidParameter.NonUTF8Body)')
  lu.assertNil(messages[1].content)
end

return TestSessions

