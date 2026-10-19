local lu = require('luaunit')
local storage = require('chat.sessions.storage')
local config = require('chat.config')

TestStorage = {}

function TestStorage:setUp()
  self.dir = vim.fn.tempname() .. '_sessions/'
  vim.fn.mkdir(self.dir, 'p')
  storage.set_cache_dir(self.dir)
end

function TestStorage:tearDown()
  if vim.fn.isdirectory(self.dir) == 1 then
    vim.fn.delete(self.dir, 'rf')
  end
end

function TestStorage:testWriteCacheMissingSession()
  local result = storage.write_cache('nonexistent')
  lu.assertFalse(result)
end

function TestStorage:testWriteCacheSuccess()
  storage.sessions['s1'] = { id = 's1', messages = { { role = 'user', content = 'hi' } } }
  local result = storage.write_cache('s1')
  lu.assertTrue(result)
  lu.assertEquals(1, vim.fn.filereadable(self.dir .. 's1.json'))
end

function TestStorage:testGetCachePathExists()
  storage.sessions['s2'] = { id = 's2' }
  storage.write_cache('s2')
  local path = storage.get_cache_path('s2')
  lu.assertNotNil(path)
  lu.assertStrContains(path, 's2.json')
end

function TestStorage:testGetCachePathMissingSession()
  lu.assertNil(storage.get_cache_path('missing'))
end

function TestStorage:testGetCachePathFileMissing()
  storage.sessions['s3'] = { id = 's3' }
  lu.assertNil(storage.get_cache_path('s3'))
end

function TestStorage:testIterSessionsEmptyDir()
  local count = 0
  for _, _ in storage.iter_sessions() do
    count = count + 1
  end
  lu.assertEquals(0, count)
end

function TestStorage:testIterSessionsLoadsFromDisk()
  vim.fn.writefile({ vim.json.encode({ id = 's10', messages = {} }) }, self.dir .. 's10.json')
  local seen = {}
  for id, data in storage.iter_sessions() do
    seen[id] = data
  end
  lu.assertNotNil(seen['s10'])
  lu.assertEquals('s10', seen['s10'].id)
end

function TestStorage:testIterSessionsAlreadyLoaded()
  storage.sessions['s11'] = { id = 's11', messages = {} }
  vim.fn.writefile({ vim.json.encode({ id = 's11', messages = {} }) }, self.dir .. 's11.json')
  local seen = {}
  for id, _ in storage.iter_sessions() do
    seen[id] = true
  end
  lu.assertTrue(seen['s11'])
end

function TestStorage:testIterSessionsLegacyFormat()
  -- Old format: a plain array of messages with no id field
  vim.fn.writefile({ vim.json.encode({ { role = 'user', content = 'old' } }) }, self.dir .. 's_legacy.json')
  local seen = {}
  for id, data in storage.iter_sessions() do
    seen[id] = data
  end
  lu.assertNotNil(seen['s_legacy'])
  lu.assertEquals('s_legacy', seen['s_legacy'].id)
  lu.assertNotNil(seen['s_legacy'].cwd)
  lu.assertNotNil(seen['s_legacy'].prompt)
end

function TestStorage:testIterSessionsInvalidJson()
  vim.fn.writefile({ 'not valid json' }, self.dir .. 's_bad.json')
  local count = 0
  for _, _ in storage.iter_sessions() do
    count = count + 1
  end
  lu.assertEquals(0, count)
end

function TestStorage:testIterSessionsMissingDir()
  storage.set_cache_dir(self.dir .. 'does_not_exist/')
  local count = 0
  for _, _ in storage.iter_sessions() do
    count = count + 1
  end
  lu.assertEquals(0, count)
end

return TestStorage
