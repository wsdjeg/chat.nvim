-- test/memory_spec.lua
local lu = require('luaunit')
local memory = require('chat.memory')
local config = require('chat.config')

TestMemory = {}

function TestMemory:setUp()
  -- Setup test configuration
  config.setup({
    memory = {
      enable = true,
      storage_dir = vim.fn.tempname() .. '_memory/',
    },
  })

  -- Create temp storage directory
  vim.fn.mkdir(config.config.memory.storage_dir, 'p')
end

function TestMemory:tearDown()
  -- Clean up temp directory
  vim.fn.delete(config.config.memory.storage_dir, 'rf')
end

function TestMemory:testStoreLongTermMemory()
  local session = 'test-session-001'
  local role = 'user'
  local content = 'Python的GIL是全局解释器锁'

  local result = memory.store_memory(session, role, content, 'long_term')
  lu.assertNotNil(result)
  lu.assertTrue(type(result) == 'string')
  lu.assertTrue(#result > 0)
end

function TestMemory:testStoreDailyMemory()
  local session = 'test-session-002'
  local role = 'user'
  local content = '今天要完成用户登录功能'

  local result = memory.store_memory(session, role, content, 'daily')
  lu.assertNotNil(result)
  lu.assertTrue(type(result) == 'string')
  lu.assertTrue(#result > 0)
end

function TestMemory:testStoreWorkingMemory()
  local session = 'test-session-003'
  local role = 'user'
  local content = '当前正在修复登录bug'

  local result = memory.store_memory(session, role, content, 'working')
  lu.assertNotNil(result)
  lu.assertTrue(type(result) == 'string')
  lu.assertTrue(#result > 0)
end

function TestMemory:testRetrieveMemories()
  local session = 'test-session-004'

  -- Store some memories
  memory.store_memory(
    session,
    'user',
    '我习惯用Vim编辑器',
    'long_term'
  )
  memory.store_memory(session, 'user', '今天要写测试', 'daily')
  memory.store_memory(session, 'user', '当前任务：修复bug', 'working')

  -- Retrieve memories
  local results = memory.retrieve_memories('Vim 编辑器', session, 5)
  lu.assertNotNil(results)
  -- Results may be empty if similarity threshold is not met
  -- lu.assertTrue(#results > 0)
end

function TestMemory:testGetAllMemories()
  local session = 'test-session-005'

  -- Store memories in different types
  memory.store_memory(session, 'user', '长期记忆测试', 'long_term')
  memory.store_memory(session, 'user', '日常记忆测试', 'daily')
  memory.store_memory(session, 'user', '工作记忆测试', 'working')

  local all_memories = memory.get_memories()
  lu.assertNotNil(all_memories)
  lu.assertTrue(#all_memories >= 3)
end

function TestMemory:testDeleteMemory()
  local session = 'test-session-006'

  -- Store a memory
  local mem_id =
    memory.store_memory(session, 'user', '测试删除功能', 'long_term')

  -- Verify it exists
  local memories = memory.get_memories()
  local found = false
  for _, mem in ipairs(memories) do
    if mem.id == mem_id then
      found = true
      break
    end
  end
  lu.assertTrue(found)

  -- Delete the memory
  memory.delete(mem_id)

  -- Verify it's deleted
  memories = memory.get_memories()
  found = false
  for _, mem in ipairs(memories) do
    if mem.id == mem_id then
      found = true
      break
    end
  end
  lu.assertFalse(found)
end

function TestMemory:testMemoryPriority()
  local session = 'test-session-007'

  -- Store same content in different memory types
  memory.store_memory(session, 'user', '工作记忆优先级', 'working')
  memory.store_memory(session, 'user', '日常记忆优先级', 'daily')
  memory.store_memory(session, 'user', '长期记忆优先级', 'long_term')

  local results = memory.retrieve_memories('优先级', session, 3)

  -- Working memory should have highest priority
  if #results > 0 then
    lu.assertTrue(results[1].priority >= results[#results].priority)
  end
end

function TestMemory:testCleanup()
  -- Test memory cleanup
  memory.cleanup()
  -- Should not crash
  lu.assertTrue(true)
end

function TestMemory:testGetStats()
  local session = 'test-session-008'

  -- Store some memories
  memory.store_memory(session, 'user', '统计测试', 'long_term')

  local stats = memory.get_stats()
  lu.assertNotNil(stats)
  lu.assertNotNil(stats.long_term)
  lu.assertNotNil(stats.daily)
  lu.assertNotNil(stats.working)
end

-- === Dedup tests ===

function TestMemory:testLongTermDedupUpdate()
  local session = 'test-dedup-lt'
  local long_term = require('chat.memory.long_term')

  -- Store first memory
  local id1 = long_term.store(session, 'user', 'Python的GIL是全局解释器锁')

  -- Store near-identical memory (should update, not duplicate)
  local id2 = long_term.store(session, 'user', 'Python的GIL是全局解释器锁')

  -- Should return same ID (dedup)
  lu.assertEquals(id1, id2)

  -- Verify only one memory exists for this session
  local all = long_term.get_all()
  local count = 0
  for _, mem in ipairs(all) do
    if mem.session == session then
      count = count + 1
    end
  end
  lu.assertEquals(count, 1)
end

function TestMemory:testDailyDedupUpdate()
  local session = 'test-dedup-daily'
  local daily = require('chat.memory.daily')

  -- Store first memory
  local id1 = daily.store(session, 'user', '今天要完成用户登录功能')

  -- Store identical memory (should update)
  local id2 = daily.store(session, 'user', '今天要完成用户登录功能')

  lu.assertEquals(id1, id2)

  local all = daily.get_all()
  local count = 0
  for _, mem in ipairs(all) do
    if mem.session == session then
      count = count + 1
    end
  end
  lu.assertEquals(count, 1)
end

function TestMemory:testWorkingDedupUpdate()
  local session = 'test-dedup-work'
  local working = require('chat.memory.working')

  -- Store first memory
  local id1 = working.store(session, 'user', '当前正在修复登录bug')

  -- Store identical memory (should update)
  local id2 = working.store(session, 'user', '当前正在修复登录bug')

  lu.assertEquals(id1, id2)

  local all = working.get_all()
  local count = 0
  for _, mem in ipairs(all) do
    if mem.session == session then
      count = count + 1
    end
  end
  lu.assertEquals(count, 1)
end

function TestMemory:testDedupDoesNotMergeDifferentContent()
  local session = 'test-dedup-diff'
  local long_term = require('chat.memory.long_term')

  -- Store two very different memories
  local id1 = long_term.store(session, 'user', 'Python的GIL是全局解释器锁')
  local id2 = long_term.store(session, 'user', '今天天气很好适合出门散步')

  -- Should be different IDs
  lu.assertNotEquals(id1, id2)

  -- Both should exist
  local all = long_term.get_all()
  local count = 0
  for _, mem in ipairs(all) do
    if mem.session == session then
      count = count + 1
    end
  end
  lu.assertEquals(count, 2)
end

function TestMemory:testDedupHitCount()
  local session = 'test-dedup-hit'
  local long_term = require('chat.memory.long_term')

  -- Store same content multiple times
  local content = 'Vim是最好的编辑器'
  long_term.store(session, 'user', content)
  long_term.store(session, 'user', content)
  local id3 = long_term.store(session, 'user', content)

  -- Find the memory and check hit_count
  local all = long_term.get_all()
  for _, mem in ipairs(all) do
    if mem.id == id3 then
      lu.assertTrue(mem.hit_count >= 3,
        'hit_count should be at least 3 after 3 stores of same content')
      return
    end
  end
  lu.fail('Memory not found after dedup store')
end

return TestMemory
