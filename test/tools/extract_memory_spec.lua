local lu = require('luaunit')
local config = require('chat.config')
local extract_memory = require('chat.tools.extract_memory')

TestExtractMemory = {}

function TestExtractMemory:setUp()
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
end

function TestExtractMemory:tearDown()
  if self.memory_dir and vim.fn.isdirectory(self.memory_dir) == 1 then
    vim.fn.delete(self.memory_dir, 'rf')
  end
end

local function extract(action, ctx)
  return extract_memory.extract_memory(action, {
    cwd = vim.fn.getcwd(),
    session = 'extract_sess',
  })
end

function TestExtractMemory:testMemoryDisabled()
  config.setup({ memory = { enable = false } })
  local result = extract_memory.extract_memory({ text = 'x' }, { session = 's' })
  lu.assertNotNil(result)
  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'Memory system is not enabled')
end

function TestExtractMemory:testNoTextNoMemories()
  local result = extract({})
  lu.assertNotNil(result)
  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'Either "text" or "memories"')
end

function TestExtractMemory:testMemoriesStringInvalidJson()
  local result = extract({ memories = 'not-json' })
  lu.assertNotNil(result)
  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'Failed to parse memories JSON')
end

function TestExtractMemory:testMemoriesStringValidJson()
  local result = extract({ memories = '[{"content":"a fact here"}]' })
  lu.assertNotNil(result)
  lu.assertNotNil(result.content)
  lu.assertStrContains(result.content, 'extracted_count')
end

function TestExtractMemory:testMemoriesNotList()
  local result = extract({ memories = { a = 1 } })
  lu.assertNotNil(result)
  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'must be an array')
end

function TestExtractMemory:testMemoriesItemMissingContent()
  local result = extract({ memories = { { category = 'fact' } } })
  lu.assertNotNil(result)
  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'must contain "content"')
end

function TestExtractMemory:testMemoriesWorkingWithMetadata()
  local result = extract({
    memories = {
      {
        content = 'current task in progress',
        memory_type = 'working',
        work_type = 'task',
        importance = 'critical',
      },
    },
  })
  lu.assertNotNil(result)
  lu.assertNotNil(result.content)
  lu.assertStrContains(result.content, 'working')
end

function TestExtractMemory:testTextNotString()
  local result = extract({ text = 123 })
  lu.assertNotNil(result)
  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'text parameter must be a string')
end

function TestExtractMemory:testTextLongTerm()
  local result = extract({ text = 'Python的GIL是全局解释器锁。' })
  lu.assertNotNil(result)
  lu.assertNotNil(result.content)
  lu.assertStrContains(result.content, 'GIL')
end

function TestExtractMemory:testTextDaily()
  local result = extract({ text = '今天要完成用户登录功能。' })
  lu.assertNotNil(result)
  lu.assertNotNil(result.content)
  lu.assertStrContains(result.content, 'daily')
end

function TestExtractMemory:testTextWorking()
  local result = extract({ text = '当前正在修复登录bug。' })
  lu.assertNotNil(result)
  lu.assertNotNil(result.content)
  lu.assertStrContains(result.content, 'working')
end

function TestExtractMemory:testTextPreference()
  local result = extract({ text = '我喜欢用Vim写代码。' })
  lu.assertNotNil(result)
  lu.assertNotNil(result.content)
  lu.assertStrContains(result.content, 'preference')
end

function TestExtractMemory:testTextNoMemorableContent()
  local result = extract({ text = 'hello world' })
  lu.assertNotNil(result)
  lu.assertNotNil(result.content)
  lu.assertStrContains(result.content, 'No memorable information')
end

function TestExtractMemory:testInfoDefault()
  local info = extract_memory.info('not json', { cwd = vim.fn.getcwd() })
  lu.assertEquals('extract_memory', info)
end

function TestExtractMemory:testInfoText()
  local info = extract_memory.info(
    vim.json.encode({ text = 'hello world', memory_type = 'long_term' }),
    { cwd = vim.fn.getcwd() }
  )
  lu.assertStrContains(info, 'Extract from')
  lu.assertStrContains(info, 'long_term')
end

function TestExtractMemory:testInfoMemories()
  local info = extract_memory.info(
    vim.json.encode({ memories = { { content = 'a' }, { content = 'b' } } }),
    { cwd = vim.fn.getcwd() }
  )
  lu.assertStrContains(info, 'Store 2 memories')
end

function TestExtractMemory:testScheme()
  local scheme = extract_memory.scheme()
  lu.assertEquals('function', scheme.type)
  lu.assertEquals('extract_memory', scheme['function'].name)
end

return TestExtractMemory
