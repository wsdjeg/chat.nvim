-- test/memory_persist_spec.lua
-- Coverage for the persistence pipeline shared by the memory modules:
--   * lazy loading (no read at require time, first use picks up the file)
--   * reloading when the configured storage_dir changes
--   * cleanup timers that can actually be stopped
--   * merge_duplicates using similarity (not exact normalized text)
--   * merge staying inside a single session

local lu = require('luaunit')
local config = require('chat.config')
local memory = require('chat.memory')
local daily = require('chat.memory.daily')
local working = require('chat.memory.working')
local long_term = require('chat.memory.long_term')

TestMemoryPersist = {}

local function new_dir(tag)
  local dir = vim.fn.tempname() .. '_persist_' .. tag .. '/'
  vim.fn.mkdir(dir, 'p')
  return dir
end

---Point the memory subsystem at a directory and remember it for cleanup.
function TestMemoryPersist:use_dir(dir)
  table.insert(self.dirs, dir)
  config.setup({
    storage_dir = dir,
    memory = {
      enable = true,
      storage_dir = dir .. 'memory/',
      long_term = { enable = true },
      daily = { enable = true },
      working = { enable = true },
    },
  })
end

function TestMemoryPersist:setUp()
  self.dirs = {}
  self:use_dir(new_dir('a'))
end

function TestMemoryPersist:tearDown()
  -- Timers are process-wide; stop them so a later spec never sees a
  -- callback firing against a directory this test just deleted.
  daily.stop_cleanup_timer()
  working.stop_cleanup_timer()
  long_term.stop_cleanup_timer()

  for _, dir in ipairs(self.dirs) do
    if vim.fn.isdirectory(dir) == 1 then
      vim.fn.delete(dir, 'rf')
    end
  end
end

-- === lazy loading ===

function TestMemoryPersist:testFirstUseLoadsFromDisk()
  local dir = self.dirs[1]
  local memory_dir = dir .. 'memory/'
  vim.fn.mkdir(memory_dir, 'p')

  local seed = {
    {
      id = 'daily-seed-1',
      session = 'lazy',
      content = '[daily][event] seeded marker',
      timestamp = os.time(),
      expiry_days = 7,
      hit_count = 1,
    },
  }
  vim.fn.writefile(
    { vim.json.encode(seed) },
    memory_dir .. 'daily_memories.json'
  )

  -- No explicit load(): the first read must pick up what is on disk.
  local all = daily.get_all()
  lu.assertEquals(1, #all)
  lu.assertEquals('daily-seed-1', all[1].id)
end

function TestMemoryPersist:testPathChangeReloadsInsteadOfKeepingOldData()
  local dir_a = self.dirs[1]
  local id = daily.store('persist-a', 'system', '[daily][event] only in dir a')
  lu.assertNotNil(id)
  lu.assertEquals(1, #daily.get_all())

  local dir_b = new_dir('b')
  self:use_dir(dir_b)

  lu.assertEquals(0, #daily.get_all(),
    'switching storage_dir must not keep the previous directory data')

  -- Switching back must show the record that lives in A again.
  self:use_dir(dir_a)
  local all = daily.get_all()
  lu.assertEquals(1, #all)
  lu.assertEquals(id, all[1].id)
end

function TestMemoryPersist:testStoreIsDurableImmediately()
  local dir = self.dirs[1]
  daily.store('persist-durable', 'system', '[daily][event] durable marker')

  -- store() must have written the file before returning: a crash right
  -- after the call may not lose the record.
  local path = dir .. 'memory/daily_memories.json'
  local content = table.concat(vim.fn.readfile(path), '\n')
  lu.assertNotNil(content:find('durable marker', 1, true))
end

-- === timers ===

function TestMemoryPersist:testDailyCleanupTimerCanBeStopped()
  daily.stop_cleanup_timer()
  lu.assertFalse(daily.has_cleanup_timer())

  daily.load()
  lu.assertTrue(daily.has_cleanup_timer(), 'load() must start the timer')

  daily.stop_cleanup_timer()
  lu.assertFalse(daily.has_cleanup_timer(),
    'stop_cleanup_timer() must close the handle')

  -- Stopping twice is a no-op, not an error.
  daily.stop_cleanup_timer()
  lu.assertFalse(daily.has_cleanup_timer())
end

function TestMemoryPersist:testWorkingAndLongTermTimersStoppable()
  working.load()
  long_term.load()
  lu.assertTrue(working.has_cleanup_timer())
  lu.assertTrue(long_term.has_cleanup_timer())

  memory.shutdown()
  lu.assertFalse(working.has_cleanup_timer())
  lu.assertFalse(long_term.has_cleanup_timer())
  lu.assertFalse(daily.has_cleanup_timer())
end

-- === merge_duplicates uses similarity ===

function TestMemoryPersist:testMergeDuplicatesUsesSimilarity()
  local now = os.time()
  local a = 'alpha beta gamma delta epsilon zeta eta theta iota kappa'
  -- Same token set in a different order: exact normalized text differs,
  -- similarity is 1.0 -> the two records must merge.
  local b = 'kappa iota theta eta zeta epsilon delta gamma beta alpha'

  long_term.import(vim.json.encode({
    {
      content = a,
      session = 'persist-merge',
      timestamp = now - 100,
      access_count = 2,
    },
    {
      content = b,
      session = 'persist-merge',
      timestamp = now,
      access_count = 1,
    },
  }))
  lu.assertEquals(2, #long_term.get_all())

  local merged = long_term.merge_duplicates()
  lu.assertEquals(1, merged, 'near-duplicate content must merge')

  local all = long_term.get_all()
  lu.assertEquals(1, #all)
  lu.assertEquals(3, all[1].access_count, 'access_count must be summed')
end

function TestMemoryPersist:testMergeDuplicatesKeepsSessionsSeparate()
  local content = 'shared alpha beta gamma'
  long_term.import(vim.json.encode({
    { content = content, session = 'persist-sess-a', timestamp = os.time() },
    { content = content, session = 'persist-sess-b', timestamp = os.time() },
  }))
  lu.assertEquals(2, #long_term.get_all())

  lu.assertEquals(0, long_term.merge_duplicates(),
    'identical content in different sessions must not merge')
  lu.assertEquals(2, #long_term.get_all())
end

return TestMemoryPersist

