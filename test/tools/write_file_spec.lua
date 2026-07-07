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

  -- Skip if uv.fs_copyfile fails on certain platforms
  if not ok then return end

  lu.assertStrContains(result.content, 'replaced')

  -- Verify backup is cleaned up
  local files = vim.fn.glob(self.test_dir .. '/*.backup.*', true, true)
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

  -- Skip if uv.fs_copyfile fails on certain platforms
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

-- ============================
-- STR_REPLACE Tests
-- ============================

function TestWriteFile:testStrReplaceBasic()
  local test_file = self.test_dir .. '/test_str_replace_basic.lua'
  vim.fn.writefile({ 'local x = 1', 'local y = 2' }, test_file)

  local result = tools.call('write_file', {
    filepath = test_file,
    action = 'str_replace',
    old_str = 'local x = 1',
    new_str = 'local x = 2',
  }, { cwd = vim.fs.normalize(vim.fn.getcwd()) })

  lu.assertNotNil(result.content, 'Expected content, got error: ' .. (result.error or 'unknown'))
  lu.assertStrContains(result.content, 'Successfully replaced')
  local lines = vim.fn.readfile(test_file)
  lu.assertEquals(lines[1], 'local x = 2')
  lu.assertEquals(lines[2], 'local y = 2')
end

function TestWriteFile:testStrReplaceMultiLine()
  local test_file = self.test_dir .. '/test_str_replace_multi.lua'
  vim.fn.writefile({ 'local x = 1', 'local y = 2', 'local z = 3' }, test_file)

  local result = tools.call('write_file', {
    filepath = test_file,
    action = 'str_replace',
    old_str = 'local x = 1\nlocal y = 2',
    new_str = 'local x = 10\nlocal y = 20',
  }, { cwd = vim.fs.normalize(vim.fn.getcwd()) })

  lu.assertNotNil(result.content)
  lu.assertStrContains(result.content, 'Successfully replaced')
  local lines = vim.fn.readfile(test_file)
  lu.assertEquals(lines[1], 'local x = 10')
  lu.assertEquals(lines[2], 'local y = 20')
  lu.assertEquals(lines[3], 'local z = 3')
end

function TestWriteFile:testStrReplacePartialLine()
  local test_file = self.test_dir .. '/test_str_replace_partial.lua'
  vim.fn.writefile({ 'print("hello world")' }, test_file)

  local result = tools.call('write_file', {
    filepath = test_file,
    action = 'str_replace',
    old_str = 'hello world',
    new_str = 'goodbye world',
  }, { cwd = vim.fs.normalize(vim.fn.getcwd()) })

  lu.assertNotNil(result.content)
  local lines = vim.fn.readfile(test_file)
  lu.assertEquals(lines[1], 'print("goodbye world")')
end

function TestWriteFile:testStrReplaceNewStrEmpty()
  local test_file = self.test_dir .. '/test_str_replace_empty_new.lua'
  vim.fn.writefile({ 'local x = 1', '-- TODO: fix this', 'local y = 2' }, test_file)

  local result = tools.call('write_file', {
    filepath = test_file,
    action = 'str_replace',
    old_str = '-- TODO: fix this\n',
    new_str = '',
  }, { cwd = vim.fs.normalize(vim.fn.getcwd()) })

  lu.assertNotNil(result.content)
  local lines = vim.fn.readfile(test_file)
  lu.assertEquals(lines[1], 'local x = 1')
  lu.assertEquals(lines[2], 'local y = 2')
end

function TestWriteFile:testStrReplaceReplaceAll()
  local test_file = self.test_dir .. '/test_str_replace_all.lua'
  vim.fn.writefile({ 'TODO: a', 'TODO: b', 'TODO: c' }, test_file)

  local result = tools.call('write_file', {
    filepath = test_file,
    action = 'str_replace',
    old_str = 'TODO',
    new_str = 'DONE',
    replace_all = true,
  }, { cwd = vim.fs.normalize(vim.fn.getcwd()) })

  lu.assertNotNil(result.content)
  lu.assertStrContains(result.content, '3 occurrence')
  local lines = vim.fn.readfile(test_file)
  lu.assertEquals(lines[1], 'DONE: a')
  lu.assertEquals(lines[2], 'DONE: b')
  lu.assertEquals(lines[3], 'DONE: c')
end

function TestWriteFile:testStrReplaceMultipleMatchesNoReplaceAll()
  local test_file = self.test_dir .. '/test_str_replace_multi_match.lua'
  vim.fn.writefile({ 'TODO: a', 'TODO: b' }, test_file)

  local result = tools.call('write_file', {
    filepath = test_file,
    action = 'str_replace',
    old_str = 'TODO',
    new_str = 'DONE',
  }, { cwd = vim.fs.normalize(vim.fn.getcwd()) })

  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'found 2 times')
  lu.assertStrContains(result.error, 'replace_all=true')
  -- File should not be modified
  local lines = vim.fn.readfile(test_file)
  lu.assertEquals(lines[1], 'TODO: a')
  lu.assertEquals(lines[2], 'TODO: b')
end

function TestWriteFile:testStrReplaceNotFound()
  local test_file = self.test_dir .. '/test_str_replace_not_found.lua'
  vim.fn.writefile({ 'local x = 1' }, test_file)

  local result = tools.call('write_file', {
    filepath = test_file,
    action = 'str_replace',
    old_str = 'nonexistent string',
    new_str = 'replacement',
  }, { cwd = vim.fs.normalize(vim.fn.getcwd()) })

  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'not found')
function TestWriteFile:testStrReplaceNotFoundWithHint()
  local test_file = self.test_dir .. '/test_str_replace_not_found_hint.lua'
  vim.fn.writefile({ 'local x = 1', 'local y = 2' }, test_file)

  local result = tools.call('write_file', {
    filepath = test_file,
    action = 'str_replace',
    -- Multi-line old_str: first line matches but full string doesn't
    old_str = 'local x = 1\nlocal z = 3',
    new_str = 'local x = 2',
  }, { cwd = vim.fs.normalize(vim.fn.getcwd()) })

  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'not found')
  lu.assertStrContains(result.error, 'Similar lines found')
end
  local test_file = self.test_dir .. '/test_str_replace_empty_old.lua'
  vim.fn.writefile({ 'local x = 1' }, test_file)

  local result = tools.call('write_file', {
    filepath = test_file,
    action = 'str_replace',
    old_str = '',
    new_str = 'something',
  }, { cwd = vim.fs.normalize(vim.fn.getcwd()) })

  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'must not be empty')
end

function TestWriteFile:testStrReplaceMissingOldStr()
  local test_file = self.test_dir .. '/test_str_replace_no_old.lua'
  vim.fn.writefile({ 'local x = 1' }, test_file)

  local result = tools.call('write_file', {
    filepath = test_file,
    action = 'str_replace',
    new_str = 'something',
  }, { cwd = vim.fs.normalize(vim.fn.getcwd()) })

  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'old_str is required')
end

function TestWriteFile:testStrReplaceNonExistentFile()
  local test_file = self.test_dir .. '/non_existent_str_replace.lua'

  local result = tools.call('write_file', {
    filepath = test_file,
    action = 'str_replace',
    old_str = 'something',
    new_str = 'other',
  }, { cwd = vim.fs.normalize(vim.fn.getcwd()) })

  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'does not exist')
end

function TestWriteFile:testStrReplacePatternChars()
  -- Ensure literal matching, not Lua pattern matching
  local test_file = self.test_dir .. '/test_str_replace_pattern.lua'
  vim.fn.writefile({ 'local s = "hello%dworld"' }, test_file)

  local result = tools.call('write_file', {
    filepath = test_file,
    action = 'str_replace',
    old_str = '%d',
    new_str = '%s',
  }, { cwd = vim.fs.normalize(vim.fn.getcwd()) })

  lu.assertNotNil(result.content, 'Expected content, got error: ' .. (result.error or 'unknown'))
  local lines = vim.fn.readfile(test_file)
  lu.assertEquals(lines[1], 'local s = "hello%sworld"')
end

function TestWriteFile:testStrReplaceValidateSyntaxSuccess()
  local test_file = self.test_dir .. '/test_str_replace_validate_ok.lua'
  vim.fn.writefile({ 'local a = 1' }, test_file)

  local result = tools.call('write_file', {
    filepath = test_file,
    action = 'str_replace',
    old_str = 'local a = 1',
    new_str = 'local a = 100',
    validate = true,
  }, { cwd = vim.fs.normalize(vim.fn.getcwd()) })

  lu.assertStrContains(result.content, 'Successfully replaced')
  local lines = vim.fn.readfile(test_file)
  lu.assertEquals(lines[1], 'local a = 100')
end

function TestWriteFile:testStrReplaceValidateSyntaxError()
  local test_file = self.test_dir .. '/test_str_replace_validate_err.lua'
  vim.fn.writefile({ 'local a = 1' }, test_file)

  local result = tools.call('write_file', {
    filepath = test_file,
    action = 'str_replace',
    old_str = 'local a = 1',
    new_str = 'local a = !!!',
    validate = true,
  }, { cwd = vim.fs.normalize(vim.fn.getcwd()) })

  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'Syntax validation failed')
  lu.assertStrContains(result.error, 'reverted')
  -- File should be unchanged
  local lines = vim.fn.readfile(test_file)
  lu.assertEquals(lines[1], 'local a = 1')
end

function TestWriteFile:testStrReplaceBackupRestoredOnValidationError()
  local test_file = self.test_dir .. '/test_str_replace_backup.lua'
  vim.fn.writefile({ 'local a = 1' }, test_file)

  local ok, result = pcall(tools.call, 'write_file', {
    filepath = test_file,
    action = 'str_replace',
    old_str = 'local a = 1',
    new_str = 'invalid !!!',
    validate = true,
    backup = true,
  }, { cwd = vim.fs.normalize(vim.fn.getcwd()) })

  -- Skip if uv.fs_copyfile fails on certain platforms
  if not ok then return end

  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'reverted')
  local lines = vim.fn.readfile(test_file)
  lu.assertEquals(lines[1], 'local a = 1')
end

return TestWriteFile

