local lu = require('luaunit')
local tools = require('chat.tools')
local config = require('chat.config')

TestToolsGeneral = {}

function TestToolsGeneral:setUp()
  config.setup({
    allowed_path = vim.fs.normalize(vim.fn.getcwd()),
  })
end

function TestToolsGeneral:testAvailableTools()
  local available = tools.available_tools()
  lu.assertNotNil(available)
  lu.assertTrue(type(available) == 'table')

  local tool_names = {}
  for _, tool in ipairs(available) do
    table.insert(tool_names, tool['function'].name)
  end

  lu.assertTrue(vim.tbl_contains(tool_names, 'read_file'))
  lu.assertTrue(vim.tbl_contains(tool_names, 'find_files'))
  lu.assertTrue(vim.tbl_contains(tool_names, 'search_text'))
  lu.assertTrue(vim.tbl_contains(tool_names, 'extract_memory'))
  lu.assertTrue(vim.tbl_contains(tool_names, 'recall_memory'))
end

function TestToolsGeneral:testInvalidToolCall()
  local result = tools.call(
    'nonexistent_tool',
    {},
    { cwd = vim.fs.normalize(vim.fn.getcwd()) }
  )
  lu.assertNotNil(result)
  lu.assertNotNil(result.error)
end

function TestToolsGeneral:testToolCallWithInvalidArguments()
  local result = tools.call(
    'read_file',
    {},
    { cwd = vim.fs.normalize(vim.fn.getcwd()) }
  )
  lu.assertNotNil(result)
  lu.assertNotNil(result.error)
end

