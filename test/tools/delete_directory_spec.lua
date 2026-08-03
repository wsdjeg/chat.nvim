local lu = require('luaunit')
local tools = require('chat.tools')
local config = require('chat.config')

TestDeleteDirectory = {}

function TestDeleteDirectory:setUp()
  self.test_dir = vim.fs.normalize(vim.fn.getcwd()) .. '/test_temp_rmdir'
  if vim.fn.isdirectory(self.test_dir) == 0 then
    vim.fn.mkdir(self.test_dir, 'p')
  end

  config.setup({
    allowed_path = vim.fs.normalize(vim.fn.getcwd()),
  })
end

function TestDeleteDirectory:tearDown()
  if self.test_dir and vim.fn.isdirectory(self.test_dir) == 1 then
    vim.fn.delete(self.test_dir, 'rf')
  end
end

-- ============================
-- Basic Delete Tests
-- ============================

function TestDeleteDirectory:testDeleteBasic()
  local dir = self.test_dir .. '/to_delete'
  vim.fn.mkdir(dir, 'p')

  local result = tools.call('delete_directory', {
    path = dir,
  }, { cwd = vim.fs.normalize(vim.fn.getcwd()) })

  lu.assertNotNil(result)
  lu.assertNotNil(result.content, 'Expected content, got error: ' .. (result.error or 'unknown'))
  lu.assertStrContains(result.content, 'Successfully deleted')
  lu.assertEquals(vim.fn.isdirectory(dir), 0)
end

function TestDeleteDirectory:testDeleteRelativePath()
  local dir = self.test_dir .. '/relative_del'
  vim.fn.mkdir(dir, 'p')
  local cwd = vim.fs.normalize(vim.fn.getcwd())

  local result = tools.call('delete_directory', {
    path = 'test_temp_rmdir/relative_del',
  }, { cwd = cwd })

  lu.assertNotNil(result)
  lu.assertNotNil(result.content)
  lu.assertStrContains(result.content, 'Successfully deleted')
  lu.assertEquals(vim.fn.isdirectory(dir), 0)
end

function TestDeleteDirectory:testDeleteEmptyDirectory()
  local dir = self.test_dir .. '/empty'
  vim.fn.mkdir(dir, 'p')

  local result = tools.call('delete_directory', {
    path = dir,
  }, { cwd = vim.fs.normalize(vim.fn.getcwd()) })

  lu.assertNotNil(result)
  lu.assertNotNil(result.content)
  lu.assertStrContains(result.content, 'empty directory')
  lu.assertEquals(vim.fn.isdirectory(dir), 0)
end

function TestDeleteDirectory:testDeleteRecursiveWithFiles()
  local dir = self.test_dir .. '/recursive'
  vim.fn.mkdir(dir .. '/sub1/sub2', 'p')
  vim.fn.writefile({ 'file1' }, dir .. '/file1.txt')
  vim.fn.writefile({ 'file2' }, dir .. '/sub1/file2.txt')
  vim.fn.writefile({ 'file3' }, dir .. '/sub1/sub2/file3.txt')

  local result = tools.call('delete_directory', {
    path = dir,
  }, { cwd = vim.fs.normalize(vim.fn.getcwd()) })

  lu.assertNotNil(result)
  lu.assertNotNil(result.content)
  lu.assertStrContains(result.content, 'Successfully deleted')
  lu.assertStrContains(result.content, '3 files')
  lu.assertEquals(vim.fn.isdirectory(dir), 0)
end

function TestDeleteDirectory:testDeleteRecursiveNestedDirs()
  local dir = self.test_dir .. '/nested'
  vim.fn.mkdir(dir .. '/a/b/c', 'p')

  local result = tools.call('delete_directory', {
    path = dir,
  }, { cwd = vim.fs.normalize(vim.fn.getcwd()) })

  lu.assertNotNil(result)
  lu.assertNotNil(result.content)
  lu.assertStrContains(result.content, '3 subdirectories')
  lu.assertEquals(vim.fn.isdirectory(dir), 0)
end

-- ============================
-- Error Cases
-- ============================

function TestDeleteDirectory:testDeleteNonExistent()
  local dir = self.test_dir .. '/does_not_exist'

  local result = tools.call('delete_directory', {
    path = dir,
  }, { cwd = vim.fs.normalize(vim.fn.getcwd()) })

  lu.assertNotNil(result)
  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'does not exist')
end

function TestDeleteDirectory:testDeletePathIsFile()
  local file = self.test_dir .. '/a_file.lua'
  vim.fn.writefile({ 'content' }, file)

  local result = tools.call('delete_directory', {
    path = file,
  }, { cwd = vim.fs.normalize(vim.fn.getcwd()) })

  lu.assertNotNil(result)
  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'not a directory')
end

function TestDeleteDirectory:testDeleteMissingPath()
  local result = tools.call('delete_directory', {}, { cwd = vim.fs.normalize(vim.fn.getcwd()) })

  lu.assertNotNil(result)
  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'path')
end

function TestDeleteDirectory:testDeleteEmptyPath()
  local result = tools.call('delete_directory', {
    path = '',
  }, { cwd = vim.fs.normalize(vim.fn.getcwd()) })

  lu.assertNotNil(result)
  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'path')
end

function TestDeleteDirectory:testDeleteMissingCwd()
  local result = tools.call('delete_directory', {
    path = self.test_dir .. '/no_cwd',
  }, { cwd = '' })

  lu.assertNotNil(result)
  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'cwd')
end

-- ============================
-- Security Tests
-- ============================

function TestDeleteDirectory:testDeleteSecurityOutsideCwd()
  local result = tools.call('delete_directory', {
    path = '../../../tmp/malicious_dir',
  }, { cwd = vim.fs.normalize(vim.fn.getcwd()) })

  lu.assertNotNil(result)
  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'Security')
end

function TestDeleteDirectory:testDeleteSecurityNotAllowedPath()
  local temp_dir = vim.fn.tempname()
  vim.fn.mkdir(temp_dir .. '/sub', 'p')

  local result = tools.call('delete_directory', {
    path = temp_dir .. '/sub',
  }, { cwd = temp_dir })

  lu.assertNotNil(result)
  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'allowed_path')

  vim.fn.delete(temp_dir, 'rf')
end

function TestDeleteDirectory:testDeleteSafetyRefuseCwd()
  local cwd = vim.fs.normalize(vim.fn.getcwd())

  local result = tools.call('delete_directory', {
    path = cwd,
  }, { cwd = cwd })

  lu.assertNotNil(result)
  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'Safety')
  lu.assertStrContains(result.error, 'working directory')
end

-- ============================
-- Scheme and Info Tests
-- ============================

function TestDeleteDirectory:testDeleteDirectoryScheme()
  local delete_directory = require('chat.tools.delete_directory')
  local scheme = delete_directory.scheme()

  lu.assertNotNil(scheme)
  lu.assertEquals(scheme.type, 'function')
  lu.assertEquals(scheme['function'].name, 'delete_directory')
  lu.assertEquals(scheme['function'].parameters.type, 'object')

  local required = scheme['function'].parameters.required
  lu.assertTrue(vim.tbl_contains(required, 'path'))
end

function TestDeleteDirectory:testDeleteDirectoryInfo()
  local delete_directory = require('chat.tools.delete_directory')
  local info = delete_directory.info(
    '{"path":"./old_build"}',
    { cwd = '/test' }
  )

  lu.assertNotNil(info)
  lu.assertStrContains(info, 'delete_directory')
  lu.assertStrContains(info, 'old_build')
end

function TestDeleteDirectory:testDeleteDirectoryInfoInvalidJson()
  local delete_directory = require('chat.tools.delete_directory')
  local info = delete_directory.info('invalid json', { cwd = '/test' })
  lu.assertEquals(info, 'delete_directory')
end

-- ============================
-- Tool Registration Test
-- ============================

function TestDeleteDirectory:testDeleteDirectoryRegistered()
  local available = tools.available_tools()
  local tool_names = {}
  for _, tool in ipairs(available) do
    table.insert(tool_names, tool['function'].name)
  end

  lu.assertTrue(
    vim.tbl_contains(tool_names, 'delete_directory'),
    'delete_directory should be in available_tools'
  )
end

return TestDeleteDirectory

