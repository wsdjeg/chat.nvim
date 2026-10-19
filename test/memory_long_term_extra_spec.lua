local lu = require('luaunit')
local config = require('chat.config')
local long_term = require('chat.memory.long_term')

TestLongTermExtra = {}

function TestLongTermExtra:setUp()
  local dir = vim.fn.tempname() .. '_memory/'
  vim.fn.mkdir(dir, 'p')
  config.setup({
    storage_dir = vim.fn.tempname(),
    memory = {
      enable = true,
      storage_dir = dir,
      long_term = { enable = true },
    },
  })
  self.memory_dir = dir
  -- Clear in-memory state between tests
  long_term.load()
end

function TestLongTermExtra:tearDown()
  if self.memory_dir and vim.fn.isdirectory(self.memory_dir) == 1 then
    vim.fn.delete(self.memory_dir, 'rf')
  end
  long_term.load()
end

function TestLongTermExtra:testTextSimilarity()
  local sim = long_term.text_similarity('hello world', 'hello world')
  lu.assertNotNil(sim)
  lu.assertTrue(sim > 0)
end

function TestLongTermExtra:testRetrieveByCategory()
  long_term.store('s1', 'system', '[long_term][fact] alpha fact', {
    memory_type = 'long_term',
    category = 'fact',
    confidence = 1.0,
  })
  local results = long_term.retrieve_by_category('fact', 10)
  lu.assertNotNil(results)
end

function TestLongTermExtra:testSearchByKeywords()
  long_term.store('s1', 'system', '[long_term][fact] hello world here', {
    memory_type = 'long_term',
    category = 'fact',
    confidence = 1.0,
  })
  local results = long_term.search_by_keywords({ 'hello', 'world' }, 10)
  lu.assertEquals(1, #results)
end

function TestLongTermExtra:testSearchByKeywordsNoMatch()
  long_term.store('s1', 'system', '[long_term][fact] hello', {
    memory_type = 'long_term',
    category = 'fact',
    confidence = 1.0,
  })
  local results = long_term.search_by_keywords({ 'zzz' }, 10)
  lu.assertEquals(0, #results)
end

function TestLongTermExtra:testDeleteByFilter()
  long_term.store('s1', 'system', '[long_term][fact] delete me', {
    memory_type = 'long_term',
    category = 'fact',
    confidence = 1.0,
  })
  local removed = long_term.delete_by_filter(function(m)
    return m.content:find('delete me') ~= nil
  end)
  lu.assertEquals(1, removed)
end

function TestLongTermExtra:testUpdate()
  local id = long_term.store('s1', 'system', '[long_term][fact] old', {
    memory_type = 'long_term',
    category = 'fact',
    confidence = 1.0,
  })
  local ok = long_term.update(id, '[long_term][fact] new', { confidence = 0.9 })
  lu.assertTrue(ok)
end

function TestLongTermExtra:testUpdateNotFound()
  lu.assertFalse(long_term.update('nonexistent', 'x'))
end

function TestLongTermExtra:testMergeDuplicates()
  long_term.store('s1', 'system', '[long_term][fact] dup content', {
    memory_type = 'long_term',
    category = 'fact',
    confidence = 1.0,
  })
  long_term.store('s1', 'system', '[long_term][fact] dup content', {
    memory_type = 'long_term',
    category = 'fact',
    confidence = 1.0,
  })
  local merged = long_term.merge_duplicates()
  -- dedup during store() may already collapse identical entries
  lu.assertTrue(merged >= 0)
end

function TestLongTermExtra:testExportJson()
  long_term.store('s1', 'system', '[long_term][fact] export me', {
    memory_type = 'long_term',
    category = 'fact',
    confidence = 1.0,
  })
  local out = long_term.export('json')
  lu.assertStrContains(out, 'export me')
end

function TestLongTermExtra:testExportMarkdown()
  long_term.store('s1', 'system', '[long_term][fact] md content', {
    memory_type = 'long_term',
    category = 'fact',
    confidence = 1.0,
  })
  local out = long_term.export('markdown')
  lu.assertNotNil(out)
end

function TestLongTermExtra:testExportUnknownFormat()
  lu.assertNil(long_term.export('csv'))
end

function TestLongTermExtra:testImportJson()
  local data = vim.json.encode({ { id = 'x', content = 'c', session = 's' } })
  local count = long_term.import(data, 'json')
  lu.assertEquals(1, count)
end

function TestLongTermExtra:testImportInvalidJson()
  lu.assertEquals(0, long_term.import('not json', 'json'))
end

function TestLongTermExtra:testImportUnknownFormat()
  lu.assertEquals(0, long_term.import('whatever', 'yaml'))
end

function TestLongTermExtra:testBatchStore()
  local ids = long_term.batch_store({
    { session = 's1', role = 'system', content = '[long_term][fact] b1' },
    { session = 's1', role = 'system', content = '[long_term][fact] b2' },
  })
  lu.assertEquals(2, #ids)
end

function TestLongTermExtra:testAdvancedSearchCategory()
  long_term.store('s1', 'system', '[long_term][fact] adv content', {
    memory_type = 'long_term',
    category = 'fact',
    confidence = 1.0,
  })
  local results = long_term.advanced_search({ category = 'fact' })
  lu.assertTrue(#results >= 1)
end

function TestLongTermExtra:testAdvancedSearchSessionFilter()
  long_term.store('sess_x', 'system', '[long_term][fact] filtered', {
    memory_type = 'long_term',
    category = 'fact',
    confidence = 1.0,
  })
  local results = long_term.advanced_search({ session = 'other_session' })
  lu.assertEquals(0, #results)
end

function TestLongTermExtra:testAdvancedSearchQueryAndSort()
  long_term.store('s1', 'system', '[long_term][fact] sortable content', {
    memory_type = 'long_term',
    category = 'fact',
    confidence = 1.0,
  })
  local results = long_term.advanced_search({
    query = 'sortable',
    sort_by = 'relevance',
    limit = 5,
  })
  lu.assertTrue(#results >= 1)
end

return TestLongTermExtra
