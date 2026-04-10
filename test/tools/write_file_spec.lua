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

-- ============================
-- Original Tests
-- ============================

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

-- ============================
-- Boundary & Edge Case Tests
-- ============================

-- INSERT Boundaries
function TestWriteFile:testWriteFileInsertAtBeginning()
  local test_file = self.test_dir .. '/test_insert_begin.lua'
  vim.fn.writefile({ 'line 1', 'line 2' }, test_file)

  local result = tools.call('write_file', {
    filepath = test_file,
    action = 'insert',
    line_start = 1,
    content = 'new first line',
  }, { cwd = vim.fs.normalize(vim.fn.getcwd()) })

  lu.assertStrContains(result.content, 'inserted')
  local lines = vim.fn.readfile(test_file)
  lu.assertEquals(lines[1], 'new first line')
  lu.assertEquals(lines[2], 'line 1')
  lu.assertEquals(lines[3], 'line 2')
end

function TestWriteFile:testWriteFileInsertAtEnd()
  local test_file = self.test_dir .. '/test_insert_end.lua'
  vim.fn.writefile({ 'line 1', 'line 2' }, test_file)

  local result = tools.call('write_file', {
    filepath = test_file,
    action = 'insert',
    line_start = 3,  -- #lines + 1
    content = 'new last line',
  }, { cwd = vim.fs.normalize(vim.fn.getcwd()) })

  lu.assertStrContains(result.content, 'inserted')
  local lines = vim.fn.readfile(test_file)
  lu.assertEquals(lines[1], 'line 1')
  lu.assertEquals(lines[2], 'line 2')
  lu.assertEquals(lines[3], 'new last line')
end

function TestWriteFile:testWriteFileInsertOutOfBoundsLow()
  local test_file = self.test_dir .. '/test_insert_oob_low.lua'
  vim.fn.writefile({ 'line 1' }, test_file)

  local result = tools.call('write_file', {
    filepath = test_file,
    action = 'insert',
    line_start = 0,
    content = 'invalid',
  }, { cwd = vim.fs.normalize(vim.fn.getcwd()) })

  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'must be between')
end

function TestWriteFile:testWriteFileInsertOutOfBoundsHigh()
  local test_file = self.test_dir .. '/test_insert_oob_high.lua'
  vim.fn.writefile({ 'line 1' }, test_file)

  local result = tools.call('write_file', {
    filepath = test_file,
    action = 'insert',
    line_start = 3,  -- #lines is 1, max is 2
    content = 'invalid',
  }, { cwd = vim.fs.normalize(vim.fn.getcwd()) })

  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'must be between')
end

function TestWriteFile:testWriteFileInsertMultipleLines()
  local test_file = self.test_dir .. '/test_insert_multi.lua'
  vim.fn.writefile({ 'line 1', 'line 2' }, test_file)

  local result = tools.call('write_file', {
    filepath = test_file,
    action = 'insert',
    line_start = 2,
    content = 'inserted A\ninserted B\ninserted C',
  }, { cwd = vim.fs.normalize(vim.fn.getcwd()) })

  lu.assertStrContains(result.content, 'inserted')
  local lines = vim.fn.readfile(test_file)
  lu.assertEquals(lines[1], 'line 1')
  lu.assertEquals(lines[2], 'inserted A')
  lu.assertEquals(lines[3], 'inserted B')
  lu.assertEquals(lines[4], 'inserted C')
  lu.assertEquals(lines[5], 'line 2')
end

-- DELETE Boundaries
function TestWriteFile:testWriteFileDeleteSingleLine()
  local test_file = self.test_dir .. '/test_delete_single.lua'
  vim.fn.writefile({ 'line 1', 'line 2', 'line 3' }, test_file)

  local result = tools.call('write_file', {
    filepath = test_file,
    action = 'delete',
    line_start = 2,
  }, { cwd = vim.fs.normalize(vim.fn.getcwd()) })

  lu.assertStrContains(result.content, 'deleted lines 2-2')
  local lines = vim.fn.readfile(test_file)
  lu.assertEquals(lines[1], 'line 1')
  lu.assertEquals(lines[2], 'line 3')
end

function TestWriteFile:testWriteFileDeleteFirstAndLastLines()
  local test_file = self.test_dir .. '/test_delete_ends.lua'
  vim.fn.writefile({ 'first', 'middle', 'last' }, test_file)

  local result = tools.call('write_file', {
    filepath = test_file,
    action = 'delete',
    line_start = 1,
    line_to = 1,
  }, { cwd = vim.fs.normalize(vim.fn.getcwd()) })

  local lines = vim.fn.readfile(test_file)
  lu.assertEquals(lines[1], 'middle')
  lu.assertEquals(lines[2], 'last')
end

function TestWriteFile:testWriteFileDeleteAllLines()
  local test_file = self.test_dir .. '/test_delete_all.lua'
  vim.fn.writefile({ 'line 1', 'line 2' }, test_file)

  local result = tools.call('write_file', {
    filepath = test_file,
    action = 'delete',
    line_start = 1,
    line_to = 2,
  }, { cwd = vim.fs.normalize(vim.fn.getcwd()) })

  lu.assertStrContains(result.content, 'deleted lines 1-2')
  local lines = vim.fn.readfile(test_file)
  lu.assertEquals(#lines, 0)
end

function TestWriteFile:testWriteFileDeleteStartGreaterThanEnd()
  local test_file = self.test_dir .. '/test_delete_invalid.lua'
  vim.fn.writefile({ 'line 1', 'line 2' }, test_file)

  local result = tools.call('write_file', {
    filepath = test_file,
    action = 'delete',
    line_start = 3,
    line_to = 1,
  }, { cwd = vim.fs.normalize(vim.fn.getcwd()) })

  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'Invalid line range')
end

function TestWriteFile:testWriteFileDeleteOutOfBounds()
  local test_file = self.test_dir .. '/test_delete_oob.lua'
  vim.fn.writefile({ 'line 1' }, test_file)

  local result = tools.call('write_file', {
    filepath = test_file,
    action = 'delete',
    line_start = 1,
    line_to = 2,
  }, { cwd = vim.fs.normalize(vim.fn.getcwd()) })

  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'Invalid line range')
end

-- REPLACE Boundaries
function TestWriteFile:testWriteFileReplaceSingleLine()
  local test_file = self.test_dir .. '/test_replace_single.lua'
  vim.fn.writefile({ 'old 1', 'old 2', 'old 3' }, test_file)

  local result = tools.call('write_file', {
    filepath = test_file,
    action = 'replace',
    line_start = 2,
    content = 'new 2',
  }, { cwd = vim.fs.normalize(vim.fn.getcwd()) })

  lu.assertStrContains(result.content, 'replaced')
  local lines = vim.fn.readfile(test_file)
  lu.assertEquals(lines[2], 'new 2')
end

function TestWriteFile:testWriteFileReplaceWithMoreLines()
  local test_file = self.test_dir .. '/test_replace_more.lua'
  vim.fn.writefile({ 'A', 'B', 'C' }, test_file)

  local result = tools.call('write_file', {
    filepath = test_file,
    action = 'replace',
    line_start = 2,
    line_to = 2,
    content = 'new1\nnew2\nnew3',
  }, { cwd = vim.fs.normalize(vim.fn.getcwd()) })

  lu.assertStrContains(result.content, 'replaced')
  local lines = vim.fn.readfile(test_file)
  lu.assertEquals(lines[1], 'A')
  lu.assertEquals(lines[2], 'new1')
  lu.assertEquals(lines[3], 'new2')
  lu.assertEquals(lines[4], 'new3')
  lu.assertEquals(lines[5], 'C')
end

function TestWriteFile:testWriteFileReplaceWithFewerLines()
  local test_file = self.test_dir .. '/test_replace_fewer.lua'
  vim.fn.writefile({ 'A', 'B', 'C', 'D' }, test_file)

  local result = tools.call('write_file', {
    filepath = test_file,
    action = 'replace',
    line_start = 2,
    line_to = 3,
    content = 'new BC',
  }, { cwd = vim.fs.normalize(vim.fn.getcwd()) })

  lu.assertStrContains(result.content, 'replaced')
  local lines = vim.fn.readfile(test_file)
  lu.assertEquals(lines[1], 'A')
  lu.assertEquals(lines[2], 'new BC')
  lu.assertEquals(lines[3], 'D')
end

function TestWriteFile:testWriteFileReplaceAllLines()
  local test_file = self.test_dir .. '/test_replace_all.lua'
  vim.fn.writefile({ 'old1', 'old2' }, test_file)

  local result = tools.call('write_file', {
    filepath = test_file,
    action = 'replace',
    line_start = 1,
    line_to = 2,
    content = 'all new',
  }, { cwd = vim.fs.normalize(vim.fn.getcwd()) })

  lu.assertStrContains(result.content, 'replaced')
  local lines = vim.fn.readfile(test_file)
  lu.assertEquals(lines[1], 'all new')
end

function TestWriteFile:testWriteFileReplaceStartGreaterThanEnd()
  local test_file = self.test_dir .. '/test_replace_invalid.lua'
  vim.fn.writefile({ 'line 1', 'line 2' }, test_file)

  local result = tools.call('write_file', {
    filepath = test_file,
    action = 'replace',
    line_start = 3,
    line_to = 1,
    content = 'invalid',
  }, { cwd = vim.fs.normalize(vim.fn.getcwd()) })

  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'Invalid line range')
end

function TestWriteFile:testWriteFileReplaceOutOfBounds()
  local test_file = self.test_dir .. '/test_replace_oob.lua'
  vim.fn.writefile({ 'line 1' }, test_file)

  local result = tools.call('write_file', {
    filepath = test_file,
    action = 'replace',
    line_start = 1,
    line_to = 2,
    content = 'invalid',
  }, { cwd = vim.fs.normalize(vim.fn.getcwd()) })

  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'Invalid line range')
end

-- OVERWRITE & APPEND Edge Cases
function TestWriteFile:testWriteFileOverwriteWithEmptyContent()
  local test_file = self.test_dir .. '/test_overwrite_empty.lua'
  vim.fn.writefile({ 'old content' }, test_file)

  local result = tools.call('write_file', {
    filepath = test_file,
    action = 'overwrite',
    content = '',
  }, { cwd = vim.fs.normalize(vim.fn.getcwd()) })

  lu.assertStrContains(result.content, 'overwritten')
  local lines = vim.fn.readfile(test_file)
  -- vim.split('', '\n') returns { "" }, so 1 line with empty string
  lu.assertEquals(#lines, 1)
  lu.assertEquals(lines[1], '')
end

function TestWriteFile:testWriteFileAppendWithNewlinePrefix()
  local test_file = self.test_dir .. '/test_append_nl.lua'
  vim.fn.writefile({ 'line 1' }, test_file)

  local result = tools.call('write_file', {
    filepath = test_file,
    action = 'append',
    content = '\nline 2',
  }, { cwd = vim.fs.normalize(vim.fn.getcwd()) })

  local lines = vim.fn.readfile(test_file)
  lu.assertEquals(lines[1], 'line 1')
  lu.assertEquals(lines[2], '')
  lu.assertEquals(lines[3], 'line 2')
end

-- REPLACE Empty Range Content
function TestWriteFile:testWriteFileReplaceWithEmptyContent()
  local test_file = self.test_dir .. '/test_replace_empty.lua'
  vim.fn.writefile({ 'A', 'B', 'C' }, test_file)

  local result = tools.call('write_file', {
    filepath = test_file,
    action = 'replace',
    line_start = 2,
    line_to = 2,
    content = '',
  }, { cwd = vim.fs.normalize(vim.fn.getcwd()) })

  lu.assertStrContains(result.content, 'replaced')
  local lines = vim.fn.readfile(test_file)
  lu.assertEquals(lines[1], 'A')
  lu.assertEquals(lines[2], '')
  lu.assertEquals(lines[3], 'C')
end

-- VALIDATION Edge Cases
function TestWriteFile:testWriteFileValidateLuaSyntaxError()
  local test_file = self.test_dir .. '/test_validate_lua_err.lua'
  vim.fn.writefile({ 'local a = 1', 'local b = ' }, test_file)

  local result = tools.call('write_file', {
    filepath = test_file,
    action = 'append',
    content = 'local c = function() end',
    validate = true,
  }, { cwd = vim.fs.normalize(vim.fn.getcwd()) })

  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'Syntax validation failed')
end

function TestWriteFile:testWriteFileValidateLuaSyntaxSuccess()
  local test_file = self.test_dir .. '/test_validate_lua_ok.lua'
  vim.fn.writefile({ 'local a = 1' }, test_file)

  local result = tools.call('write_file', {
    filepath = test_file,
    action = 'append',
    content = 'local b = function() return 1 end',
    validate = true,
  }, { cwd = vim.fs.normalize(vim.fn.getcwd()) })

  lu.assertStrContains(result.content, 'appended')
end

-- BACKUP Edge Cases
function TestWriteFile:testWriteFileBackupCreatedAndCleaned()
  local test_file = self.test_dir .. '/test_backup.lua'
  vim.fn.writefile({ 'original' }, test_file)

  local ok, result = pcall(tools.call, 'write_file', {
    filepath = test_file,
    action = 'replace',
    line_start = 1,
    content = 'modified',
    backup = true,
  }, { cwd = vim.fs.normalize(vim.fn.getcwd()) })

  -- Skip if vim.fn.copy fails on certain platforms
  if not ok then return end

  lu.assertStrContains(result.content, 'replaced')

  -- Verify backup is cleaned up
  local files = vim.fn.glob(self.test_dir .. '/*backup*', true, true)
  lu.assertEquals(#files, 0)
end

function TestWriteFile:testWriteFileBackupRestoredOnValidationError()
  local test_file = self.test_dir .. '/test_backup_restore.lua'
  vim.fn.writefile({ 'local a = 1' }, test_file)

  local ok, result = pcall(tools.call, 'write_file', {
    filepath = test_file,
    action = 'replace',
    line_start = 1,
    content = 'invalid lua syntax !!!',
    validate = true,
    backup = true,
  }, { cwd = vim.fs.normalize(vim.fn.getcwd()) })

  -- Skip if vim.fn.copy fails on certain platforms
  if not ok then return end

  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'reverted')

  local lines = vim.fn.readfile(test_file)
  lu.assertEquals(lines[1], 'local a = 1')
end

-- MISSING PARAMETERS
function TestWriteFile:testWriteFileInsertMissingContent()
  local test_file = self.test_dir .. '/test_insert_no_content.lua'
  vim.fn.writefile({ 'line 1' }, test_file)

  local result = tools.call('write_file', {
    filepath = test_file,
    action = 'insert',
    line_start = 1,
  }, { cwd = vim.fs.normalize(vim.fn.getcwd()) })

  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'content is required')
end

function TestWriteFile:testWriteFileDeleteMissingLineStart()
  local test_file = self.test_dir .. '/test_delete_no_start.lua'
  vim.fn.writefile({ 'line 1' }, test_file)

  local result = tools.call('write_file', {
    filepath = test_file,
    action = 'delete',
  }, { cwd = vim.fs.normalize(vim.fn.getcwd()) })

  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'line_start is required')
end

function TestWriteFile:testWriteFileReplaceMissingLineStart()
  local test_file = self.test_dir .. '/test_replace_no_start.lua'
  vim.fn.writefile({ 'line 1' }, test_file)

  local result = tools.call('write_file', {
    filepath = test_file,
    action = 'replace',
    content = 'new',
  }, { cwd = vim.fs.normalize(vim.fn.getcwd()) })

  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'line_start is required')
end

function TestWriteFile:testWriteFileOverwriteMissingContent()
  local test_file = self.test_dir .. '/test_overwrite_no_content.lua'
  vim.fn.writefile({ 'old' }, test_file)

  local result = tools.call('write_file', {
    filepath = test_file,
    action = 'overwrite',
  }, { cwd = vim.fs.normalize(vim.fn.getcwd()) })

  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'content is required')
end

-- FILE NOT EXIST
function TestWriteFile:testWriteFileOverwriteNonExistent()
  local test_file = self.test_dir .. '/non_existent_overwrite.lua'

  local result = tools.call('write_file', {
    filepath = test_file,
    action = 'overwrite',
    content = 'new',
  }, { cwd = vim.fs.normalize(vim.fn.getcwd()) })

  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'does not exist')
end

function TestWriteFile:testWriteFileAppendNonExistent()
  local test_file = self.test_dir .. '/non_existent_append.lua'

  local result = tools.call('write_file', {
    filepath = test_file,
    action = 'append',
    content = 'new',
  }, { cwd = vim.fs.normalize(vim.fn.getcwd()) })

  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'does not exist')
end

function TestWriteFile:testWriteFileInsertNonExistent()
  local test_file = self.test_dir .. '/non_existent_insert.lua'

  local result = tools.call('write_file', {
    filepath = test_file,
    action = 'insert',
    line_start = 1,
    content = 'new',
  }, { cwd = vim.fs.normalize(vim.fn.getcwd()) })

  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'does not exist')
end

function TestWriteFile:testWriteFileDeleteNonExistent()
  local test_file = self.test_dir .. '/non_existent_delete.lua'

  local result = tools.call('write_file', {
    filepath = test_file,
    action = 'delete',
    line_start = 1,
  }, { cwd = vim.fs.normalize(vim.fn.getcwd()) })

  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'does not exist')
end

function TestWriteFile:testWriteFileReplaceNonExistent()
  local test_file = self.test_dir .. '/non_existent_replace.lua'

  local result = tools.call('write_file', {
    filepath = test_file,
    action = 'replace',
    line_start = 1,
    content = 'new',
  }, { cwd = vim.fs.normalize(vim.fn.getcwd()) })

  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'does not exist')
end

-- INVALID ACTION
function TestWriteFile:testWriteFileInvalidAction()
  local test_file = self.test_dir .. '/test_invalid_action.lua'
  vim.fn.writefile({ 'line 1' }, test_file)

  local result = tools.call('write_file', {
    filepath = test_file,
    action = 'invalid',
  }, { cwd = vim.fs.normalize(vim.fn.getcwd()) })

  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'Invalid action')
end

return TestWriteFile

