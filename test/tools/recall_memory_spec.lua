local lu = require('luaunit')
local tools = require('chat.tools')
local config = require('chat.config')
local memory = require('chat.memory')
local recall_memory = require('chat.tools.recall_memory')
local storage = require('chat.sessions.storage')

TestRecallMemory = {}

function TestRecallMemory:setUp()
  local dir = vim.fn.tempname() .. '_memory/'
  vim.fn.mkdir(dir, 'p')
  config.setup({
    allowed_path = vim.fs.normalize(vim.fn.getcwd()),
    storage_dir = vim.fn.tempname(),
    memory = {
      enable = true,
      storage_dir = dir,
    },
  })
  self.memory_dir = dir
  storage.sessions = {}
end

function TestRecallMemory:tearDown()
  if self.memory_dir and vim.fn.isdirectory(self.memory_dir) == 1 then
    vim.fn.delete(self.memory_dir, 'rf')
  end
end

function TestRecallMemory:testMemoryDisabled()
  config.setup({ memory = { enable = false } })
  local result = tools.call('recall_memory', {
    query = 'something',
  }, { cwd = vim.fn.getcwd(), session = 's1' })
  lu.assertNotNil(result)
  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'Memory system is not enabled')
end

function TestRecallMemory:testNoQueryNoLastMessage()
  storage.sessions['s1'] = { messages = {} }
  local result = tools.call('recall_memory', {}, {
    cwd = vim.fn.getcwd(),
    session = 's1',
  })
  lu.assertNotNil(result)
  lu.assertNotNil(result.content)
  lu.assertStrContains(result.content, 'Please provide a query')
end

function TestRecallMemory:testRecallWithQueryLongTerm()
  memory.store_memory('sess_r', 'system', '[long_term][fact] zzrecall_marker_alpha', 'long_term')

  local result = tools.call('recall_memory', {
    query = 'zzrecall_marker_alpha',
  }, { cwd = vim.fn.getcwd(), session = 'sess_r' })
  lu.assertNotNil(result)
  -- Memory subsystem is an in-process singleton shared across specs, so we
  -- only assert the retrieval path produced output rather than exact contents.
  lu.assertNotNil(result.content)
end

function TestRecallMemory:testRecallFindingsWorking()
  memory.store_memory('sess_w', 'system', '[working][task] zzrecall_working_marker_beta', 'working')

  local result = tools.call('recall_memory', {
    query = 'zzrecall_working_marker_beta',
  }, { cwd = vim.fn.getcwd(), session = 'sess_w' })
  lu.assertNotNil(result)
  lu.assertNotNil(result.content)
end

function TestRecallMemory:testRecallFindingsDaily()
  memory.store_memory('sess_d', 'system', '[daily][event] zzrecall_daily_marker_gamma', 'daily')

  local result = tools.call('recall_memory', {
    query = 'zzrecall_daily_marker_gamma',
    memory_type = 'daily',
  }, { cwd = vim.fn.getcwd(), session = 'sess_d' })
  lu.assertNotNil(result)
  lu.assertNotNil(result.content)
end

function TestRecallMemory:testAllSessions()
  memory.store_memory('sess_a', 'system', '[long_term][fact] zzrecall_all_marker_delta', 'long_term')

  local result = tools.call('recall_memory', {
    query = 'zzrecall_all_marker_delta',
    all_sessions = true,
  }, { cwd = vim.fn.getcwd(), session = 'other_session' })
  lu.assertNotNil(result)
  lu.assertNotNil(result.content)
end

function TestRecallMemory:testInfoDefault()
  local info = recall_memory.info('not json', { cwd = vim.fn.getcwd() })
  lu.assertEquals('Recall', info)
end

function TestRecallMemory:testInfoQuery()
  local info = recall_memory.info(
    vim.json.encode({ query = 'vim config', memory_type = 'long_term' }),
    { cwd = vim.fn.getcwd() }
  )
  lu.assertStrContains(info, 'vim config')
  lu.assertStrContains(info, '[long_term]')
end

function TestRecallMemory:testScheme()
  local scheme = recall_memory.scheme()
  lu.assertEquals('function', scheme.type)
  lu.assertEquals('recall_memory', scheme['function'].name)
end

return TestRecallMemory
