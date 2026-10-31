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

function TestSessions:testSearchMessages()
  local session_id = sessions.new()

  sessions.append_message(session_id, {
    role = 'user',
    content = 'Hello world',
    created = os.time(),
  })
  sessions.append_message(session_id, {
    role = 'assistant',
    content = 'Hi',
    reasoning_content = 'world is the topic',
    created = os.time(),
  })

  local result = sessions.search_messages(session_id, 'world')
  lu.assertNotNil(result)
  lu.assertEquals(result.count, 2)
  lu.assertEquals(result.indices[1], 1)
  lu.assertEquals(result.indices[2], 2)
end

function TestSessions:testSearchMessagesNoMatch()
  local session_id = sessions.new()

  sessions.append_message(session_id, {
    role = 'user',
    content = 'hello',
    created = os.time(),
  })

  local result = sessions.search_messages(session_id, 'nope')
  lu.assertEquals(result.count, 0)
  lu.assertEquals(#result.indices, 0)
end

function TestSessions:testSearchMessagesNonExistentSession()
  lu.assertNil(sessions.search_messages('ghost', 'x'))
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
  local total, prompt, completion, cached =
    sessions.get_total_tokens('no-such-session')
  lu.assertEquals(total, 0)
  lu.assertEquals(prompt, 0)
  lu.assertEquals(completion, 0)
  lu.assertEquals(cached, 0)
end

function TestSessions:testGetTotalTokensEmptySession()
  local session_id = sessions.new()
  local total, prompt, completion, cached = sessions.get_total_tokens(session_id)
  lu.assertEquals(total, 0)
  lu.assertEquals(prompt, 0)
  lu.assertEquals(completion, 0)
  lu.assertEquals(cached, 0)
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

  local total, prompt, completion, cached = sessions.get_total_tokens(session_id)
  lu.assertEquals(total, 170)
  lu.assertEquals(prompt, 130)
  lu.assertEquals(completion, 40)
  lu.assertEquals(cached, 0)

  -- second call returns the same cached values
  local total2, prompt2, completion2, cached2 = sessions.get_total_tokens(session_id)
  lu.assertEquals(total2, 170)
  lu.assertEquals(prompt2, 130)
  lu.assertEquals(completion2, 40)
  lu.assertEquals(cached2, 0)
end

function TestSessions:testAppendMessageAccumulatesCachedTokens()
  local session_id = sessions.new()
  sessions.append_message(session_id, {
    role = 'assistant',
    content = 'a',
    created = os.time(),
    usage = {
      prompt_tokens = 100,
      completion_tokens = 10,
      prompt_cache_hit_tokens = 60,
    },
  })
  sessions.append_message(session_id, {
    role = 'assistant',
    content = 'b',
    created = os.time(),
    usage = {
      prompt_tokens = 50,
      completion_tokens = 5,
      cached_tokens = 20,
    },
  })

  local session_usage =
    require('chat.sessions.storage').sessions[session_id].usage
  lu.assertEquals(session_usage.cached_tokens, 80)
  -- total falls back to prompt + completion for both payloads
  lu.assertEquals(session_usage.total_tokens, 165)
end

function TestSessions:testGetTotalTokensPartialUsageFields()
  local session_id = sessions.new()
  -- Missing fields default to 0. When a payload omits total_tokens the total
  -- falls back to prompt + completion (chat.usage.normalize), so a partial
  -- message still contributes its real size instead of 0.
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

  local total, prompt, completion, cached = sessions.get_total_tokens(session_id)
  lu.assertEquals(total, 17)
  lu.assertEquals(prompt, 4)
  lu.assertEquals(completion, 3)
  lu.assertEquals(cached, 0)
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

  local total, prompt, completion, cached = sessions.get_total_tokens(session_id)
  lu.assertEquals(total, 40)
  lu.assertEquals(prompt, 30)
  lu.assertEquals(completion, 10)
  lu.assertEquals(cached, 0)

  -- computed result is cached back onto the session
  local cached_usage = require('chat.sessions.storage').sessions[session_id].usage
  lu.assertEquals(cached_usage.total_tokens, 40)
  lu.assertEquals(cached_usage.prompt_tokens, 30)
  lu.assertEquals(cached_usage.completion_tokens, 10)
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

function TestSessions:testGetRequestMessagesExcludesReasoningContent()
  -- Regression: reasoning_content must never be resent in requests.
  -- Providers ignore or reject reasoning on input, and those that keep it
  -- tokenize and bill it: resending a reasoning-heavy window inflated
  -- requests by tens of thousands of tokens and alternated the request
  -- shape between turns, breaking the provider prefix cache. History
  -- keeps reasoning_content for UI display and the get_history tool.
  local session_id = sessions.new()

  sessions.set_session_prompt(session_id, 'You are helpful.')

  sessions.append_message(session_id, {
    role = 'user',
    content = 'Question',
    created = os.time(),
  })
  sessions.append_message(session_id, {
    role = 'assistant',
    content = 'Answer',
    reasoning_content = 'internal chain of thought',
    created = os.time(),
  })

  local request_messages = sessions.get_request_messages(session_id)
  for _, m in ipairs(request_messages) do
    lu.assertNil(
      m.reasoning_content,
      'request messages must not carry reasoning_content'
    )
  end
  lu.assertEquals(request_messages[2].content, 'Question')
  lu.assertEquals(request_messages[3].content, 'Answer')

  -- History (UI display / get_history tool) still exposes the reasoning.
  local history = sessions.get_messages(session_id)
  lu.assertEquals(history[2].reasoning_content, 'internal chain of thought')
end

function TestSessions:testGetRequestMessagesNoticeTrailsTruncatedAssistant()
  -- Auto-continue (finish_reason == "length") strips the trailing notice
  -- and resends the truncated assistant as the final entry (regression for
  -- eac6d50, which displaced the assistant). The notice itself is the very
  -- last request message so it never invalidates the cached prefix.
  local session_id = sessions.new()
  sessions.set_session_prompt(session_id, 'You are helpful.')

  for i = 1, 58 do
    sessions.append_message(session_id, {
      role = 'user',
      content = 'm' .. i,
      created = os.time(),
    })
  end
  sessions.append_message(session_id, {
    role = 'assistant',
    content = 'partial answer',
    created = os.time(),
  })

  local request_messages = sessions.get_request_messages(session_id)

  -- 59 history messages exceed trigger_threshold (50), so truncation fires
  -- and emits the context notice at the very end of the request.
  local notice_index = nil
  for i, m in ipairs(request_messages) do
    if m.role == 'system' and m.content:find('Context Window Notice', 1, true) then
      notice_index = i
      break
    end
  end
  lu.assertNotNil(notice_index, 'context notice emitted after truncation')
  lu.assertEquals(notice_index, #request_messages, 'notice is the last entry')

  -- The truncated assistant stays the last real message; the continue flow
  -- sees it after strip_trailing_notice().
  lu.assertEquals(request_messages[#request_messages - 1].role, 'assistant')
  lu.assertEquals(request_messages[#request_messages - 1].content, 'partial answer')

  local stripped =
    require('chat.context').strip_trailing_notice(request_messages)
  lu.assertEquals(stripped[#stripped].role, 'assistant')
  lu.assertEquals(stripped[#stripped].content, 'partial answer')
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

-- ─── nil 守卫（#5）────────────────────────────────────

function TestSessions:testGetSessionProviderNonexistent()
  lu.assertNil(sessions.get_session_provider('no-such-session'))
end

function TestSessions:testSetSessionProviderNonexistent()
  lu.assertFalse(sessions.set_session_provider('no-such-session', 'openai'))
end

function TestSessions:testGetSessionModelNonexistent()
  lu.assertNil(sessions.get_session_model('no-such-session'))
end

function TestSessions:testSetSessionModelNonexistent()
  lu.assertFalse(sessions.set_session_model('no-such-session', 'gpt-4'))
end

function TestSessions:testGetcwdNonexistent()
  lu.assertNil(sessions.getcwd('no-such-session'))
end

function TestSessions:testChangeCwdNonexistent()
  sessions.change_cwd('no-such-session', '/tmp/whatever')
  lu.assertTrue(true)
end

-- ─── 同秒冲突（#7）─────────────────────────────────────

function TestSessions:testNewSessionSameSecondCollision()
  local id = os.date('%Y-%m-%d-%H-%M-%S', os.time())
  local storage = require('chat.sessions.storage')
  storage.sessions[id] = {
    id = id,
    messages = { { role = 'user', content = 'original', created = os.time() } },
    provider = 'test',
    model = 'test',
    cwd = vim.fn.getcwd(),
  }

  local new_id, err = sessions.new()
  lu.assertNil(new_id)
  lu.assertNotNil(err)

  -- 原会话未被静默覆盖
  lu.assertEquals(storage.sessions[id].messages[1].content, 'original')
end

return TestSessions

