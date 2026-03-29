local lu = require('luaunit')
local tools = require('chat.tools')
local config = require('chat.config')

TestToolsMemory = {}

function TestToolsMemory:setUp()
  config.setup({
    allowed_path = vim.fs.normalize(vim.fn.getcwd()),
  })
end

function TestToolsMemory:testCallExtractMemory()
  local result = tools.call('extract_memory', {
    text = 'Test memory extraction functionality',
    memory_type = 'long_term',
  }, { cwd = vim.fs.normalize(vim.fn.getcwd()), session = 'test-session' })

  lu.assertNotNil(result)
  lu.assertNotNil(result.content)
end

