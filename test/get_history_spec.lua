-- test/get_history_spec.lua
local lu = require('luaunit')
local get_history = require('chat.tools.get_history')
local sessions = require('chat.sessions')
local config = require('chat.config')

TestGetHistory = {}

function TestGetHistory:setUp()
  config.setup({
    provider = 'test-provider',
    model = 'test-model',
  })
end

-- ─── scheme() tests ─────────────────────────────────────────────

function TestGetHistory:testSchemeReturnsTable()
  local scheme = get_history.scheme()
  lu.assertEquals(type(scheme), 'table')
  lu.assertEquals(scheme.type, 'function')
end

function TestGetHistory:testSchemeHasCorrectName()
  local scheme = get_history.scheme()
  lu.assertEquals(scheme['function'].name, 'get_history')
end

function TestGetHistory:testSchemeHasOffsetProperty()
  local scheme = get_history.scheme()
  lu.assertNotNil(scheme['function'].parameters.properties.offset)
  lu.assertEquals(scheme['function'].parameters.properties.offset.type, 'integer')
end

function TestGetHistory:testSchemeHasLimitProperty()
  local scheme = get_history.scheme()
  lu.assertNotNil(scheme['function'].parameters.properties.limit)
  lu.assertEquals(scheme['function'].parameters.properties.limit.type, 'integer')
end

function TestGetHistory:testSchemeHasSearchProperty()
  local scheme = get_history.scheme()
  lu.assertNotNil(scheme['function'].parameters.properties.search)
  lu.assertEquals(scheme['function'].parameters.properties.search.type, 'string')
end

function TestGetHistory:testSchemeRequiredIsEmpty()
  local scheme = get_history.scheme()
  lu.assertEquals(#scheme['function'].parameters.required, 0)
end

-- ─── get_history() — error cases ────────────────────────────────

function TestGetHistory:testNoSessionInCtx()
  local result = get_history.get_history({}, { session = nil })
  lu.assertNotNil(result.error)
  lu.assertEquals(result.error, 'No active session')
end

function TestGetHistory:testNonExistentSession()
  local result = get_history.get_history(
    {},
    { session = 'non-existent-session-id' }
  )
  lu.assertNotNil(result.error)
  lu.assertEquals(result.error, 'No active session')
end

function TestGetHistory:testEmptySession()
  local sid = sessions.new()
  local result = get_history.get_history({}, { session = sid })
  lu.assertNotNil(result.content)
  lu.assertEquals(result.content, 'No messages in session history.')
end

-- ─── get_history() — basic retrieval ────────────────────────────

function TestGetHistory:testDefaultOffsetAndLimit()
  local sid = sessions.new()
  for i = 1, 5 do
    sessions.append_message(sid, {
      role = 'user',
      content = 'Message ' .. i,
      created = 1000 + i,
    })
  end

  local result = get_history.get_history({}, { session = sid })
  local data = vim.json.decode(result.content)

  lu.assertEquals(data.total, 5)
  lu.assertEquals(data.offset, 0)
  lu.assertEquals(data.limit, 20)
  lu.assertEquals(data.returned, 5)
  lu.assertEquals(#data.messages, 5)
end

function TestGetHistory:testCustomOffset()
  local sid = sessions.new()
  for i = 1, 10 do
    sessions.append_message(sid, {
      role = 'user',
      content = 'Message ' .. i,
      created = 1000 + i,
    })
  end

  local result = get_history.get_history(
    { offset = 3 },
    { session = sid }
  )
  local data = vim.json.decode(result.content)

  lu.assertEquals(data.offset, 3)
  lu.assertEquals(data.returned, 7)
  -- First returned message should be index 3 (0-indexed)
  lu.assertEquals(data.messages[1].index, 3)
  lu.assertEquals(data.messages[1].content, 'Message 4')
end

function TestGetHistory:testCustomLimit()
  local sid = sessions.new()
  for i = 1, 30 do
    sessions.append_message(sid, {
      role = 'user',
      content = 'Message ' .. i,
      created = 1000 + i,
    })
  end

  local result = get_history.get_history(
    { limit = 5 },
    { session = sid }
  )
  local data = vim.json.decode(result.content)

  lu.assertEquals(data.limit, 5)
  lu.assertEquals(data.returned, 5)
  lu.assertEquals(#data.messages, 5)
end

function TestGetHistory:testLimitClampedTo50()
  local sid = sessions.new()
  for i = 1, 60 do
    sessions.append_message(sid, {
      role = 'user',
      content = 'Message ' .. i,
      created = 1000 + i,
    })
  end

  local result = get_history.get_history(
    { limit = 100 },
    { session = sid }
  )
  local data = vim.json.decode(result.content)

  lu.assertEquals(data.limit, 50)
  lu.assertEquals(data.returned, 50)
end

function TestGetHistory:testLimitLargerThanTotal()
  local sid = sessions.new()
  for i = 1, 3 do
    sessions.append_message(sid, {
      role = 'user',
      content = 'Message ' .. i,
      created = 1000 + i,
    })
  end

  local result = get_history.get_history(
    { limit = 50 },
    { session = sid }
  )
  local data = vim.json.decode(result.content)

  lu.assertEquals(data.limit, 50)
  lu.assertEquals(data.returned, 3)
end

function TestGetHistory:testNegativeOffsetClampedToZero()
  local sid = sessions.new()
  sessions.append_message(sid, {
    role = 'user',
    content = 'Hello',
    created = 1000,
  })

  local result = get_history.get_history(
    { offset = -10 },
    { session = sid }
  )
  local data = vim.json.decode(result.content)

  lu.assertEquals(data.offset, 0)
  lu.assertEquals(data.returned, 1)
end

function TestGetHistory:testOffsetBeyondTotal()
  local sid = sessions.new()
  for i = 1, 5 do
    sessions.append_message(sid, {
      role = 'user',
      content = 'Message ' .. i,
      created = 1000 + i,
    })
  end

  local result = get_history.get_history(
    { offset = 10 },
    { session = sid }
  )
  lu.assertStrContains(result.content, 'beyond total message count')
  lu.assertStrContains(result.content, '5')
end

function TestGetHistory:testOffsetEqualsTotal()
  local sid = sessions.new()
  for i = 1, 3 do
    sessions.append_message(sid, {
      role = 'user',
      content = 'Message ' .. i,
      created = 1000 + i,
    })
  end

  local result = get_history.get_history(
    { offset = 3 },
    { session = sid }
  )
  lu.assertStrContains(result.content, 'beyond total message count')
end

-- ─── get_history() — message fields ─────────────────────────────

function TestGetHistory:testMessageFieldsPreserved()
  local sid = sessions.new()
  sessions.append_message(sid, {
    role = 'user',
    content = 'Test content',
    created = 12345,
  })

  local result = get_history.get_history({}, { session = sid })
  local data = vim.json.decode(result.content)

  lu.assertEquals(data.messages[1].index, 0)
  lu.assertEquals(data.messages[1].role, 'user')
  lu.assertEquals(data.messages[1].content, 'Test content')
  lu.assertEquals(data.messages[1].created, 12345)
end

function TestGetHistory:testMultipleRoles()
  local sid = sessions.new()
  sessions.append_message(sid, {
    role = 'user',
    content = 'Question',
    created = 1001,
  })
  sessions.append_message(sid, {
    role = 'assistant',
    content = 'Answer',
    created = 1002,
  })
  sessions.append_message(sid, {
    role = 'tool',
    content = 'Tool result',
    created = 1003,
  })

  local result = get_history.get_history({}, { session = sid })
  local data = vim.json.decode(result.content)

  lu.assertEquals(#data.messages, 3)
  lu.assertEquals(data.messages[1].role, 'user')
  lu.assertEquals(data.messages[2].role, 'assistant')
  lu.assertEquals(data.messages[3].role, 'tool')
end

function TestGetHistory:testZeroIndexedMessages()
  local sid = sessions.new()
  for i = 1, 5 do
    sessions.append_message(sid, {
      role = 'user',
      content = 'Msg ' .. i,
      created = i,
    })
  end

  local result = get_history.get_history({}, { session = sid })
  local data = vim.json.decode(result.content)

  for i, msg in ipairs(data.messages) do
    lu.assertEquals(msg.index, i - 1)
  end
end

-- ─── get_history() — search ─────────────────────────────────────

function TestGetHistory:testSearchExactMatch()
  local sid = sessions.new()
  sessions.append_message(sid, {
    role = 'user',
    content = 'Hello world',
    created = 1001,
  })
  sessions.append_message(sid, {
    role = 'assistant',
    content = 'Goodbye world',
    created = 1002,
  })
  sessions.append_message(sid, {
    role = 'user',
    content = 'Hello again',
    created = 1003,
  })

  local result = get_history.get_history(
    { search = 'Hello' },
    { session = sid }
  )
  local data = vim.json.decode(result.content)

  lu.assertEquals(data.search, 'Hello')
  lu.assertEquals(data.total_matched, 2)
  lu.assertEquals(data.returned, 2)
  -- Original indices preserved
  lu.assertEquals(data.messages[1].index, 0)
  lu.assertEquals(data.messages[1].content, 'Hello world')
  lu.assertEquals(data.messages[2].index, 2)
  lu.assertEquals(data.messages[2].content, 'Hello again')
end

function TestGetHistory:testSearchCaseInsensitive()
  local sid = sessions.new()
  sessions.append_message(sid, {
    role = 'user',
    content = 'ERROR: something went wrong',
    created = 1001,
  })
  sessions.append_message(sid, {
    role = 'assistant',
    content = 'No issues here',
    created = 1002,
  })

  local result = get_history.get_history(
    { search = 'error' },
    { session = sid }
  )
  local data = vim.json.decode(result.content)

  lu.assertEquals(data.total_matched, 1)
  lu.assertEquals(data.returned, 1)
  lu.assertEquals(data.messages[1].content, 'ERROR: something went wrong')
end

function TestGetHistory:testSearchPartialMatch()
  local sid = sessions.new()
  sessions.append_message(sid, {
    role = 'user',
    content = 'configuring the system',
    created = 1001,
  })
  sessions.append_message(sid, {
    role = 'assistant',
    content = 'Done',
    created = 1002,
  })
  sessions.append_message(sid, {
    role = 'user',
    content = 'config file updated',
    created = 1003,
  })

  local result = get_history.get_history(
    { search = 'config' },
    { session = sid }
  )
  local data = vim.json.decode(result.content)

  lu.assertEquals(data.total_matched, 2)
  lu.assertEquals(data.messages[1].index, 0)
  lu.assertEquals(data.messages[2].index, 2)
end

function TestGetHistory:testSearchNoMatches()
  local sid = sessions.new()
  sessions.append_message(sid, {
    role = 'user',
    content = 'Hello world',
    created = 1001,
  })

  local result = get_history.get_history(
    { search = 'nonexistent' },
    { session = sid }
  )
  lu.assertStrContains(result.content, 'beyond matched message count')
  lu.assertStrContains(result.content, '0')
end

function TestGetHistory:testSearchWithOffsetAndLimit()
  local sid = sessions.new()
  -- Create 10 messages, 5 containing "keyword"
  for i = 1, 10 do
    sessions.append_message(sid, {
      role = 'user',
      content = i % 2 == 0 and 'keyword match ' .. i or 'other message ' .. i,
      created = 1000 + i,
    })
  end

  local result = get_history.get_history(
    { search = 'keyword', offset = 1, limit = 2 },
    { session = sid }
  )
  local data = vim.json.decode(result.content)

  lu.assertEquals(data.search, 'keyword')
  lu.assertEquals(data.total_matched, 5)
  lu.assertEquals(data.offset, 1)
  lu.assertEquals(data.limit, 2)
  lu.assertEquals(data.returned, 2)
end

function TestGetHistory:testSearchOnEmptySession()
  local sid = sessions.new()

  local result = get_history.get_history(
    { search = 'test' },
    { session = sid }
  )
  lu.assertEquals(result.content, 'No messages in session history.')
end

function TestGetHistory:testSearchEmptyStringBehavesLikeNoSearch()
  local sid = sessions.new()
  sessions.append_message(sid, {
    role = 'user',
    content = 'Hello',
    created = 1001,
  })
  sessions.append_message(sid, {
    role = 'assistant',
    content = 'World',
    created = 1002,
  })

  local result = get_history.get_history(
    { search = '' },
    { session = sid }
  )
  local data = vim.json.decode(result.content)

  -- Should return all messages, no search fields in response
  lu.assertIsNil(data.search)
  lu.assertIsNil(data.total_matched)
  lu.assertEquals(data.returned, 2)
end

function TestGetHistory:testSearchResponseFields()
  local sid = sessions.new()
  sessions.append_message(sid, {
    role = 'user',
    content = 'find me',
    created = 1001,
  })

  local result = get_history.get_history(
    { search = 'find' },
    { session = sid }
  )
  local data = vim.json.decode(result.content)

  lu.assertEquals(data.search, 'find')
  lu.assertEquals(data.total_matched, 1)
  lu.assertEquals(data.total, 1)
  lu.assertEquals(data.offset, 0)
  lu.assertEquals(data.limit, 20)
  lu.assertEquals(data.returned, 1)
end

function TestGetHistory:testSearchPreservesOriginalIndices()
  local sid = sessions.new()
  sessions.append_message(sid, {
    role = 'user',
    content = 'apple',
    created = 1001,
  })
  sessions.append_message(sid, {
    role = 'user',
    content = 'banana',
    created = 1002,
  })
  sessions.append_message(sid, {
    role = 'user',
    content = 'apple pie',
    created = 1003,
  })
  sessions.append_message(sid, {
    role = 'user',
    content = 'cherry',
    created = 1004,
  })
  sessions.append_message(sid, {
    role = 'user',
    content = 'apple juice',
    created = 1005,
  })

  local result = get_history.get_history(
    { search = 'apple' },
    { session = sid }
  )
  local data = vim.json.decode(result.content)

  lu.assertEquals(data.total_matched, 3)
  -- Indices should be original positions: 0, 2, 4
  lu.assertEquals(data.messages[1].index, 0)
  lu.assertEquals(data.messages[2].index, 2)
  lu.assertEquals(data.messages[3].index, 4)
end

function TestGetHistory:testSearchOffsetBeyondMatched()
  local sid = sessions.new()
  sessions.append_message(sid, {
    role = 'user',
    content = 'match here',
    created = 1001,
  })
  sessions.append_message(sid, {
    role = 'user',
    content = 'no match',
    created = 1002,
  })

  local result = get_history.get_history(
    { search = 'match', offset = 5 },
    { session = sid }
  )
  lu.assertStrContains(result.content, 'beyond matched message count')
  lu.assertStrContains(result.content, 'match')
end

function TestGetHistory:testSearchSpecialCharacters()
  local sid = sessions.new()
  sessions.append_message(sid, {
    role = 'user',
    content = 'function() return end',
    created = 1001,
  })

  -- Lua pattern special chars should be treated literally
  local result = get_history.get_history(
    { search = '()' },
    { session = sid }
  )
  local data = vim.json.decode(result.content)

  lu.assertEquals(data.total_matched, 1)
  lu.assertEquals(data.returned, 1)
end

-- ─── info() tests ───────────────────────────────────────────────

function TestGetHistory:testInfoDefault()
  local info = get_history.info('{}')
  lu.assertEquals(info, 'get_history(offset=0, limit=20)')
end

function TestGetHistory:testInfoInvalidJson()
  local info = get_history.info('not valid json')
  lu.assertEquals(info, 'get_history')
end

function TestGetHistory:testInfoWithOffsetAndLimit()
  local info = get_history.info('{"offset": 10, "limit": 30}')
  lu.assertEquals(info, 'get_history(offset=10, limit=30)')
end

function TestGetHistory:testInfoWithSearch()
  local info = get_history.info('{"search": "error"}')
  lu.assertEquals(info, 'get_history(search="error", offset=0, limit=20)')
end

function TestGetHistory:testInfoWithSearchOffsetAndLimit()
  local info = get_history.info('{"search": "config", "offset": 5, "limit": 10}')
  lu.assertEquals(info, 'get_history(search="config", offset=5, limit=10)')
end

function TestGetHistory:testInfoWithEmptySearch()
  local info = get_history.info('{"search": ""}')
  lu.assertEquals(info, 'get_history(offset=0, limit=20)')
end

function TestGetHistory:testInfoNilAction()
  local info = get_history.info(nil)
  lu.assertEquals(info, 'get_history')
end

return TestGetHistory

