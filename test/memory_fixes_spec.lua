-- Regression coverage for the memory-system fixes:
--   * metadata passthrough from chat.memory.store_memory into the modules
--   * extract_memory forwarding / returning importance + work_type
--   * source-level memory_type filtering in retrieve_memories
--   * priority weights applied exactly once (module level only)
--   * daily enable gate, max_memories cap, per-memory expiry_days
--   * long_term nil-metadata safety and a cleanup that actually removes
--   * memory.cleanup() not clearing the current session
--   * global memory.enable gate inside chat.memory

local lu = require('luaunit')

local config = require('chat.config')
local memory = require('chat.memory')
local working = require('chat.memory.working')
local daily = require('chat.memory.daily')
local long_term = require('chat.memory.long_term')
local extract_memory = require('chat.tools.extract_memory')

TestMemoryFixes = {}

---Reset config to a complete, pristine memory baseline, then apply overrides.
---
---`config.setup()` deep-merges into the existing config, so a value written
---by an earlier test (`retention_days = 0`, `daily.enable = false`, ...) would
---survive into later tests if the base table did not spell it out again.
---Every key that any test in this file overrides must therefore be present in
---this baseline, otherwise the override leaks globally.
function TestMemoryFixes:setup_config(overrides)
  config.setup(vim.tbl_deep_extend('force', {
    storage_dir = self.storage_dir,
    memory = {
      enable = true,
      storage_dir = self.storage_dir .. 'memory/',
      long_term = {
        enable = true,
        max_memories = 500,
        retrieval_limit = 3,
        similarity_threshold = 0.3,
      },
      daily = {
        enable = true,
        retention_days = 7,
        max_memories = 100,
        similarity_threshold = 0.4,
        priority_weight = 1.5,
      },
      working = {
        enable = true,
        max_memories = 20,
        priority_weight = 2.0,
      },
    },
  }, overrides or {}))
end

function TestMemoryFixes:reload()
  working.load()
  daily.load()
  long_term.load()
end

function TestMemoryFixes:setUp()
  self.storage_dir = vim.fn.tempname() .. '_memfix/'
  vim.fn.mkdir(self.storage_dir, 'p')
  vim.fn.mkdir(self.storage_dir .. 'memory/', 'p')
  self:setup_config()
  self:reload()
end

function TestMemoryFixes:tearDown()
  -- Leave every module empty: modules are process-wide singletons and other
  -- specs assume they only see their own data.
  local empty = vim.fn.tempname() .. '_memfix_empty/'
  vim.fn.mkdir(empty, 'p')
  config.setup({
    storage_dir = empty,
    memory = {
      enable = true,
      storage_dir = empty .. 'memory/',
    },
  })
  self:reload()

  if vim.fn.isdirectory(self.storage_dir) == 1 then
    vim.fn.delete(self.storage_dir, 'rf')
  end
  if vim.fn.isdirectory(empty) == 1 then
    vim.fn.delete(empty, 'rf')
  end
end

---Find a stored working memory by ID (raw record, not the retrieval view)
local function find_working(session, id)
  for _, mem in ipairs(working.get_session_memories(session)) do
    if mem.id == id then
      return mem
    end
  end
end

local function read_json_file(path)
  local file = io.open(path, 'r')
  if not file then
    return nil
  end
  local content = file:read('*a')
  file:close()
  return content
end

-- === metadata passthrough ===

function TestMemoryFixes:testStoreMemoryForwardsMetadataToWorking()
  local session = 'fix-md-working'
  local id = memory.store_memory(session, 'system', '[working][task] deploy', 'working', {
    type = 'task',
    importance = 'critical',
  })

  lu.assertNotNil(id)
  local mem = find_working(session, id)
  lu.assertNotNil(mem, 'working memory should be stored')
  lu.assertEquals('critical', mem.metadata.importance)
  lu.assertEquals('task', mem.metadata.type)
end

function TestMemoryFixes:testStoreMemoryDefaultsMetadata()
  local session = 'fix-md-default'
  local id = memory.store_memory(session, 'system', '[working][task] anything', 'working')

  local mem = find_working(session, id)
  lu.assertNotNil(mem)
  lu.assertEquals('normal', mem.metadata.importance)
  lu.assertEquals('general', mem.metadata.type)
end

function TestMemoryFixes:testStoreMemoryForwardsMetadataAcrossTypes()
  -- long_term / daily accept metadata too; it must not be dropped on the way
  local session = 'fix-md-multi'
  local lt_id = memory.store_memory(session, 'system', '[long_term][fact] ltm', 'long_term', {
    category = 'fact',
    confidence = 0.7,
  })
  local found = false
  for _, mem in ipairs(long_term.get_all()) do
    if mem.id == lt_id then
      lu.assertEquals(0.7, mem.confidence)
      found = true
    end
  end
  lu.assertTrue(found)
end

-- === global switch ===

function TestMemoryFixes:testStoreMemoryHonoursGlobalEnable()
  self:setup_config({ memory = { enable = false } })
  self:reload()

  local id = memory.store_memory('fix-off', 'system', 'should not be stored', 'long_term')
  lu.assertNil(id, 'disabled memory system must not store anything')
  lu.assertEquals(0, #long_term.get_all())

  local retrieved = memory.retrieve_memories('anything', nil, 5)
  lu.assertEquals(0, #retrieved)
end

function TestMemoryFixes:testStoreMemoryUnknownTypeReturnsNil()
  lu.assertNil(memory.store_memory('fix-unknown', 'system', 'x', 'nope'))
end

-- === source-level type filtering ===

function TestMemoryFixes:testRetrieveMemoriesFiltersAtSource()
  local session = 'fix-filter'
  -- A working memory that outranks the daily one, plus a daily memory that
  -- only matches the query superficially. With limit=1 the global top-1 is
  -- the working entry, so the old "top-N then filter" path returned nothing.
  memory.store_memory(session, 'system', '[working][task] alpha alpha task', 'working')
  memory.store_memory(session, 'system', '[daily][event] alpha reminder', 'daily')

  local results = memory.retrieve_memories('alpha', session, 1, {
    memory_type = 'daily',
  })

  lu.assertEquals(1, #results, 'daily memory must be found even when outranked')
  lu.assertStrContains(results[1].content, '[daily]')
end

function TestMemoryFixes:testRetrieveMemoriesWithoutTypeStillMerges()
  local session = 'fix-filter-all'
  memory.store_memory(session, 'system', '[working][task] merged alpha', 'working')
  memory.store_memory(session, 'system', '[daily][event] merged alpha', 'daily')
  memory.store_memory(session, 'system', '[long_term][fact] merged alpha', 'long_term')

  local results = memory.retrieve_memories('merged alpha', session, 5)
  lu.assertTrue(#results >= 2, 'unfiltered search should merge tiers')
end

-- === weights applied once ===

function TestMemoryFixes:testWorkingPriorityWeightAppliedOnce()
  local session = 'fix-weight-working'
  memory.store_memory(session, 'system', '[working][task] weight alpha', 'working')

  local direct = working.retrieve('weight alpha', 5)
  local via_init = memory.retrieve_memories('weight alpha', session, 5)

  lu.assertEquals(1, #direct)
  lu.assertEquals(1, #via_init)
  lu.assertEquals(direct[1].id, via_init[1].id)
  -- chat.memory must not add a second multiplier on top of the module one
  lu.assertAlmostEquals(direct[1].priority, via_init[1].priority, 0.01)
end

function TestMemoryFixes:testDailyPriorityWeightAppliedOnce()
  local session = 'fix-weight-daily'
  memory.store_memory(session, 'system', '[daily][event] weight beta', 'daily')

  local direct = daily.retrieve('weight beta', 5)
  local via_init = memory.retrieve_memories('weight beta', session, 5, {
    memory_type = 'daily',
  })

  lu.assertEquals(1, #direct)
  lu.assertEquals(1, #via_init)
  lu.assertAlmostEquals(direct[1].priority, via_init[1].priority, 0.01)
end

function TestMemoryFixes:testWorkingWeightScalesWithConfig()
  local session = 'fix-weight-scale'
  memory.store_memory(session, 'system', '[working][task] scale gamma', 'working')

  local low = working.retrieve('scale gamma', 5)

  self:setup_config({ memory = { working = { priority_weight = 4.0 } } })
  local high = working.retrieve('scale gamma', 5)

  lu.assertEquals(1, #low)
  lu.assertEquals(1, #high)
  lu.assertAlmostEquals(high[1].priority / low[1].priority, 2.0, 0.05,
    'priority_weight must scale the score linearly (4.0/2.0)')
end

-- === retrieval must not mutate stored records ===

function TestMemoryFixes:testRetrieveDoesNotWritePriorityToDisk()
  local session = 'fix-view-lt'
  memory.store_memory(session, 'system', '[long_term][fact] view delta', 'long_term')

  long_term.retrieve('view delta', session, 5)

  local path = vim.fs.normalize(
    config.get_memory_storage_dir() .. '/long_term_memories.json'
  )
  local content = read_json_file(path)
  lu.assertNotNil(content)
  lu.assertNil(content:find('"priority"', 1, true),
    'retrieval must not persist a priority field into long_term storage')
end

function TestMemoryFixes:testWorkingStoredPriorityStaysBaseValue()
  local session = 'fix-view-work'
  local id = memory.store_memory(session, 'system', '[working][task] view epsilon', 'working')

  working.retrieve('view epsilon', 5)

  local mem = find_working(session, id)
  lu.assertNotNil(mem)
  lu.assertEquals(1.0, mem.priority,
    'stored base priority must stay 1.0 after retrieval')
end

-- === daily gate / cap / expiry ===

function TestMemoryFixes:testDailyRetrieveHonoursEnableFlag()
  self:setup_config()
  daily.store('fix-daily-off', 'system', '[daily][event] hidden reminder')

  self:setup_config({ memory = { daily = { enable = false } } })
  self:reload()

  -- Reloaded from the same directory: the record exists but must not be
  -- returned while daily memory is disabled.
  lu.assertTrue(#daily.get_all() >= 1, 'record should still be loaded')
  lu.assertEquals(0, #daily.retrieve('hidden reminder', 5))

  -- Re-enable so the tearDown reset sees a clean config
  self:setup_config()
  self:reload()
end

function TestMemoryFixes:testDailyMaxMemoriesCap()
  self:setup_config({ memory = { daily = { max_memories = 2 } } })

  daily.store('fix-daily-cap', 'system', '[daily][event] cap one alpha')
  daily.store('fix-daily-cap', 'system', '[daily][event] cap two beta')
  daily.store('fix-daily-cap', 'system', '[daily][event] cap three gamma')

  lu.assertEquals(2, #daily.get_all(),
    'daily.max_memories must cap the store like long_term / working do')
end

function TestMemoryFixes:testDailyExpiryUsesPerMemoryDays()
  -- Snapshot expiry_days = 7, then tighten the global retention to 0.
  -- A global-only cleanup would delete it; per-memory expiry must keep it.
  self:setup_config({ memory = { daily = { retention_days = 7 } } })
  local id = daily.store('fix-daily-exp', 'system', '[daily][event] exp zeta')
  lu.assertNotNil(id)

  self:setup_config({ memory = { daily = { retention_days = 0 } } })
  local removed = daily.cleanup_expired()
  lu.assertEquals(0, removed, 'per-memory expiry_days must win over config')

  local still_there = false
  for _, mem in ipairs(daily.get_all()) do
    if mem.id == id then
      still_there = true
    end
  end
  lu.assertTrue(still_there, 'memory must survive a config change')

  self:setup_config()
end

function TestMemoryFixes:testDailyStatsExpiredIsComputed()
  -- retention_days = 0 makes a fresh record expired immediately, so the
  -- stat must be computed from timestamps rather than a never-set flag.
  self:setup_config({ memory = { daily = { retention_days = 0 } } })
  daily.store('fix-daily-stat', 'system', '[daily][event] stat eta')

  local stats = daily.get_stats()
  lu.assertTrue(stats.total >= 1)
  lu.assertTrue(stats.expired >= 1,
    'get_stats().expired must reflect real expiry, not a missing flag')

  self:setup_config()
end

-- === long_term nil-metadata safety ===

function TestMemoryFixes:testLongTermTrimHandlesImportedMemoriesWithoutMetadata()
  self:setup_config({ memory = { long_term = { max_memories = 1 } } })
  self:reload()

  local imported = vim.json.encode({
    { content = 'imported no metadata', session = 'fix-import', timestamp = os.time() },
  })
  lu.assertEquals(1, long_term.import(imported))

  -- Second store pushes past max_memories and triggers the trim sort, which
  -- used to index a.metadata.confidence directly.
  local ok, err = pcall(function()
    memory.store_memory('fix-import', 'system', '[long_term][fact] second', 'long_term')
  end)
  lu.assertTrue(ok, 'trim must not crash on memories without metadata: ' .. tostring(err))
  lu.assertEquals(1, #long_term.get_all())

  self:setup_config()
end

function TestMemoryFixes:testAdvancedSearchCategoryIgnoresMetadataLessMemories()
  local imported = vim.json.encode({
    { content = 'nomata entry', session = 'fix-adv', timestamp = os.time() },
  })
  long_term.import(imported)

  local ok, err = pcall(function()
    local results = long_term.advanced_search({ category = 'fact' })
    lu.assertEquals(0, #results, 'metadata-less memory matches no category')
  end)
  lu.assertTrue(ok, 'advanced_search must not crash without metadata: ' .. tostring(err))
end

function TestMemoryFixes:testMergeDuplicatesHandlesMemoriesWithoutMetadata()
  local payload = {
    { content = 'dup nomata', session = 'fix-merge', timestamp = os.time() },
    { content = 'dup nomata', session = 'fix-merge', timestamp = os.time() },
  }
  long_term.import(vim.json.encode(payload))

  local ok, err = pcall(function()
    local merged = long_term.merge_duplicates()
    lu.assertTrue(merged >= 1, 'identical metadata-less memories should merge')
  end)
  lu.assertTrue(ok, 'merge_duplicates must not crash without metadata: ' .. tostring(err))
  lu.assertEquals(1, #long_term.get_all())
end

-- === long_term cleanup actually removes ===

function TestMemoryFixes:testCleanupRemovesStaleNeverAccessedMemories()
  local now = os.time()
  local stale = now - 120 * 86400 -- 120 days old, never accessed
  long_term.import(vim.json.encode({
    {
      content = 'stale theta',
      session = 'fix-clean',
      timestamp = stale,
      access_count = 0,
    },
    {
      content = 'accessed iota',
      session = 'fix-clean',
      timestamp = stale,
      access_count = 3,
    },
    {
      content = 'fresh kappa',
      session = 'fix-clean',
      timestamp = now,
      access_count = 0,
    },
  }))
  lu.assertEquals(3, #long_term.get_all())

  local removed = long_term.cleanup()
  lu.assertEquals(1, removed, 'only the stale, never-accessed memory should go')

  local contents = {}
  for _, mem in ipairs(long_term.get_all()) do
    contents[mem.content] = true
  end
  lu.assertNil(contents['stale theta'])
  lu.assertNotNil(contents['accessed iota'])
  lu.assertNotNil(contents['fresh kappa'])
end

function TestMemoryFixes:testCleanupOnFreshMemoriesRemovesNothing()
  memory.store_memory('fix-clean-fresh', 'system', '[long_term][fact] lambda', 'long_term')
  lu.assertEquals(0, long_term.cleanup(), 'fresh memories are never cleaned up')
  lu.assertEquals(1, #long_term.get_all())
end

-- === memory.cleanup must not wipe the current session ===

function TestMemoryFixes:testMemoryCleanupKeepsCurrentSessionMemories()
  local windows = require('chat.windows')
  local real_current_session = windows.current_session
  local session = 'fix-clean-session'

  windows.current_session = function()
    return session
  end

  local ok, err = pcall(function()
    local id = memory.store_memory(session, 'system', '[working][task] keep me', 'working')
    lu.assertNotNil(id)

    memory.cleanup()

    local survivors = working.get_session_memories(session)
    lu.assertEquals(1, #survivors,
      'cleanup must only drop TTL-expired memories, not the whole session')
    lu.assertEquals(id, survivors[1].id)
  end)

  windows.current_session = real_current_session
  if not ok then
    error(err)
  end
end

-- === extract_memory forwards metadata ===

function TestMemoryFixes:testExtractMemoryStoresImportanceAndWorkType()
  local session = 'fix-extract'
  local result = extract_memory.extract_memory({
    memories = {
      {
        content = 'current task in progress',
        memory_type = 'working',
        work_type = 'task',
        importance = 'critical',
      },
    },
  }, { session = session })

  lu.assertNotNil(result.content)

  local payload = vim.json.decode(result.content)
  lu.assertEquals(1, payload.extracted_count)
  -- The response itself must document what was stored
  lu.assertEquals('critical', payload.memories[1].metadata.importance)
  lu.assertEquals('task', payload.memories[1].metadata.type)

  -- And the stored record must actually carry it
  local mem = find_working(session, payload.memories[1].id)
  lu.assertNotNil(mem)
  lu.assertEquals('critical', mem.metadata.importance)
  lu.assertEquals('task', mem.metadata.type)
end

function TestMemoryFixes:testExtractMemoryHonoursTopLevelImportance()
  local session = 'fix-extract-top'
  local result = extract_memory.extract_memory({
    text = '这是一个很重要的任务。',
    memory_type = 'working',
    importance = 'critical',
  }, { session = session })

  lu.assertNotNil(result.content)
  local payload = vim.json.decode(result.content)
  lu.assertTrue(payload.extracted_count >= 1)

  local mem = find_working(session, payload.memories[1].id)
  lu.assertNotNil(mem)
  lu.assertEquals('critical', mem.metadata.importance)
end

function TestMemoryFixes:testExtractMemoryDetectsHighForImportant()
  -- '重要' belongs to high, not critical: the keyword used to appear in both
  -- lists with critical checked first, making 'high' unreachable.
  local session = 'fix-extract-imp'
  local result = extract_memory.extract_memory({
    text = '这个很重要。',
    memory_type = 'working',
  }, { session = session })

  lu.assertNotNil(result.content)
  local payload = vim.json.decode(result.content)
  lu.assertTrue(payload.extracted_count >= 1)

  local mem = find_working(session, payload.memories[1].id)
  lu.assertNotNil(mem)
  lu.assertEquals('high', mem.metadata.importance,
    "'重要' must map to high, not critical")
end

function TestMemoryFixes:testExtractMemoryBatchResponseContainsMetadata()
  -- Both branches must return the same shape; the batch branch used to omit
  -- the metadata it had just computed.
  local result = extract_memory.extract_memory({
    memories = {
      { content = '当前任务：批量分支 metadata' },
    },
  }, { session = 'fix-extract-shape' })

  local payload = vim.json.decode(result.content)
  lu.assertNotNil(payload.memories[1].metadata,
    'batch branch must return metadata like the text branch')
  lu.assertEquals('task', payload.memories[1].metadata.type)
end

return TestMemoryFixes

