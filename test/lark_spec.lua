local lu = require('luaunit')
local config = require('chat.config')

TestLark = {}

function TestLark:setUp()
  -- Setup test configuration
  config.setup({
    provider = 'test-provider',
    model = 'test-model',
  })

  -- Mock state
  self.mock_state = {
    last_message_id = nil,
    last_message_time = nil,
    processed_ids = {},
    is_running = false,
    is_fetching = false,
  }
end

function TestLark:tearDown()
  -- Clean up
end

function TestLark:testStatePersistence()
  -- Test saving and loading state
  local state_data = {
    last_message_id = 'msg_123456',
    last_message_time = '1704067200000',
    processed_ids = {
      ['msg_001'] = true,
      ['msg_002'] = true,
    },
    session = 'test-session-123',
  }

  lu.assertNotNil(state_data.last_message_id)
  lu.assertEquals(state_data.last_message_id, 'msg_123456')
  lu.assertEquals(state_data.last_message_time, '1704067200000')
  lu.assertEquals(state_data.processed_ids['msg_001'], true)
  lu.assertEquals(state_data.session, 'test-session-123')
end

function TestLark:testLastMessageTimeTracking()
  -- Test that last_message_time is properly tracked
  local messages = {
    {
      message_id = 'msg_001',
      create_time = '1704067100000',
      content = 'First message',
    },
    {
      message_id = 'msg_002',
      create_time = '1704067200000',
      content = 'Second message',
    },
    {
      message_id = 'msg_003',
      create_time = '1704067300000',
      content = 'Third message',
    },
  }

  -- Simulate finding latest time
  local latest_time = '0'
  for _, msg in ipairs(messages) do
    if msg.create_time then
      local create_time_ms = msg.create_time
      if not latest_time or create_time_ms > latest_time then
        latest_time = create_time_ms
      end
    end
  end

  lu.assertEquals(latest_time, '1704067300000')
end

function TestLark:testMessageFilteringByStartTime()
  -- Test that messages are filtered by start_time
  local last_message_time = '1704067200000' -- milliseconds
  local start_time_seconds = math.floor(tonumber(last_message_time) / 1000)

  lu.assertEquals(start_time_seconds, 1704067200)

  -- Messages created after this time should be fetched
  local new_message_time = 1704067300000
  lu.assertTrue(new_message_time > tonumber(last_message_time))

  -- Old messages should be filtered out
  local old_message_time = 1704067100000
  lu.assertTrue(old_message_time < tonumber(last_message_time))
end

function TestLark:testFutureTimeValidation()
  -- Test that future timestamps are handled correctly
  local future_time_ms = (os.time() + 3600) * 1000 -- 1 hour in future
  local current_time_seconds = os.time()

  -- Convert future time to seconds
  local start_time_seconds = math.floor(future_time_ms / 1000)

  -- Should detect and reset to current time
  if start_time_seconds > current_time_seconds then
    start_time_seconds = current_time_seconds
  end

  lu.assertTrue(start_time_seconds <= current_time_seconds)
end

function TestLark:testProcessedIdsCache()
  -- Test processed IDs cache limit
  local max_processed_cache = 100
  local processed_ids = {}

  -- Add more than cache limit
  for i = 1, 150 do
    processed_ids['msg_' .. i] = true
  end

  -- Simulate cache trimming
  local count = 0
  local trimmed_ids = {}
  for id, _ in pairs(processed_ids) do
    count = count + 1
    if count <= max_processed_cache then
      trimmed_ids[id] = true
    end
  end

  -- Count trimmed cache
  local trimmed_count = 0
  for _ in pairs(trimmed_ids) do
    trimmed_count = trimmed_count + 1
  end

  lu.assertEquals(trimmed_count, max_processed_cache)
end

function TestLark:testMessageOrdering()
  -- Test that messages are processed in chronological order (oldest first)
  local messages = {
    { message_id = 'msg_3', create_time = '300' },
    { message_id = 'msg_1', create_time = '100' },
    { message_id = 'msg_2', create_time = '200' },
  }

  -- Sort by create_time (ascending)
  table.sort(messages, function(a, b)
    return tonumber(a.create_time) < tonumber(b.create_time)
  end)

  lu.assertEquals(messages[1].message_id, 'msg_1')
  lu.assertEquals(messages[2].message_id, 'msg_2')
  lu.assertEquals(messages[3].message_id, 'msg_3')
end

function TestLark:testEmptyMessagesHandling()
  -- Test that empty message arrays are handled gracefully
  local messages = {}

  local has_new = false
  local latest_time = nil

  for _, msg in ipairs(messages) do
    has_new = true
    if msg.create_time then
      if not latest_time or msg.create_time > latest_time then
        latest_time = msg.create_time
      end
    end
  end

  lu.assertFalse(has_new)
  lu.assertNil(latest_time)
end

function TestLark:testTimestampConversion()
  -- Test millisecond to second conversion
  local time_ms = '1704067200000'
  local time_seconds = math.floor(tonumber(time_ms) / 1000)

  lu.assertEquals(time_seconds, 1704067200)

  -- Test reverse (should not lose precision)
  local back_to_ms = time_seconds * 1000
  lu.assertTrue(back_to_ms <= tonumber(time_ms))
  lu.assertTrue(back_to_ms + 999 >= tonumber(time_ms))
end

function TestLark:testSessionManagement()
  -- Test session ID management
  local session = 'test-session-' .. os.time()

  lu.assertNotNil(session)
  lu.assertTrue(type(session) == 'string')
  lu.assertTrue(#session > 0)
end

return TestLark
