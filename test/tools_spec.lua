-- test/tools_spec.lua
local lu = require('luaunit')
local tools = require('chat.tools')
local config = require('chat.config')

TestTools = {}

function TestTools:setUp()
  config.setup({
    allowed_path = vim.fn.getcwd(),
  })
end

function TestTools:testAvailableTools()
  local available = tools.available_tools()
  lu.assertNotNil(available)
  lu.assertTrue(type(available) == 'table')
  
  -- Check for expected tools
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

function TestTools:testCallReadFile()
  -- Create a test file
  local test_file = vim.fn.tempname()
  vim.fn.writefile({ 'test content line 1', 'test content line 2' }, test_file)
  
  local result = tools.call('read_file', { filepath = test_file })
  lu.assertNotNil(result)
  lu.assertNotNil(result.content)
  lu.assertStrContains(result.content, 'test content line 1')
  
  -- Clean up
  vim.fn.delete(test_file)
end

function TestTools:testCallReadFileWithLines()
  -- Create a test file with multiple lines
  local test_file = vim.fn.tempname()
  local lines = {}
  for i = 1, 10 do
    table.insert(lines, 'Line ' .. i)
  end
  vim.fn.writefile(lines, test_file)
  
  local result = tools.call('read_file', {
    filepath = test_file,
    line_start = 3,
    line_to = 5,
  })
  
  lu.assertNotNil(result)
  lu.assertNotNil(result.content)
  lu.assertStrContains(result.content, 'Line 3')
  lu.assertStrContains(result.content, 'Line 5')
  
  -- Clean up
  vim.fn.delete(test_file)
end

function TestTools:testCallFindFiles()
  -- Create a test file
  local test_file = vim.fn.tempname() .. '.lua'
  vim.fn.writefile({ '-- test file' }, test_file)
  
  local result = tools.call('find_files', {
    pattern = vim.fn.fnamemodify(test_file, ':t'),
  })
  
  lu.assertNotNil(result)
  lu.assertNotNil(result.content)
  
  -- Clean up
  vim.fn.delete(test_file)
end

function TestTools:testCallExtractMemory()
  local result = tools.call('extract_memory', {
    text = '测试提取记忆功能',
    memory_type = 'long_term',
  })
  
  lu.assertNotNil(result)
  lu.assertNotNil(result.content)
end

function TestTools:testInvalidToolCall()
  local result = tools.call('nonexistent_tool', {})
  lu.assertNotNil(result)
  lu.assertNotNil(result.error)
end

function TestTools:testToolCallWithInvalidArguments()
  local result = tools.call('read_file', {})
  lu.assertNotNil(result)
  lu.assertNotNil(result.error)
end

return TestTools
