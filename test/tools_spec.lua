-- test/tools_spec.lua
local lu = require('luaunit')
local tools = require('chat.tools')
local config = require('chat.config')

TestTools = {}

function TestTools:setUp()
  -- Set up a temporary directory for test files
  self.test_dir = vim.fs.normalize(vim.fn.getcwd()) .. '/test_temp_files'
  if vim.fn.isdirectory(self.test_dir) == 0 then
    vim.fn.mkdir(self.test_dir, 'p')
  end
  
  -- Normalize the allowed path
  config.setup({
    allowed_path = vim.fs.normalize(vim.fn.getcwd()),
  })
end

function TestTools:tearDown()
  -- Clean up test files
  if self.test_dir and vim.fn.isdirectory(self.test_dir) == 1 then
    vim.fn.delete(self.test_dir, 'rf')
  end
end

function TestTools:testAvailableTools()
  local available = tools.available_tools()
  lu.assertNotNil(available)
  lu.assertTrue(type(available) == 'tables')
  
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
  -- Create a test file in allowed path
  local test_file = self.test_dir .. '/test_read.lua'
  vim.fn.writefile({ 'test content line 1', 'test content line 2' }, test_file)
  
  local result = tools.call('read_file', { filepath = test_file }, { cwd = vim.fs.normalize(vim.fn.getcwd()) })
  
  -- Debug: print result if error
  if result.error then
    print('Error in testCallReadFile: ' .. result.error)
  end
  
  lu.assertNotNil(result)
  lu.assertNotNil(result.content, 'Expected content, got error: ' .. (result.error or 'unknown'))
  lu.assertStrContains(result.content, 'test content line 1')
end

function TestTools:testCallReadFileWithLines()
  -- Create a test file with multiple lines in allowed path
  local test_file = self.test_dir .. '/test_read_lines.lua'
  local lines = {}
  for i = 1, 10 do
    table.insert(lines, 'Line ' .. i)
  end
  vim.fn.writefile(lines, test_file)
  
  local result = tools.call('read_file', {
    filepath = test_file,
    line_start = 3,
    line_to = 5,
  }, { cwd = vim.fs.normalize(vim.fn.getcwd()) })
  
  -- Debug: print result if error
  if result.error then
    print('Error in testCallReadFileWithLines: ' .. result.error)
  end
  
  lu.assertNotNil(result)
  lu.assertNotNil(result.content, 'Expected content, got error: ' .. (result.error or 'unknown'))
  lu.assertStrContains(result.content, 'Line 3')
  lu.assertStrContains(result.content, 'Line 5')
end

function TestTools:testCallFindFiles()
  -- Create a test file in allowed path
  local test_file = self.test_dir .. '/test_find.lua'
  vim.fn.writefile({ '-- test file for find_files' }, test_file)
  
  -- Use normalized path for cwd
  local cwd = vim.fs.normalize(vim.fn.getcwd())
  
  local result = tools.call('find_files', {
    pattern = '**/test_find.lua',
  }, { cwd = cwd })
  
  -- Debug: print result if error
  if result.error then
    print('Error in testCallFindFiles: ' .. result.error)
    print('  cwd: ' .. cwd)
    print('  allowed_path: ' .. vim.inspect(config.config.allowed_path))
  end
  
  lu.assertNotNil(result)
  lu.assertNotNil(result.content, 'Expected content, got error: ' .. (result.error or 'unknown'))
  lu.assertStrContains(result.content, 'test_find.lua')
end

function TestTools:testCallExtractMemory()
  local result = tools.call('extract_memory', {
    text = '测试提取记忆功能',
    memory_type = 'long_term',
  }, { cwd = vim.fs.normalize(vim.fn.getcwd()), session = 'test-session' })
  
  lu.assertNotNil(result)
  lu.assertNotNil(result.content)
end

function TestTools:testInvalidToolCall()
  local result = tools.call('nonexistent_tool', {}, { cwd = vim.fs.normalize(vim.fn.getcwd()) })
  lu.assertNotNil(result)
  lu.assertNotNil(result.error)
end

function TestTools:testToolCallWithInvalidArguments()
  local result = tools.call('read_file', {}, { cwd = vim.fs.normalize(vim.fn.getcwd()) })
  lu.assertNotNil(result)
  lu.assertNotNil(result.error)
end

return TestTools
