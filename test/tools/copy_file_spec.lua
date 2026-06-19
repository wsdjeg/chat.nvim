local lu = require('luaunit')
local tools = require('chat.tools')
local config = require('chat.config')

TestCopyFile = {}

function TestCopyFile:setUp()
  self.test_dir = vim.fs.normalize(vim.fn.getcwd()) .. '/test_temp_copy'
  if vim.fn.isdirectory(self.test_dir) == 0 then
    vim.fn.mkdir(self.test_dir, 'p')
  end

  config.setup({
    allowed_path = vim.fs.normalize(vim.fn.getcwd()),
  })
end

function TestCopyFile:tearDown()
  if self.test_dir and vim.fn.isdirectory(self.test_dir) == 1 then
    vim.fn.delete(self.test_dir, 'rf')
  end
end

-- ============================
-- Basic Copy Tests
-- ============================

function TestCopyFile:testCopyFileBasic()
  local source = self.test_dir .. '/source.lua'
  local dest = self.test_dir .. '/dest.lua'
  vim.fn.writefile({ 'hello world' }, source)

  local result = tools.call('copy_file', {
    source = source,
    destination = dest,
  }, { cwd = vim.fs.normalize(vim.fn.getcwd()) })

  lu.assertNotNil(result)
  lu.assertNotNil(
    result.content,
    'Expected content, got error: ' .. (result.error or 'unknown')
  )
  lu.assertStrContains(result.content, 'Successfully copied')
  -- Both files should exist (copy preserves source)
  lu.assertEquals(vim.fn.filereadable(source), 1)
  lu.assertEquals(vim.fn.filereadable(dest), 1)

  local lines = vim.fn.readfile(dest)
  lu.assertEquals(lines[1], 'hello world')
end

function TestCopyFile:testCopyFileRelativePath()
  local source = self.test_dir .. '/rel_source.lua'
  local dest = self.test_dir .. '/rel_dest.lua'
  vim.fn.writefile({ 'relative' }, source)

  local cwd = vim.fs.normalize(vim.fn.getcwd())
  local result = tools.call('copy_file', {
    source = 'test_temp_copy/rel_source.lua',
    destination = 'test_temp_copy/rel_dest.lua',
  }, { cwd = cwd })

  lu.assertNotNil(result)
  lu.assertNotNil(result.content)
  lu.assertStrContains(result.content, 'Successfully copied')
  lu.assertEquals(vim.fn.filereadable(source), 1)
  lu.assertEquals(vim.fn.filereadable(dest), 1)
end

-- ============================
-- Directory Copy Tests
-- ============================

function TestCopyFile:testCopyDirectory()
  local source = self.test_dir .. '/src_dir'
  local dest = self.test_dir .. '/dst_dir'
  vim.fn.mkdir(source, 'p')
  vim.fn.writefile({ 'file A' }, source .. '/a.lua')
  vim.fn.writefile({ 'file B' }, source .. '/b.lua')

  local result = tools.call('copy_file', {
    source = source,
    destination = dest,
  }, { cwd = vim.fs.normalize(vim.fn.getcwd()) })

  lu.assertNotNil(result)
  lu.assertNotNil(result.content)
  lu.assertStrContains(result.content, 'Successfully copied')
  lu.assertEquals(vim.fn.isdirectory(source), 1)
  lu.assertEquals(vim.fn.isdirectory(dest), 1)
  lu.assertEquals(vim.fn.filereadable(dest .. '/a.lua'), 1)
  lu.assertEquals(vim.fn.filereadable(dest .. '/b.lua'), 1)

  local lines_a = vim.fn.readfile(dest .. '/a.lua')
  lu.assertEquals(lines_a[1], 'file A')
end

function TestCopyFile:testCopyDirectoryWithSubdirectories()
  local source = self.test_dir .. '/nested_src'
  local dest = self.test_dir .. '/nested_dst'
  vim.fn.mkdir(source .. '/inner', 'p')
  vim.fn.writefile({ 'top' }, source .. '/top.lua')
  vim.fn.writefile({ 'inner' }, source .. '/inner/deep.lua')

  local result = tools.call('copy_file', {
    source = source,
    destination = dest,
  }, { cwd = vim.fs.normalize(vim.fn.getcwd()) })

  lu.assertNotNil(result)
  lu.assertNotNil(result.content)
  lu.assertStrContains(result.content, 'Successfully copied')
  lu.assertEquals(vim.fn.isdirectory(dest), 1)
  lu.assertEquals(vim.fn.isdirectory(dest .. '/inner'), 1)
  lu.assertEquals(vim.fn.filereadable(dest .. '/top.lua'), 1)
  lu.assertEquals(vim.fn.filereadable(dest .. '/inner/deep.lua'), 1)

  local lines = vim.fn.readfile(dest .. '/inner/deep.lua')
  lu.assertEquals(lines[1], 'inner')
end

-- ============================
-- Overwrite Tests
-- ============================

function TestCopyFile:testCopyFileOverwriteExisting()
  local source = self.test_dir .. '/overwrite_src.lua'
  local dest = self.test_dir .. '/overwrite_dst.lua'
  vim.fn.writefile({ 'source content' }, source)
  vim.fn.writefile({ 'old dest content' }, dest)

  local result = tools.call('copy_file', {
    source = source,
    destination = dest,
    overwrite = true,
  }, { cwd = vim.fs.normalize(vim.fn.getcwd()) })

  lu.assertNotNil(result)
  lu.assertNotNil(result.content)
  lu.assertStrContains(result.content, 'Successfully copied')
  lu.assertEquals(vim.fn.filereadable(source), 1)
  lu.assertEquals(vim.fn.filereadable(dest), 1)

  local lines = vim.fn.readfile(dest)
  lu.assertEquals(lines[1], 'source content')
end

function TestCopyFile:testCopyFileNoOverwriteExisting()
  local source = self.test_dir .. '/no_overwrite_src.lua'
  local dest = self.test_dir .. '/no_overwrite_dst.lua'
  vim.fn.writefile({ 'source' }, source)
  vim.fn.writefile({ 'dest' }, dest)

  local result = tools.call('copy_file', {
    source = source,
    destination = dest,
  }, { cwd = vim.fs.normalize(vim.fn.getcwd()) })

  lu.assertNotNil(result)
  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'already exists')
  lu.assertEquals(vim.fn.filereadable(source), 1)
  lu.assertEquals(vim.fn.filereadable(dest), 1)
end

-- ============================
-- Self-copy Prevention
-- ============================

function TestCopyFile:testCopyFileSamePath()
  local source = self.test_dir .. '/same.lua'
  vim.fn.writefile({ 'content' }, source)

  local result = tools.call('copy_file', {
    source = source,
    destination = source,
  }, { cwd = vim.fs.normalize(vim.fn.getcwd()) })

  lu.assertNotNil(result)
  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'same path')
end

function TestCopyFile:testCopyDirectoryIntoSelf()
  local source = self.test_dir .. '/self_dir'
  vim.fn.mkdir(source, 'p')

  local result = tools.call('copy_file', {
    source = source,
    destination = source .. '/subdir',
  }, { cwd = vim.fs.normalize(vim.fn.getcwd()) })

  lu.assertNotNil(result)
  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'into itself')
end

-- ============================
-- Error Cases
-- ============================

function TestCopyFile:testCopyFileSourceNotExist()
  local result = tools.call('copy_file', {
    source = self.test_dir .. '/nonexistent.lua',
    destination = self.test_dir .. '/dest.lua',
  }, { cwd = vim.fs.normalize(vim.fn.getcwd()) })

  lu.assertNotNil(result)
  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'does not exist')
end

function TestCopyFile:testCopyFileMissingSource()
  local result = tools.call('copy_file', {
    destination = self.test_dir .. '/dest.lua',
  }, { cwd = vim.fs.normalize(vim.fn.getcwd()) })

  lu.assertNotNil(result)
  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'source')
end

function TestCopyFile:testCopyFileMissingDestination()
  local source = self.test_dir .. '/missing_dest_src.lua'
  vim.fn.writefile({ 'content' }, source)

  local result = tools.call('copy_file', {
    source = source,
  }, { cwd = vim.fs.normalize(vim.fn.getcwd()) })

  lu.assertNotNil(result)
  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'destination')
end

function TestCopyFile:testCopyFileEmptySource()
  local result = tools.call('copy_file', {
    source = '',
    destination = self.test_dir .. '/dest.lua',
  }, { cwd = vim.fs.normalize(vim.fn.getcwd()) })

  lu.assertNotNil(result)
  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'source')
end

function TestCopyFile:testCopyFileEmptyDestination()
  local source = self.test_dir .. '/empty_dest_src.lua'
  vim.fn.writefile({ 'content' }, source)

  local result = tools.call('copy_file', {
    source = source,
    destination = '',
  }, { cwd = vim.fs.normalize(vim.fn.getcwd()) })

  lu.assertNotNil(result)
  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'destination')
end

function TestCopyFile:testCopyFileMissingCwd()
  local source = self.test_dir .. '/no_cwd.lua'
  vim.fn.writefile({ 'content' }, source)

  local result = tools.call('copy_file', {
    source = source,
    destination = self.test_dir .. '/dest.lua',
  }, { cwd = '' })

  lu.assertNotNil(result)
  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'cwd')
end

-- ============================
-- Security Tests
-- ============================

function TestCopyFile:testCopyFileSecuritySourceOutsideCwd()
  local result = tools.call('copy_file', {
    source = '../../../etc/passwd',
    destination = self.test_dir .. '/dest.lua',
  }, { cwd = vim.fs.normalize(vim.fn.getcwd()) })

  lu.assertNotNil(result)
  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'Security')
end

function TestCopyFile:testCopyFileSecurityDestinationOutsideCwd()
  local source = self.test_dir .. '/security_src.lua'
  vim.fn.writefile({ 'content' }, source)

  local result = tools.call('copy_file', {
    source = source,
    destination = '../../../tmp/malicious.lua',
  }, { cwd = vim.fs.normalize(vim.fn.getcwd()) })

  lu.assertNotNil(result)
  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'Security')
end

function TestCopyFile:testCopyFileSecurityNotAllowedPath()
  local temp_dir = vim.fn.tempname()
  vim.fn.mkdir(temp_dir, 'p')
  local temp_source = temp_dir .. '/source.lua'
  local temp_dest = temp_dir .. '/dest.lua'
  vim.fn.writefile({ 'content' }, temp_source)

  local result = tools.call('copy_file', {
    source = temp_source,
    destination = temp_dest,
  }, { cwd = temp_dir })

  lu.assertNotNil(result)
  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'allowed_path')

  vim.fn.delete(temp_dir, 'rf')
end

-- ============================
-- Scheme and Info Tests
-- ============================

function TestCopyFile:testCopyFileScheme()
  local copy_file = require('chat.tools.copy_file')
  local scheme = copy_file.scheme()

  lu.assertNotNil(scheme)
  lu.assertEquals(scheme.type, 'function')
  lu.assertEquals(scheme['function'].name, 'copy_file')
  lu.assertEquals(scheme['function'].parameters.type, 'object')

  local required = scheme['function'].parameters.required
  lu.assertTrue(vim.tbl_contains(required, 'source'))
  lu.assertTrue(vim.tbl_contains(required, 'destination'))
end

function TestCopyFile:testCopyFileInfo()
  local copy_file = require('chat.tools.copy_file')
  local info = copy_file.info(
    '{"source":"./a.lua","destination":"./b.lua"}',
    { cwd = '/test' }
  )

  lu.assertNotNil(info)
  lu.assertStrContains(info, 'copy_file')
  lu.assertStrContains(info, 'a.lua')
  lu.assertStrContains(info, 'b.lua')
end

function TestCopyFile:testCopyFileInfoWithOverwrite()
  local copy_file = require('chat.tools.copy_file')
  local info = copy_file.info(
    '{"source":"./a.lua","destination":"./b.lua","overwrite":true}',
    { cwd = '/test' }
  )

  lu.assertNotNil(info)
  lu.assertStrContains(info, 'overwrite')
end

function TestCopyFile:testCopyFileInfoInvalidJson()
  local copy_file = require('chat.tools.copy_file')
  local info = copy_file.info('invalid json', { cwd = '/test' })
  lu.assertEquals(info, 'copy_file')
end

-- ============================
-- Tool Registration Test
-- ============================

function TestCopyFile:testCopyFileRegistered()
  local available = tools.available_tools()
  local tool_names = {}
  for _, tool in ipairs(available) do
    table.insert(tool_names, tool['function'].name)
  end

  lu.assertTrue(
    vim.tbl_contains(tool_names, 'copy_file'),
    'copy_file should be in available_tools'
  )
end

return TestCopyFile

