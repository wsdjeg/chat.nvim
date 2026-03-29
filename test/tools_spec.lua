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


-- ============================================
-- Git Add Tests
-- ============================================

function TestTools:testGitAddAvailable()
  -- Test that git_add tool is available
  local available = tools.available_tools()
  local tool_names = {}
  for _, tool in ipairs(available) do
    tool_names[tool['function'].name] = true
  end
  lu.assertTrue(tool_names['git_add'], 'git_add tool should be available')
end

function TestTools:testGitAddSecurityOutsideAllowedPath()
  -- Test that git_add rejects paths outside allowed_path
  local temp_dir = vim.fn.tempname()
  vim.fn.mkdir(temp_dir, 'p')

  local result = tools.call('git_add', {
    path = temp_dir .. '/test.lua',
  }, { cwd = temp_dir })

  lu.assertNotNil(result)
  lu.assertNotNil(result.error, 'Should reject path outside allowed_path')
  lu.assertStrContains(result.error, 'allowed')

  -- Cleanup
  vim.fn.delete(temp_dir, 'rf')
end

function TestTools:testGitAddNoGitRepo()
  -- Test git_add in a non-git directory
  local test_subdir = self.test_dir .. '/no_git_repo'
  vim.fn.mkdir(test_subdir, 'p')

  local test_file = test_subdir .. '/test.lua'
  vim.fn.writefile({ '-- test file' }, test_file)

  local result = call_async_tool('git_add', {
    path = test_file,
  }, { cwd = test_subdir }, 3000)

  lu.assertNotNil(result)
  lu.assertNotNil(result.error, 'Should fail in non-git directory')
  lu.assertStrContains(result.error:lower(), 'git')

  -- Cleanup
  vim.fn.delete(test_subdir, 'rf')
end

function TestTools:testGitAddInGitRepo()
  -- Skip test if git is not available
  if vim.fn.executable('git') ~= 1 then
    print('Skipping testGitAddInGitRepo: git not available')
    return
  end

  -- Create a temporary git repository
  local git_repo = self.test_dir .. '/git_test_repo'
  vim.fn.mkdir(git_repo, 'p')

  -- Initialize git repo
  local init_result = vim.fn.system('cd "' .. git_repo .. '" && git init')
  if vim.v.shell_error ~= 0 then
    print('Skipping testGitAddInGitRepo: failed to init git repo')
    return
  end

  -- Configure git user
  vim.fn.system('cd "' .. git_repo .. '" && git config user.email "test@test.com"')
  vim.fn.system('cd "' .. git_repo .. '" && git config user.name "Test User"')

  -- Create a test file
  local test_file = git_repo .. '/test.lua'
  vim.fn.writefile({ 'print("hello")' }, test_file)

  -- Test adding a file
  local result = call_async_tool('git_add', {
    path = test_file,
  }, { cwd = git_repo }, 3000)

  lu.assertNotNil(result)
  lu.assertNotNil(result.content, 'Expected content, got error: ' .. (result.error or 'unknown'))
  lu.assertStrContains(result.content:lower(), 'success')

  -- Cleanup
  vim.fn.delete(git_repo, 'rf')
end

function TestTools:testGitAddMultipleFiles()
  -- Skip test if git is not available
  if vim.fn.executable('git') ~= 1 then
    print('Skipping testGitAddMultipleFiles: git not available')
    return
  end

  -- Create a temporary git repository
  local git_repo = self.test_dir .. '/git_test_repo_multi'
  vim.fn.mkdir(git_repo, 'p')

  -- Initialize git repo
  local init_result = vim.fn.system('cd "' .. git_repo .. '" && git init')
  if vim.v.shell_error ~= 0 then
    print('Skipping testGitAddMultipleFiles: failed to init git repo')
    return
  end

  -- Configure git user
  vim.fn.system('cd "' .. git_repo .. '" && git config user.email "test@test.com"')
  vim.fn.system('cd "' .. git_repo .. '" && git config user.name "Test User"')

  -- Create test files
  local test_file1 = git_repo .. '/file1.lua'
  local test_file2 = git_repo .. '/file2.lua'
  vim.fn.writefile({ '-- file 1' }, test_file1)
  vim.fn.writefile({ '-- file 2' }, test_file2)

  -- Test adding multiple files
  local result = call_async_tool('git_add', {
    path = { test_file1, test_file2 },
  }, { cwd = git_repo }, 3000)

  lu.assertNotNil(result)
  lu.assertNotNil(result.content, 'Expected content, got error: ' .. (result.error or 'unknown'))
  lu.assertStrContains(result.content:lower(), 'success')

  -- Cleanup
  vim.fn.delete(git_repo, 'rf')
end

function TestTools:testGitAddAll()
  -- Skip test if git is not available
  if vim.fn.executable('git') ~= 1 then
    print('Skipping testGitAddAll: git not available')
    return
  end

  -- Create a temporary git repository
  local git_repo = self.test_dir .. '/git_test_repo_all'
  vim.fn.mkdir(git_repo, 'p')

  -- Initialize git repo
  local init_result = vim.fn.system('cd "' .. git_repo .. '" && git init')
  if vim.v.shell_error ~= 0 then
    print('Skipping testGitAddAll: failed to init git repo')
    return
  end

  -- Configure git user
  vim.fn.system('cd "' .. git_repo .. '" && git config user.email "test@test.com"')
  vim.fn.system('cd "' .. git_repo .. '" && git config user.name "Test User"')

  -- Create test files
  vim.fn.writefile({ '-- test 1' }, git_repo .. '/test1.lua')
  vim.fn.writefile({ '-- test 2' }, git_repo .. '/test2.lua')

  -- Test adding all files
  local result = call_async_tool('git_add', {
    all = true,
  }, { cwd = git_repo }, 3000)

  lu.assertNotNil(result)
  lu.assertNotNil(result.content, 'Expected content, got error: ' .. (result.error or 'unknown'))
  lu.assertStrContains(result.content:lower(), 'success')

  -- Cleanup
  vim.fn.delete(git_repo, 'rf')
end

-- ============================================
-- Git Commit Tests
-- ============================================

function TestTools:testGitCommitAvailable()
  -- Test that git_commit tool is available
  local available = tools.available_tools()
  local tool_names = {}
  for _, tool in ipairs(available) do
    tool_names[tool['function'].name] = true
  end
  lu.assertTrue(tool_names['git_commit'], 'git_commit tool should be available')
end

function TestTools:testGitCommitNoMessage()
  -- Test that git_commit requires a message
  local result = tools.call('git_commit', {}, { cwd = vim.fs.normalize(vim.fn.getcwd()) })

  lu.assertNotNil(result)
  lu.assertNotNil(result.error, 'Should require commit message')
  lu.assertStrContains(result.error:lower(), 'message')
end

function TestTools:testGitCommitEmptyMessage()
  -- Test that git_commit rejects empty message
  local result = tools.call('git_commit', {
    message = '',
  }, { cwd = vim.fs.normalize(vim.fn.getcwd()) })

  lu.assertNotNil(result)
  lu.assertNotNil(result.error, 'Should reject empty commit message')
  lu.assertStrContains(result.error:lower(), 'message')
end

function TestTools:testGitCommitSecurityOutsideAllowedPath()
  -- Test that git_commit rejects paths outside allowed_path
  local temp_dir = vim.fn.tempname()
  vim.fn.mkdir(temp_dir, 'p')

  local result = tools.call('git_commit', {
    message = 'test commit',
  }, { cwd = temp_dir })

  lu.assertNotNil(result)
  lu.assertNotNil(result.error, 'Should reject path outside allowed_path')
  lu.assertStrContains(result.error, 'allowed')

  -- Cleanup
  vim.fn.delete(temp_dir, 'rf')
end

function TestTools:testGitCommitNothingToCommit()
  -- Skip test if git is not available
  if vim.fn.executable('git') ~= 1 then
    print('Skipping testGitCommitNothingToCommit: git not available')
    return
  end

  -- Create a temporary git repository
  local git_repo = self.test_dir .. '/git_commit_repo'
  vim.fn.mkdir(git_repo, 'p')

  -- Initialize git repo
  local init_result = vim.fn.system('cd "' .. git_repo .. '" && git init')
  if vim.v.shell_error ~= 0 then
    print('Skipping testGitCommitNothingToCommit: failed to init git repo')
    return
  end

  -- Configure git user
  vim.fn.system('cd "' .. git_repo .. '" && git config user.email "test@test.com"')
  vim.fn.system('cd "' .. git_repo .. '" && git config user.name "Test User"')

  -- Try to commit without staging anything
  local result = call_async_tool('git_commit', {
    message = 'test commit',
  }, { cwd = git_repo }, 3000)

  lu.assertNotNil(result)
  lu.assertNotNil(result.error, 'Should fail when nothing to commit')
  lu.assertStrContains(result.error:lower(), 'nothing')

  -- Cleanup
  vim.fn.delete(git_repo, 'rf')
end

function TestTools:testGitCommitWithStagedChanges()
  -- Skip test if git is not available
  if vim.fn.executable('git') ~= 1 then
    print('Skipping testGitCommitWithStagedChanges: git not available')
    return
  end

  -- Create a temporary git repository
  local git_repo = self.test_dir .. '/git_commit_repo_staged'
  vim.fn.mkdir(git_repo, 'p')

  -- Initialize git repo
  local init_result = vim.fn.system('cd "' .. git_repo .. '" && git init')
  if vim.v.shell_error ~= 0 then
    print('Skipping testGitCommitWithStagedChanges: failed to init git repo')
    return
  end

  -- Configure git user
  vim.fn.system('cd "' .. git_repo .. '" && git config user.email "test@test.com"')
  vim.fn.system('cd "' .. git_repo .. '" && git config user.name "Test User"')

  -- Create and stage a file
  local test_file = git_repo .. '/test.lua'
  vim.fn.writefile({ 'print("test")' }, test_file)
  vim.fn.system('cd "' .. git_repo .. '" && git add ' .. test_file)

  -- Commit the changes
  local result = call_async_tool('git_commit', {
    message = 'Initial commit',
  }, { cwd = git_repo }, 3000)

  lu.assertNotNil(result)
  lu.assertNotNil(result.content, 'Expected content, got error: ' .. (result.error or 'unknown'))
  lu.assertStrContains(result.content:lower(), 'success')
  lu.assertStrContains(result.content, 'Initial commit')

  -- Cleanup
  vim.fn.delete(git_repo, 'rf')
end

function TestTools:testGitCommitAllowEmpty()
  -- Skip test if git is not available
  if vim.fn.executable('git') ~= 1 then
    print('Skipping testGitCommitAllowEmpty: git not available')
    return
  end

  -- Create a temporary git repository
  local git_repo = self.test_dir .. '/git_commit_repo_empty'
  vim.fn.mkdir(git_repo, 'p')

  -- Initialize git repo
  local init_result = vim.fn.system('cd "' .. git_repo .. '" && git init')
  if vim.v.shell_error ~= 0 then
    print('Skipping testGitCommitAllowEmpty: failed to init git repo')
    return
  end

  -- Configure git user
  vim.fn.system('cd "' .. git_repo .. '" && git config user.email "test@test.com"')
  vim.fn.system('cd "' .. git_repo .. '" && git config user.name "Test User"')

  -- Create an empty commit
  local result = call_async_tool('git_commit', {
    message = 'Empty commit',
    allow_empty = true,
  }, { cwd = git_repo }, 3000)

  lu.assertNotNil(result)
  lu.assertNotNil(result.content, 'Expected content, got error: ' .. (result.error or 'unknown'))
  lu.assertStrContains(result.content:lower(), 'success')

  -- Cleanup
  vim.fn.delete(git_repo, 'rf')
end

function TestTools:testGitCommitAmend()
  -- Skip test if git is not available
  if vim.fn.executable('git') ~= 1 then
    print('Skipping testGitCommitAmend: git not available')
    return
  end

  -- Create a temporary git repository
  local git_repo = self.test_dir .. '/git_commit_repo_amend'
  vim.fn.mkdir(git_repo, 'p')

  -- Initialize git repo
  local init_result = vim.fn.system('cd "' .. git_repo .. '" && git init')
  if vim.v.shell_error ~= 0 then
    print('Skipping testGitCommitAmend: failed to init git repo')
    return
  end

  -- Configure git user
  vim.fn.system('cd "' .. git_repo .. '" && git config user.email "test@test.com"')
  vim.fn.system('cd "' .. git_repo .. '" && git config user.name "Test User"')

  -- Create and commit a file
  local test_file = git_repo .. '/test.lua'
  vim.fn.writefile({ 'print("test")' }, test_file)
  vim.fn.system('cd "' .. git_repo .. '" && git add ' .. test_file)
  vim.fn.system('cd "' .. git_repo .. '" && git commit -m "Initial commit"')

  -- Amend the commit
  local result = call_async_tool('git_commit', {
    message = 'Amended commit',
    amend = true,
  }, { cwd = git_repo }, 3000)

  lu.assertNotNil(result)
  lu.assertNotNil(result.content, 'Expected content, got error: ' .. (result.error or 'unknown'))
  lu.assertStrContains(result.content:lower(), 'success')

  -- Cleanup
  vim.fn.delete(git_repo, 'rf')
end

