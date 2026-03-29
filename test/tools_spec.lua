local lu = require('luaunit')
local tools = require('chat.tools')
local config = require('chat.config')

-- Helper function to test async tools
local function call_async_tool(func, arguments, ctx, timeout)
  timeout = timeout or 2000
  local result_received = false
  local actual_result = nil
  local result = tools.call(
    func,
    arguments,
    vim.tbl_extend('force', ctx, {
      callback = function(res)
        result_received = true
        actual_result = res
      end,
    })
  )
  -- If immediate error, return it
  if result.error then
    return result
  end
  -- Wait for async completion
  local wait_ok = vim.wait(timeout, function()
    return result_received
  end, 50)
  if not wait_ok then
    return { error = 'Async tool did not complete within ' .. timeout .. 'ms' }
  end
  return actual_result
end

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
  -- Create a test file in allowed path
  local test_file = self.test_dir .. '/test_read.lua'
  vim.fn.writefile(
    { 'test content line 1', 'test content line 2' },
    test_file
  )

  local result = tools.call(
    'read_file',
    { filepath = test_file },
    { cwd = vim.fs.normalize(vim.fn.getcwd()) }
  )

  -- Debug: print result if error
  if result.error then
    print('Error in testCallReadFile: ' .. result.error)
  end

  lu.assertNotNil(result)
  lu.assertNotNil(
    result.content,
    'Expected content, got error: ' .. (result.error or 'unknown')
  )
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
  lu.assertNotNil(
    result.content,
    'Expected content, got error: ' .. (result.error or 'unknown')
  )
  lu.assertStrContains(result.content, 'Line 3')
  lu.assertStrContains(result.content, 'Line 5')
end

function TestTools:testCallFindFiles()
  -- Create a test file in allowed path
  local test_file = self.test_dir .. '/test_find.lua'
  vim.fn.writefile({ '-- test file for find_files' }, test_file)

  -- Use normalized path for cwd
  local cwd = vim.fs.normalize(vim.fn.getcwd())

  local result = call_async_tool('find_files', {
    pattern = '**/test_find.lua',
  }, { cwd = cwd })

  -- Debug: print result if error
  if result.error then
    print('Error in testCallFindFiles: ' .. result.error)
    print('  cwd: ' .. cwd)
    print('  allowed_path: ' .. vim.inspect(config.config.allowed_path))
  end

  lu.assertNotNil(result)
  lu.assertNotNil(
    result.content,
    'Expected content, got error: ' .. (result.error or 'unknown')
  )
  lu.assertStrContains(result.content, 'test_find.lua')
end

function TestTools:testCallExtractMemory()
  local result = tools.call('extract_memory', {
    text = 'Test memory extraction functionality',
    memory_type = 'long_term',
  }, { cwd = vim.fs.normalize(vim.fn.getcwd()), session = 'test-session' })

  lu.assertNotNil(result)
  lu.assertNotNil(result.content)
end

function TestTools:testInvalidToolCall()
  local result = tools.call(
    'nonexistent_tool',
    {},
    { cwd = vim.fs.normalize(vim.fn.getcwd()) }
  )
  lu.assertNotNil(result)
  lu.assertNotNil(result.error)
end

function TestTools:testToolCallWithInvalidArguments()
  local result = tools.call(
    'read_file',
    {},
    { cwd = vim.fs.normalize(vim.fn.getcwd()) }
  )
  lu.assertNotNil(result)
  lu.assertNotNil(result.error)
end


-- ============================================
-- Write File Tests
-- ============================================
-- Write File Tests
-- ============================================

function TestTools:testWriteFileCreate()
  local test_file = self.test_dir .. '/test_create.lua'

  -- Create new file
  local result = tools.call('write_file', {
    filepath = test_file,
    action = 'create',
    content = 'print("hello")',
  }, { cwd = vim.fs.normalize(vim.fn.getcwd()) })

  lu.assertNotNil(result)
  lu.assertNotNil(result.content, 'Expected content, got error: ' .. (result.error or 'unknown'))
  lu.assertStrContains(result.content, 'Successfully created')
  lu.assertEquals(vim.fn.filereadable(test_file), 1)

  -- Verify content
  local lines = vim.fn.readfile(test_file)
  lu.assertEquals(lines[1], 'print("hello")')
end

function TestTools:testWriteFileCreateAlreadyExists()
  local test_file = self.test_dir .. '/test_create_exists.lua'
  vim.fn.writefile({ 'existing content' }, test_file)

  local result = tools.call('write_file', {
    filepath = test_file,
    action = 'create',
    content = 'new content',
  }, { cwd = vim.fs.normalize(vim.fn.getcwd()) })

  lu.assertNotNil(result)
  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'already exists')
end

function TestTools:testWriteFileOverwrite()
  local test_file = self.test_dir .. '/test_overwrite.lua'
  vim.fn.writefile({ 'old content' }, test_file)

  local result = tools.call('write_file', {
    filepath = test_file,
    action = 'overwrite',
    content = 'new content\nline 2',
  }, { cwd = vim.fs.normalize(vim.fn.getcwd()) })

  lu.assertNotNil(result)
  lu.assertNotNil(result.content, 'Expected content, got error: ' .. (result.error or 'unknown'))
  lu.assertStrContains(result.content, 'overwritten')

  local lines = vim.fn.readfile(test_file)
end

function TestTools:testWriteFileAppend()
  local test_file = self.test_dir .. '/test_append.lua'
  vim.fn.writefile({ 'line 1' }, test_file)

  local result = tools.call('write_file', {
    filepath = test_file,
    action = 'append',
    content = 'line 2\nline 3',
  }, { cwd = vim.fs.normalize(vim.fn.getcwd()) })
  lu.assertStrContains(result.content, 'appended')

  local lines = vim.fn.readfile(test_file)
  lu.assertEquals(lines[1], 'line 1')
  lu.assertEquals(lines[2], 'line 2')
  lu.assertEquals(lines[3], 'line 3')
end

function TestTools:testWriteFileInsert()
  local test_file = self.test_dir .. '/test_insert.lua'
  vim.fn.writefile({ 'line 1', 'line 2', 'line 3' }, test_file)

  local result = tools.call('write_file', {
    filepath = test_file,
    action = 'insert',
    line_start = 2,
    content = 'inserted line',
  }, { cwd = vim.fs.normalize(vim.fn.getcwd()) })

  lu.assertNotNil(result)
  lu.assertNotNil(result.content, 'Expected content, got error: ' .. (result.error or 'unknown'))
  lu.assertStrContains(result.content, 'inserted')

  local lines = vim.fn.readfile(test_file)
  lu.assertEquals(lines[1], 'line 1')
  lu.assertEquals(lines[2], 'inserted line')
  lu.assertEquals(lines[3], 'line 2')
  lu.assertEquals(lines[4], 'line 3')
end

function TestTools:testWriteFileDeleteLines()
  local test_file = self.test_dir .. '/test_delete_lines.lua'
  vim.fn.writefile({ 'line 1', 'line 2', 'line 3', 'line 4', 'line 5' }, test_file)

  local result = tools.call('write_file', {
    filepath = test_file,
    action = 'delete',
    line_start = 2,
    line_to = 3,
  }, { cwd = vim.fs.normalize(vim.fn.getcwd()) })

  lu.assertNotNil(result)
  lu.assertNotNil(result.content, 'Expected content, got error: ' .. (result.error or 'unknown'))
  lu.assertStrContains(result.content, 'deleted lines 2-3')

  local lines = vim.fn.readfile(test_file)
  lu.assertEquals(#lines, 3)
  lu.assertEquals(lines[1], 'line 1')
  lu.assertEquals(lines[2], 'line 4')
  lu.assertEquals(lines[3], 'line 5')
end

function TestTools:testWriteFileReplace()
  local test_file = self.test_dir .. '/test_replace.lua'
  vim.fn.writefile({ 'line 1', 'line 2', 'line 3', 'line 4' }, test_file)

  local result = tools.call('write_file', {
    filepath = test_file,
    action = 'replace',
    line_start = 2,
    line_to = 3,
    content = 'new line a\nnew line b\nnew line c',
  }, { cwd = vim.fs.normalize(vim.fn.getcwd()) })

  lu.assertNotNil(result)
  lu.assertNotNil(result.content, 'Expected content, got error: ' .. (result.error or 'unknown'))
  lu.assertStrContains(result.content, 'replaced')

  local lines = vim.fn.readfile(test_file)
  lu.assertEquals(#lines, 5)
  lu.assertEquals(lines[1], 'line 1')
  lu.assertEquals(lines[2], 'new line a')
  lu.assertEquals(lines[3], 'new line b')
  lu.assertEquals(lines[4], 'new line c')
  lu.assertEquals(lines[5], 'line 4')
end

function TestTools:testWriteFileRemove()
  local test_file = self.test_dir .. '/test_remove.lua'
  vim.fn.writefile({ 'content to be removed' }, test_file)
  lu.assertEquals(vim.fn.filereadable(test_file), 1)

  local result = tools.call('write_file', {
    filepath = test_file,
    action = 'remove',
  }, { cwd = vim.fs.normalize(vim.fn.getcwd()) })

  lu.assertNotNil(result)
  lu.assertNotNil(result.content, 'Expected content, got error: ' .. (result.error or 'unknown'))
  lu.assertStrContains(result.content, 'removed')
  lu.assertEquals(vim.fn.filereadable(test_file), 0)
end

function TestTools:testWriteFileRemoveNonExistent()
  local test_file = self.test_dir .. '/non_existent.lua'

  local result = tools.call('write_file', {
    filepath = test_file,
    action = 'remove',
  }, { cwd = vim.fs.normalize(vim.fn.getcwd()) })

  lu.assertNotNil(result)
  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'does not exist')
end

function TestTools:testWriteFileSecurityOutsideCwd()
  local result = tools.call('write_file', {
    filepath = '../../../etc/passwd',
    action = 'create',
    content = 'malicious',
  }, { cwd = vim.fs.normalize(vim.fn.getcwd()) })

  lu.assertNotNil(result)
  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'Security')
end

function TestTools:testWriteFileSecurityNotAllowedPath()
  -- Create a temp file outside allowed path
  local temp_dir = vim.fn.tempname()
  vim.fn.mkdir(temp_dir, 'p')
  local temp_file = temp_dir .. '/test.lua'

  local result = tools.call('write_file', {
    filepath = temp_file,
    action = 'create',
    content = 'test',
  }, { cwd = temp_dir })

  lu.assertNotNil(result)
  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'allowed_path')

  -- Cleanup
  vim.fn.delete(temp_dir, 'rf')
end



return TestTools
