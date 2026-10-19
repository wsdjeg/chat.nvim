local lu = require('luaunit')
local config = require('chat.config')
local daily = require('chat.memory.daily')
local working = require('chat.memory.working')

TestDailyWorkingExtra = {}

function TestDailyWorkingExtra:setUp()
  local dir = vim.fn.tempname() .. '_memory/'
  vim.fn.mkdir(dir, 'p')
  config.setup({
    storage_dir = vim.fn.tempname(),
    memory = {
      enable = true,
      storage_dir = dir,
      daily = { enable = true },
      working = { enable = true },
    },
  })
  self.memory_dir = dir
  daily.load()
  working.load()
end

function TestDailyWorkingExtra:tearDown()
  if self.memory_dir and vim.fn.isdirectory(self.memory_dir) == 1 then
    vim.fn.delete(self.memory_dir, 'rf')
  end
end

function TestDailyWorkingExtra:testDailyGetStats()
  daily.store('s1', 'system', '[daily][event] daily stat')
  local stats = daily.get_stats()
  lu.assertTrue(stats.total >= 1)
end

function TestDailyWorkingExtra:testDailyCleanupExpired()
  daily.cleanup_expired()
  lu.assertTrue(true)
end

function TestDailyWorkingExtra:testDailyDelete()
  local id = daily.store('s1', 'system', '[daily][event] to delete')
  lu.assertTrue(daily.delete(id))
  lu.assertFalse(daily.delete('nonexistent'))
end

function TestDailyWorkingExtra:testWorkingExtendTtl()
  local id = working.store('s1', 'system', '[working][task] ttl task')
  lu.assertTrue(working.extend_ttl(id, 3600))
  lu.assertFalse(working.extend_ttl('nonexistent'))
end

function TestDailyWorkingExtra:testWorkingMarkCompleted()
  local id = working.store('s1', 'system', '[working][task] complete me')
  lu.assertTrue(working.mark_completed(id, 'done'))
  lu.assertFalse(working.mark_completed('nonexistent'))
end

function TestDailyWorkingExtra:testWorkingUpdateImportance()
  local id = working.store('s1', 'system', '[working][task] important')
  lu.assertTrue(working.update_importance(id, 'critical'))
  lu.assertFalse(working.update_importance('nonexistent', 'high'))
end

function TestDailyWorkingExtra:testWorkingGetSessionMemories()
  working.store('sess_a', 'system', '[working][task] for sess_a')
  local mems = working.get_session_memories('sess_a')
  lu.assertTrue(#mems >= 1)
end

function TestDailyWorkingExtra:testWorkingGetStats()
  working.store('s1', 'system', '[working][task] stats')
  local stats = working.get_stats('s1')
  lu.assertTrue(stats.total >= 1)
end

function TestDailyWorkingExtra:testWorkingDeleteAndClear()
  local id = working.store('s1', 'system', '[working][task] delete me')
  lu.assertTrue(working.delete(id))
  lu.assertFalse(working.delete('nonexistent'))
  working.clear()
  lu.assertTrue(true)
end

function TestDailyWorkingExtra:testWorkingPromoteToLongTermNotFound()
  local id, err = working.promote_to_long_term('nonexistent')
  lu.assertNil(id)
  lu.assertNotNil(err)
end

function TestDailyWorkingExtra:testWorkingPromoteToLongTerm()
  local id = working.store('s1', 'system', '[working][task] promote me')
  local lt_id, err = working.promote_to_long_term(id)
  lu.assertNotNil(lt_id)
  lu.assertNil(err)
end

function TestDailyWorkingExtra:testWorkingCleanupExpired()
  local removed = working.cleanup_expired()
  lu.assertTrue(removed >= 0)
end

function TestDailyWorkingExtra:testWorkingCleanupSession()
  working.store('sess_x', 'system', '[working][task] cleanup session')
  local removed = working.cleanup_session('sess_x')
  lu.assertTrue(removed >= 0)
end

return TestDailyWorkingExtra
