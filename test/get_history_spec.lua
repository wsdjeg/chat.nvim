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
    -- config.setup() deep-merges, so a budget set by one test would leak
    -- into the next one. Reset both keys to the built-in defaults here;
    -- individual tests override them as needed.
    tools = {
      get_history = {
        default_max_bytes = 32768,
        max_bytes_limit = 204800,
      },
    },
  })
  -- Use a temp directory to avoid polluting real session cache
  self.test_cache_dir = vim.fn.tempname() .. '/'
  sessions.set_cache_dir(self.test_cache_dir)
end

function TestGetHistory:tearDown()
  -- Clean up temp cache directory
  vim.fn.delete(self.test_cache_dir, 'rf')
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

  -- Every branch returns the same JSON shape; an empty session is not a
  -- special text response.
  local data = vim.json.decode(result.content)
  lu.assertEquals(data.total, 0)
  lu.assertEquals(data.returned, 0)
  lu.assertEquals(#data.messages, 0)
  lu.assertStrContains(data.note, 'No messages in session history')
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

function TestGetHistory:testLimitClampedToMaxLimit()
  local sid = sessions.new()
  for i = 1, 260 do
    sessions.append_message(sid, {
      role = 'user',
      content = 'Message ' .. i,
      created = 1000 + i,
    })
  end

  local result = get_history.get_history(
    { limit = 300 },
    { session = sid }
  )
  local data = vim.json.decode(result.content)

  -- The message-count ceiling only keeps offset pagination finite; the byte
  -- budget is the real constraint, so a screenful of short turns is no
  -- longer capped at 50.
  lu.assertEquals(data.limit, 200)
  lu.assertEquals(data.returned, 200)
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

function TestGetHistory:testNegativeOffsetBeyondStartClampsToZero()
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

  -- Only ONE entry exists, so -10 overshoots the start: clamp to 0 rather
  -- than to a negative position.
  lu.assertEquals(data.offset, 0)
  lu.assertEquals(data.returned, 1)
end

function TestGetHistory:testNegativeOffsetReturnsTail()
  local sid = sessions.new()
  for i = 1, 10 do
    sessions.append_message(sid, {
      role = 'user',
      content = 'Message ' .. i,
      created = 1000 + i,
    })
  end

  local result = get_history.get_history(
    { offset = -2 },
    { session = sid }
  )
  local data = vim.json.decode(result.content)

  -- -2 is "the last 2". Clamping to 0 would answer with the OLDEST
  -- messages, the exact opposite of the request.
  lu.assertEquals(data.offset, 8)
  lu.assertEquals(data.returned, 2)
  lu.assertEquals(data.messages[1].index, 8)
  lu.assertEquals(data.messages[1].content, 'Message 9')
  lu.assertEquals(data.messages[2].index, 9)
end

function TestGetHistory:testNegativeOffsetWithLimit()
  local sid = sessions.new()
  for i = 1, 10 do
    sessions.append_message(sid, {
      role = 'user',
      content = 'Message ' .. i,
      created = 1000 + i,
    })
  end

  local result = get_history.get_history(
    { offset = -5, limit = 2 },
    { session = sid }
  )
  local data = vim.json.decode(result.content)

  -- "start at the 5th from the end, take 2"
  lu.assertEquals(data.offset, 5)
  lu.assertEquals(data.returned, 2)
  lu.assertEquals(data.messages[1].index, 5)
end

function TestGetHistory:testNegativeOffsetCountsWithinMatches()
  local sid = sessions.new()
  for i = 1, 10 do
    sessions.append_message(sid, {
      role = 'user',
      content = i % 2 == 0 and 'keyword ' .. i or 'other ' .. i,
      created = 1000 + i,
    })
  end

  local result = get_history.get_history(
    { search = 'keyword', offset = -2 },
    { session = sid }
  )
  local data = vim.json.decode(result.content)

  -- The tail is counted inside the MATCHED set, and the echoed offset is
  -- a position in that set (3 of 5 matches), not a global message index.
  lu.assertEquals(data.total_matched, 5)
  lu.assertEquals(data.offset, 3)
  lu.assertEquals(data.returned, 2)
  -- Matches are messages 2/4/6/8/10 (0-indexed: 1/3/5/7/9): the last two
  -- matched entries are 7 and 9.
  lu.assertEquals(data.messages[1].index, 7)
  lu.assertEquals(data.messages[2].index, 9)
end

function TestGetHistory:testNegativeOffsetEchoesForwardCursor()
  local sid = sessions.new()
  for i = 1, 10 do
    sessions.append_message(sid, {
      role = 'user',
      content = 'Message ' .. i,
      created = 1000 + i,
    })
  end

  local tail = vim.json.decode(get_history.get_history(
    { offset = -4, limit = 2 },
    { session = sid }
  ).content)

  -- A paginating caller needs a non-negative cursor it can continue from.
  local next_page = vim.json.decode(get_history.get_history(
    { offset = tail.offset + tail.limit, limit = 2 },
    { session = sid }
  ).content)

  lu.assertEquals(next_page.messages[1].index, 8)
  lu.assertEquals(next_page.messages[2].index, 9)
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
  local data = vim.json.decode(result.content)
  lu.assertEquals(data.returned, 0)
  lu.assertEquals(data.total, 5)
  lu.assertStrContains(data.note, 'beyond total message count')
  lu.assertStrContains(data.note, '5')
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
  local data = vim.json.decode(result.content)
  lu.assertEquals(data.returned, 0)
  lu.assertStrContains(data.note, 'beyond total message count')
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
  local data = vim.json.decode(result.content)
  lu.assertEquals(data.total_matched, 0)
  lu.assertEquals(data.returned, 0)
  lu.assertStrContains(data.note, 'beyond matched message count')
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
  local data = vim.json.decode(result.content)
  lu.assertEquals(data.returned, 0)
  lu.assertStrContains(data.note, 'No messages in session history')
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
  local data = vim.json.decode(result.content)
  lu.assertEquals(data.returned, 0)
  lu.assertStrContains(data.note, 'beyond matched message count')
  lu.assertStrContains(data.note, 'match')
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

-- ─── get_history() — byte budget ────────────────────────────────

function TestGetHistory:testSchemeHasMaxBytesProperty()
  local scheme = get_history.scheme()
  lu.assertNotNil(scheme['function'].parameters.properties.max_bytes)
  lu.assertEquals(
    scheme['function'].parameters.properties.max_bytes.type,
    'integer'
  )
end

function TestGetHistory:testMaxBytesDefaultReportedInResponse()
  local sid = sessions.new()
  sessions.append_message(sid, {
    role = 'user',
    content = 'Hello',
    created = 1001,
  })

  local result = get_history.get_history({}, { session = sid })
  local data = vim.json.decode(result.content)

  lu.assertEquals(data.max_bytes, 32768)
  lu.assertIsNil(data.truncated)
  lu.assertIsNil(data.next_offset)
end

function TestGetHistory:testMaxBytesBelowFloorClampedUp()
  local sid = sessions.new()
  sessions.append_message(sid, {
    role = 'user',
    content = 'Hello',
    created = 1001,
  })

  local result = get_history.get_history(
    { max_bytes = 10 },
    { session = sid }
  )
  local data = vim.json.decode(result.content)

  lu.assertEquals(data.max_bytes, 2048)
end

function TestGetHistory:testMaxBytesAboveCeilingClampedDown()
  local sid = sessions.new()
  sessions.append_message(sid, {
    role = 'user',
    content = 'Hello',
    created = 1001,
  })

  local result = get_history.get_history(
    { max_bytes = 10 * 1024 * 1024 },
    { session = sid }
  )
  local data = vim.json.decode(result.content)

  lu.assertEquals(data.max_bytes, 204800)
end

function TestGetHistory:testMaxBytesNonNumberFallsBackToDefault()
  local sid = sessions.new()
  sessions.append_message(sid, {
    role = 'user',
    content = 'Hello',
    created = 1001,
  })

  local result = get_history.get_history(
    { max_bytes = '1024' },
    { session = sid }
  )
  local data = vim.json.decode(result.content)

  lu.assertEquals(data.max_bytes, 32768)
end

-- ─── get_history() — configurable byte budget ───────────────────

--- Create a session with one small message, ready for budget assertions.
---@return string sid
function TestGetHistory:smallSession()
  local sid = sessions.new()
  sessions.append_message(sid, {
    role = 'user',
    content = 'Hello',
    created = 1001,
  })
  return sid
end

function TestGetHistory:testConfigDefaultMaxBytesApplied()
  config.setup({
    tools = { get_history = { default_max_bytes = 65536 } },
  })
  local sid = self:smallSession()

  -- max_bytes omitted: the configured default must be what the response
  -- reports, not the hardcoded fallback.
  local data = vim.json.decode(
    get_history.get_history({}, { session = sid }).content
  )
  lu.assertEquals(data.max_bytes, 65536)
end

function TestGetHistory:testConfigLimitClampsExplicitMaxBytes()
  config.setup({
    tools = { get_history = { max_bytes_limit = 51200 } },
  })
  local sid = self:smallSession()

  local data = vim.json.decode(
    get_history.get_history({ max_bytes = 10 * 1024 * 1024 }, { session = sid }).content
  )
  lu.assertEquals(data.max_bytes, 51200)
end

function TestGetHistory:testConfigLimitNeverBelowDefault()
  -- A config that raised only the default would otherwise cap explicit
  -- values below the no-argument budget, which is nonsense: asking for
  -- max_bytes=61440 would silently return 8192.
  config.setup({
    tools = { get_history = { default_max_bytes = 61440, max_bytes_limit = 8192 } },
  })
  local sid = self:smallSession()

  -- Explicit value equal to the default survives: the effective ceiling is
  -- max(limit, default) = 61440.
  local data = vim.json.decode(
    get_history.get_history({ max_bytes = 61440 }, { session = sid }).content
  )
  lu.assertEquals(data.max_bytes, 61440)
end

function TestGetHistory:testConfigExplicitSmallBudgetHonored()
  config.setup({
    tools = { get_history = { default_max_bytes = 61440, max_bytes_limit = 8192 } },
  })
  local sid = self:smallSession()

  -- An explicit small value is a deliberate caller choice, not a default:
  -- it must not be raised to the (larger) default.
  local data = vim.json.decode(
    get_history.get_history({ max_bytes = 8192 }, { session = sid }).content
  )
  lu.assertEquals(data.max_bytes, 8192)
end

function TestGetHistory:testConfigInvalidBudgetFallsBack()
  config.setup({
    tools = { get_history = { default_max_bytes = 'big', max_bytes_limit = -1 } },
  })
  local sid = self:smallSession()

  local data = vim.json.decode(
    get_history.get_history({}, { session = sid }).content
  )
  -- 'big' is not a number and -1 is not positive: both fall back.
  lu.assertEquals(data.max_bytes, 32768)
end

function TestGetHistory:testConfigBudgetBelowFloorClampedUp()
  config.setup({
    tools = { get_history = { default_max_bytes = 100 } },
  })
  local sid = self:smallSession()

  local data = vim.json.decode(
    get_history.get_history({}, { session = sid }).content
  )
  -- The response envelope cannot fit below the floor.
  lu.assertEquals(data.max_bytes, 2048)
end

function TestGetHistory:testStringOffsetDoesNotRaise()
  config.setup({
    tools = { get_history = { default_max_bytes = 32768, max_bytes_limit = 204800 } },
  })
  local sid = sessions.new()
  for i = 1, 5 do
    sessions.append_message(sid, {
      role = 'user',
      content = 'Message ' .. i,
      created = 1000 + i,
    })
  end

  -- Models sometimes emit numeric strings; a crash here would cost a whole
  -- request round trip.
  local data = vim.json.decode(
    get_history.get_history(
      { offset = '3', limit = '2' },
      { session = sid }
    ).content
  )
  lu.assertEquals(data.offset, 3)
  lu.assertEquals(data.limit, 2)
  lu.assertEquals(data.messages[1].index, 3)
end

function TestGetHistory:testBytesFieldMatchesContentLength()
  local sid = sessions.new()
  for i = 1, 3 do
    sessions.append_message(sid, {
      role = 'user',
      content = 'Message ' .. i,
      created = 1000 + i,
    })
  end

  local result = get_history.get_history({}, { session = sid })
  local data = vim.json.decode(result.content)

  -- The reported size is the size of the payload that was sent.
  lu.assertEquals(data.bytes, #result.content)
end

function TestGetHistory:testLargeContentTruncated()
  local sid = sessions.new()
  local big = string.rep('word ', 20000) -- ~100 KB of content
  sessions.append_message(sid, {
    role = 'tool',
    content = big,
    created = 1001,
  })

  local result = get_history.get_history(
    { max_bytes = 4096 },
    { session = sid }
  )

  -- Never exceed the requested budget
  lu.assertTrue(#result.content <= 4096, 'response exceeded max_bytes')

  local data = vim.json.decode(result.content)
  lu.assertEquals(data.truncated, true)
  -- The head of message 0 was returned, so paging continues AFTER it; the
  -- rest of that message is read again by raising max_bytes.
  lu.assertEquals(data.next_offset, 1)
  lu.assertNotNil(data.note)
  -- "Increase max_bytes" is not actionable; the note names the exact
  -- budget a retry needs.
  lu.assertStrContains(data.note, 'retry with max_bytes=')
  lu.assertNotNil(data.required_bytes)
  lu.assertEquals(data.returned, 1)

  -- The head of the message is kept, marked as truncated
  local msg = data.messages[1]
  lu.assertEquals(msg.index, 0)
  lu.assertEquals(msg.role, 'tool')
  lu.assertEquals(msg.content_truncated, true)
  lu.assertEquals(msg.original_bytes, #big)
  lu.assertTrue(#msg.content < #big)
  lu.assertStrContains(msg.content, 'word')
  lu.assertStrContains(msg.content, 'Content truncated')
end

function TestGetHistory:testTruncatedContentStaysValidUtf8()
  local sid = sessions.new()
  -- Multi-byte characters: a byte-based cut would split a codepoint
  local big = string.rep('中文内容测试', 8000)
  sessions.append_message(sid, {
    role = 'tool',
    content = big,
    created = 1001,
  })

  local result = get_history.get_history(
    { max_bytes = 2048 },
    { session = sid }
  )

  lu.assertTrue(#result.content <= 2048, 'response exceeded max_bytes')
  -- Decoding fails on invalid UTF-8, so this asserts the cut was clean
  local ok, data = pcall(vim.json.decode, result.content)
  lu.assertTrue(ok, 'truncated payload is not valid JSON/UTF-8')
  lu.assertEquals(data.messages[1].content_truncated, true)
end

function TestGetHistory:testBudgetStopsAfterFittingMessages()
  local sid = sessions.new()
  -- 10 messages of ~4 KB each
  for i = 1, 10 do
    sessions.append_message(sid, {
      role = 'user',
      content = string.rep('x', 4000),
      created = 1000 + i,
    })
  end

  local result = get_history.get_history(
    { limit = 10, max_bytes = 8192 },
    { session = sid }
  )

  lu.assertTrue(#result.content <= 8192, 'response exceeded max_bytes')

  local data = vim.json.decode(result.content)
  lu.assertEquals(data.total, 10)
  lu.assertEquals(data.returned, #data.messages)
  lu.assertTrue(data.returned < 10, 'budget did not limit the result')
  lu.assertEquals(data.truncated, true)
  -- next_offset points at the first incomplete message
  lu.assertEquals(data.next_offset, data.messages[#data.messages].index + 1)
end

function TestGetHistory:testContinueFromNextOffset()
  local sid = sessions.new()
  for i = 1, 10 do
    sessions.append_message(sid, {
      role = 'user',
      content = string.rep('y', 4000),
      created = 1000 + i,
    })
  end

  local first = vim.json.decode(get_history.get_history(
    { limit = 10, max_bytes = 8192 },
    { session = sid }
  ).content)

  local second = vim.json.decode(get_history.get_history(
    { offset = first.next_offset, limit = 10, max_bytes = 8192 },
    { session = sid }
  ).content)

  lu.assertEquals(second.offset, first.next_offset)
  lu.assertTrue(second.returned > 0)
  lu.assertEquals(second.messages[1].index, first.next_offset)
end

function TestGetHistory:testTruncationWithSearch()
  local sid = sessions.new()
  sessions.append_message(sid, {
    role = 'user',
    content = 'match ' .. string.rep('a', 6000),
    created = 1001,
  })
  sessions.append_message(sid, {
    role = 'user',
    content = 'match ' .. string.rep('b', 6000),
    created = 1002,
  })

  local result = get_history.get_history(
    { search = 'match', max_bytes = 4096 },
    { session = sid }
  )

  lu.assertTrue(#result.content <= 4096, 'response exceeded max_bytes')
  local data = vim.json.decode(result.content)
  lu.assertEquals(data.search, 'match')
  lu.assertEquals(data.total_matched, 2)
  lu.assertEquals(data.truncated, true)
end

-- ─── get_history() — pagination numbering ───────────────────────

function TestGetHistory:testNextMessageIndexSkipsDroppedEntries()
  local sid = sessions.new()
  -- Real turns interleaved with on_complete bookkeeping markers: after
  -- filtering, working positions (the pagination cursor) no longer match
  -- the global message indices.
  for i = 1, 6 do
    sessions.append_message(sid, {
      role = 'user',
      content = string.rep('z', 4000),
      created = 1000 + i,
    })
    sessions.append_message(sid, {
      on_complete = true,
      usage = { total_tokens = i },
      created = 1000 + i,
    })
  end

  local data = vim.json.decode(get_history.get_history(
    { limit = 10, max_bytes = 8192 },
    { session = sid }
  ).content)

  lu.assertEquals(data.truncated, true)
  lu.assertNotNil(data.next_offset)
  lu.assertNotNil(data.next_message_index)
  -- Two numbering systems on purpose: the cursor (position in the working
  -- set) and the stable global index. Every filtered marker pushes them
  -- further apart.
  lu.assertTrue(data.next_message_index > data.next_offset)

  -- Following the cursor lands exactly on the advertised index.
  local next_page = vim.json.decode(get_history.get_history(
    { offset = data.next_offset, limit = 1, max_bytes = 8192 },
    { session = sid }
  ).content)
  lu.assertEquals(next_page.messages[1].index, data.next_message_index)
end

function TestGetHistory:testNextMessageIndexWithSearch()
  local sid = sessions.new()
  sessions.append_message(sid, {
    role = 'user',
    content = 'gap filler',
    created = 1001,
  })
  sessions.append_message(sid, {
    role = 'user',
    content = 'match ' .. string.rep('a', 6000),
    created = 1002,
  })
  sessions.append_message(sid, {
    role = 'user',
    content = 'gap filler',
    created = 1003,
  })
  sessions.append_message(sid, {
    role = 'user',
    content = 'match ' .. string.rep('b', 6000),
    created = 1004,
  })

  local data = vim.json.decode(get_history.get_history(
    { search = 'match', limit = 5, max_bytes = 4096 },
    { session = sid }
  ).content)

  lu.assertEquals(data.total_matched, 2)
  lu.assertEquals(data.truncated, true)
  -- Under search the cursor counts matches while next_message_index stays a
  -- global message index: conflating them re-reads the wrong message.
  lu.assertEquals(data.next_message_index, 3)

  local next_page = vim.json.decode(get_history.get_history(
    { search = 'match', offset = data.next_offset, max_bytes = 4096 },
    { session = sid }
  ).content)
  lu.assertEquals(next_page.messages[1].index, data.next_message_index)
end

function TestGetHistory:testNoNextMessageIndexWhenPageIsExhausted()
  local sid = sessions.new()
  sessions.append_message(sid, {
    role = 'tool',
    content = string.rep('q', 20000),
    created = 1001,
  })

  local data = vim.json.decode(get_history.get_history(
    { max_bytes = 4096 },
    { session = sid }
  ).content)

  lu.assertEquals(data.truncated, true)
  -- The last (and only) message's head was returned; there is nothing
  -- after it, so no forward cursor is advertised.
  lu.assertEquals(data.next_offset, 1)
  lu.assertIsNil(data.next_message_index)
end

-- ─── get_history() — actionable retry budget ───────────────────

function TestGetHistory:testRequiredBytesRetryReadsWholeMessage()
  local sid = sessions.new()
  local big = string.rep('word ', 20000) -- ~100 KB
  sessions.append_message(sid, {
    role = 'tool',
    content = big,
    created = 1001,
  })

  local first = vim.json.decode(get_history.get_history(
    { max_bytes = 4096 },
    { session = sid }
  ).content)

  lu.assertEquals(first.truncated, true)
  lu.assertEquals(first.messages[1].content_truncated, true)
  lu.assertNotNil(first.required_bytes)
  lu.assertTrue(first.required_bytes > 4096)
  lu.assertStrContains(first.note, 'retry with max_bytes=')

  -- The advertised budget must work on the FIRST retry: no bisection, no
  -- repeated probing, which is what an adjective ("increase max_bytes")
  -- forces on the caller.
  local retry = vim.json.decode(get_history.get_history(
    { max_bytes = first.required_bytes },
    { session = sid }
  ).content)

  lu.assertIsNil(retry.truncated)
  lu.assertIsNil(retry.required_bytes)
  lu.assertIsNil(retry.messages[1].content_truncated)
  lu.assertEquals(retry.messages[1].content, big)
end

function TestGetHistory:testRequiredBytesOmittedAboveCeiling()
  local sid = sessions.new()
  -- ~300 KB cannot fit under the 204800 ceiling, so no retry budget is
  -- advertised: a value above the ceiling would be clamped back down and
  -- silently repeat the same result.
  local huge = string.rep('word ', 60000)
  sessions.append_message(sid, {
    role = 'tool',
    content = huge,
    created = 1001,
  })

  local result = get_history.get_history(
    { max_bytes = 4096 },
    { session = sid }
  )

  lu.assertTrue(#result.content <= 4096, 'response exceeded max_bytes')
  local data = vim.json.decode(result.content)
  lu.assertIsNil(data.required_bytes)
  lu.assertStrContains(data.note, 'ceiling')
end

function TestGetHistory:testRequiredBytesAbsentWhenNothingWasCut()
  local sid = sessions.new()
  sessions.append_message(sid, {
    role = 'user',
    content = 'small',
    created = 1001,
  })

  local data = vim.json.decode(get_history.get_history(
    {},
    { session = sid }
  ).content)

  lu.assertIsNil(data.truncated)
  lu.assertIsNil(data.required_bytes)
  lu.assertIsNil(data.next_message_index)
end

-- ─── get_history() — entry classification ──────────────────────

function TestGetHistory:testBookkeepingMarkersAreDropped()
  local sid = sessions.new()
  sessions.append_message(sid, {
    role = 'user',
    content = 'Question',
    created = 1001,
  })
  -- What sessions/tools.lua appends after every finished request: usage
  -- bookkeeping with neither role nor content.
  sessions.append_message(sid, {
    on_complete = true,
    usage = { total_tokens = 120 },
    created = 1002,
  })

  local result = get_history.get_history({}, { session = sid })
  local data = vim.json.decode(result.content)

  lu.assertEquals(data.total, 1)
  lu.assertEquals(data.returned, 1)
  lu.assertEquals(#data.messages, 1)
  lu.assertEquals(data.messages[1].role, 'user')
end

function TestGetHistory:testBookkeepingDoesNotConsumeLimit()
  local sid = sessions.new()
  for i = 1, 10 do
    sessions.append_message(sid, {
      role = 'user',
      content = 'Message ' .. i,
      created = 1000 + i,
    })
    sessions.append_message(sid, {
      on_complete = true,
      usage = { total_tokens = i },
      created = 1000 + i,
    })
  end

  local result = get_history.get_history({}, { session = sid })
  local data = vim.json.decode(result.content)

  -- 10 real messages fit inside the default limit of 20; before the fix
  -- the 10 markers ate half the slots and only 10 of 20 were returned.
  lu.assertEquals(data.total, 10)
  lu.assertEquals(data.returned, 10)
end

function TestGetHistory:testErrorMessageKeptWithKind()
  local sid = sessions.new()
  sessions.append_message(sid, {
    role = 'user',
    content = 'Do something',
    created = 1001,
  })
  sessions.append_message(sid, {
    error = 'Request cancelled by user.',
    created = 1002,
  })

  local result = get_history.get_history({}, { session = sid })
  local data = vim.json.decode(result.content)

  lu.assertEquals(data.total, 2)
  local error_entry = data.messages[2]
  lu.assertEquals(error_entry.kind, 'error')
  lu.assertIsNil(error_entry.role)
  lu.assertEquals(error_entry.content, 'Request cancelled by user.')
end

function TestGetHistory:testNoticeKeptWithKind()
  local sid = sessions.new()
  sessions.append_message(sid, {
    role = 'user',
    content = 'Hello',
    created = 1001,
  })
  sessions.append_message(sid, {
    notice = 'API key #2 rotated after rate limit',
    created = 1002,
  })

  local result = get_history.get_history({}, { session = sid })
  local data = vim.json.decode(result.content)

  local notice_entry = data.messages[2]
  lu.assertEquals(notice_entry.kind, 'notice')
  lu.assertEquals(
    notice_entry.content,
    'API key #2 rotated after rate limit'
  )
end

function TestGetHistory:testConversationalEntriesAreKindMessage()
  local sid = sessions.new()
  sessions.append_message(sid, {
    role = 'user',
    content = 'Hi',
    created = 1001,
  })

  local result = get_history.get_history({}, { session = sid })
  local data = vim.json.decode(result.content)

  lu.assertEquals(data.messages[1].kind, 'message')
end

function TestGetHistory:testTotalCountsNonConversationalEntries()
  local sid = sessions.new()
  sessions.append_message(sid, {
    role = 'user',
    content = 'Hi',
    created = 1001,
  })
  sessions.append_message(sid, {
    notice = 'rotated',
    created = 1002,
  })
  sessions.append_message(sid, {
    on_complete = true,
    usage = { total_tokens = 10 },
    created = 1003,
  })

  local result = get_history.get_history({}, { session = sid })
  local data = vim.json.decode(result.content)

  -- total counts everything that carries information: the real turn plus
  -- the notice, but not the bookkeeping marker.
  lu.assertEquals(data.total, 2)
end

-- ─── get_history() — tool context ───────────────────────────────

function TestGetHistory:testAssistantToolCallNamesOnly()
  local sid = sessions.new()
  sessions.append_message(sid, {
    role = 'assistant',
    tool_calls = {
      {
        id = 'call_1',
        type = 'function',
        ['function'] = {
          name = 'read_file',
          arguments = '{"filepath":"./lua/chat/tools/get_history.lua"}',
        },
      },
      {
        id = 'call_2',
        type = 'function',
        ['function'] = {
          name = 'git_add',
          arguments = '{"path":"lua/chat/tools/get_history.lua"}',
        },
      },
    },
    created = 1001,
  })

  local result = get_history.get_history({}, { session = sid })
  local data = vim.json.decode(result.content)

  local entry = data.messages[1]
  lu.assertEquals(#entry.tool_calls, 2)
  -- Names only: the model already wrote the arguments, and they can be
  -- hundreds of bytes each.
  lu.assertEquals(entry.tool_calls[1], 'read_file')
  lu.assertEquals(entry.tool_calls[2], 'git_add')
  lu.assertIsNil(entry.tool_calls[1].arguments)
end

function TestGetHistory:testToolResultCarriesToolName()
  local sid = sessions.new()
  sessions.append_message(sid, {
    role = 'tool',
    content = 'No changes found.',
    tool_call_id = 'call_1',
    tool_call_state = { name = 'git_diff' },
    created = 1001,
  })

  local result = get_history.get_history({}, { session = sid })
  local data = vim.json.decode(result.content)

  lu.assertEquals(data.messages[1].tool, 'git_diff')
end

function TestGetHistory:testToolResultWithoutStateDoesNotRaise()
  local sid = sessions.new()
  -- Older caches predate tool_call_state.
  sessions.append_message(sid, {
    role = 'tool',
    content = 'legacy result',
    tool_call_id = 'call_1',
    created = 1001,
  })

  local result = get_history.get_history({}, { session = sid })
  local data = vim.json.decode(result.content)

  lu.assertEquals(data.returned, 1)
  lu.assertEquals(data.messages[1].role, 'tool')
  lu.assertIsNil(data.messages[1].tool)
end

function TestGetHistory:testToolCallNamesSkipsMalformedEntries()
  local sid = sessions.new()
  sessions.append_message(sid, {
    role = 'assistant',
    tool_calls = {
      { id = 'ok', ['function'] = { name = 'read_file' } },
      { id = 'no_function' },
      { ['function'] = { name = '' } },
    },
    created = 1001,
  })

  local result = get_history.get_history({}, { session = sid })
  local data = vim.json.decode(result.content)

  lu.assertEquals(#data.messages[1].tool_calls, 1)
  lu.assertEquals(data.messages[1].tool_calls[1], 'read_file')
end

function TestGetHistory:testSearchMatchesReasoningContent()
  local sid = sessions.new()
  sessions.append_message(sid, {
    role = 'assistant',
    content = 'The answer is 42.',
    reasoning_content = 'I should reconsider the config default.',
    created = 1001,
  })

  local result = get_history.get_history(
    { search = 'config' },
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

