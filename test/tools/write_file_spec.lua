local lu = require('luaunit')
local tools = require('chat.tools')
local config = require('chat.config')

TestWriteFile = {}

function TestWriteFile:setUp()
  self.test_dir = vim.fs.normalize(vim.fn.getcwd()) .. '/test_temp_files'
  if vim.fn.isdirectory(self.test_dir) == 0 then
    vim.fn.mkdir(self.test_dir, 'p')
  end

  config.setup({
    allowed_path = vim.fs.normalize(vim.fn.getcwd()),
  })
end

function TestWriteFile:tearDown()
  if self.test_dir and vim.fn.isdirectory(self.test_dir) == 1 then
    vim.fn.delete(self.test_dir, 'rf')
  end
end

function TestWriteFile:testWriteFileCreate()
  local test_file = self.test_dir .. '/test_create.lua'

  local result = tools.call('write_file', {
    filepath = test_file,
    action = 'create',
    content = 'print("hello")',
  }, { cwd = vim.fs.normalize(vim.fn.getcwd()) })

  lu.assertNotNil(result)
  lu.assertNotNil(
    result.content,
    'Expected content, got error: ' .. (result.error or 'unknown')
  )
  lu.assertStrContains(result.content, 'Successfully created')
  lu.assertEquals(vim.fn.filereadable(test_file), 1)

  local lines = vim.fn.readfile(test_file)
  lu.assertEquals(lines[1], 'print("hello")')
end

function TestWriteFile:testWriteFileCreateAlreadyExists()
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

function TestWriteFile:testWriteFileOverwrite()
  local test_file = self.test_dir .. '/test_overwrite.lua'
  vim.fn.writefile({ 'old content' }, test_file)

  local result = tools.call('write_file', {
    filepath = test_file,
    action = 'overwrite',
    content = 'new content\nline 2',
  }, { cwd = vim.fs.normalize(vim.fn.getcwd()) })

  lu.assertNotNil(result)
  lu.assertNotNil(
    result.content,
    'Expected content, got error: ' .. (result.error or 'unknown')
  )
  lu.assertStrContains(result.content, 'overwritten')

  local lines = vim.fn.readfile(test_file)
  lu.assertEquals(lines[1], 'new content')
  lu.assertEquals(lines[2], 'line 2')
end

function TestWriteFile:testWriteFileAppend()
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

function TestWriteFile:testWriteFileInsert()
  local test_file = self.test_dir .. '/test_insert.lua'
  vim.fn.writefile({ 'line 1', 'line 2', 'line 3' }, test_file)

  local result = tools.call('write_file', {
    filepath = test_file,
    action = 'insert',
    line_start = 2,
    content = 'inserted line',
  }, { cwd = vim.fs.normalize(vim.fn.getcwd()) })

  lu.assertNotNil(result)
  lu.assertNotNil(
    result.content,
    'Expected content, got error: ' .. (result.error or 'unknown')
  )
  lu.assertStrContains(result.content, 'inserted')

  local lines = vim.fn.readfile(test_file)
  lu.assertEquals(lines[1], 'line 1')
  lu.assertEquals(lines[2], 'inserted line')
  lu.assertEquals(lines[3], 'line 2')
  lu.assertEquals(lines[4], 'line 3')
end

function TestWriteFile:testWriteFileDeleteLines()
  local test_file = self.test_dir .. '/test_delete_lines.lua'
  vim.fn.writefile(
    { 'line 1', 'line 2', 'line 3', 'line 4', 'line 5' },
    test_file
  )

  local result = tools.call('write_file', {
    filepath = test_file,
    action = 'delete',
    line_start = 2,
    line_to = 3,
  }, { cwd = vim.fs.normalize(vim.fn.getcwd()) })

  lu.assertNotNil(result)
  lu.assertNotNil(
    result.content,
    'Expected content, got error: ' .. (result.error or 'unknown')
  )
  lu.assertStrContains(result.content, 'deleted lines 2-3')

  local lines = vim.fn.readfile(test_file)
  lu.assertEquals(#lines, 3)
  lu.assertEquals(lines[1], 'line 1')
  lu.assertEquals(lines[2], 'line 4')
  lu.assertEquals(lines[3], 'line 5')
end

function TestWriteFile:testWriteFileReplace()
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
  lu.assertNotNil(
    result.content,
    'Expected content, got error: ' .. (result.error or 'unknown')
  )
  lu.assertStrContains(result.content, 'replaced')

  local lines = vim.fn.readfile(test_file)
  lu.assertEquals(#lines, 5)
  lu.assertEquals(lines[1], 'line 1')
  lu.assertEquals(lines[2], 'new line a')
  lu.assertEquals(lines[3], 'new line b')
  lu.assertEquals(lines[4], 'new line c')
  lu.assertEquals(lines[5], 'line 4')
end

function TestWriteFile:testWriteFileRemove()
  local test_file = self.test_dir .. '/test_remove.lua'
  vim.fn.writefile({ 'content to be removed' }, test_file)
  lu.assertEquals(vim.fn.filereadable(test_file), 1)

  local result = tools.call('write_file', {
    filepath = test_file,
    action = 'remove',
  }, { cwd = vim.fs.normalize(vim.fn.getcwd()) })

  lu.assertNotNil(result)
  lu.assertNotNil(
    result.content,
    'Expected content, got error: ' .. (result.error or 'unknown')
  )
  lu.assertStrContains(result.content, 'removed')
  lu.assertEquals(vim.fn.filereadable(test_file), 0)
end

function TestWriteFile:testWriteFileRemoveNonExistent()
  local test_file = self.test_dir .. '/non_existent.lua'

  local result = tools.call('write_file', {
    filepath = test_file,
    action = 'remove',
  }, { cwd = vim.fs.normalize(vim.fn.getcwd()) })

  lu.assertNotNil(result)
  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'does not exist')
end

function TestWriteFile:testWriteFileSecurityOutsideCwd()
  local result = tools.call('write_file', {
    filepath = '../../../etc/passwd',
    action = 'create',
    content = 'malicious',
  }, { cwd = vim.fs.normalize(vim.fn.getcwd()) })

  lu.assertNotNil(result)
  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'Security')
end

function TestWriteFile:testWriteFileSecurityNotAllowedPath()
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

  vim.fn.delete(temp_dir, 'rf')
end
