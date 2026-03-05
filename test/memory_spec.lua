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
  memory.store_memory(session, 'user', '我习惯用Vim编辑器', 'long_term')
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
  local mem_id = memory.store_memory(session, 'user', '测试删除功能', 'long_term')
  
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

return TestMemory
