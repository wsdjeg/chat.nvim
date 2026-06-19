local lu = require('luaunit')
local tools = require('chat.tools')
local config = require('chat.config')

TestCreateDirectory = {}

function TestCreateDirectory:setUp()
  self.test_dir = vim.fs.normalize(vim.fn.getcwd()) .. '/test_temp_mkdir'
  if vim.fn.isdirectory(self.test_dir) == 0 then
    vim.fn.mkdir(self.test_dir, 'p')
  end

  config.setup({
    allowed_path = vim.fs.normalize(vim.fn.getcwd()),
  })
end

function TestCreateDirectory:tearDown()
  if self.test_dir and vim.fn.isdirectory(self.test_dir) == 1 then
    vim.fn.delete(self.test_dir, 'rf')
  end
end

-- ============================
-- Basic Create Tests
-- ============================

function TestCreateDirectory:testCreateBasic()
  local dir = self.test_dir .. '/new_dir'

  local result = tools.call('create_directory', {
    path = dir,
  }, { cwd = vim.fs.normalize(vim.fn.getcwd()) })

  lu.assertNotNil(result)
  lu.assertNotNil(result.content, 'Expected content, got error: ' .. (result.error or 'unknown'))
  lu.assertStrContains(result.content, 'Successfully created')
  lu.assertEquals(vim.fn.isdirectory(dir), 1)
end

function TestCreateDirectory:testCreateRelativePath()
  local dir = self.test_dir .. '/relative_dir'
  local cwd = vim.fs.normalize(vim.fn.getcwd())

  local result = tools.call('create_directory', {
    path = 'test_temp_mkdir/relative_dir',
  }, { cwd = cwd })

  lu.assertNotNil(result)
  lu.assertNotNil(result.content)
  lu.assertStrContains(result.content, 'Successfully created')
  lu.assertEquals(vim.fn.isdirectory(dir), 1)
end

function TestCreateDirectory:testCreateNestedDirectories()
  local dir = self.test_dir .. '/a/b/c/d'

  local result = tools.call('create_directory', {
    path = dir,
  }, { cwd = vim.fs.normalize(vim.fn.getcwd()) })

  lu.assertNotNil(result)
  lu.assertNotNil(result.content)
  lu.assertStrContains(result.content, 'Successfully created')
  lu.assertEquals(vim.fn.isdirectory(dir), 1)
  lu.assertEquals(vim.fn.isdirectory(self.test_dir .. '/a/b/c'), 1)
end

-- ============================
-- Already Exists Tests
-- ============================

function TestCreateDirectory:testCreateAlreadyExists()
  local dir = self.test_dir .. '/exists'
  vim.fn.mkdir(dir, 'p')

  local result = tools.call('create_directory', {
    path = dir,
  }, { cwd = vim.fs.normalize(vim.fn.getcwd()) })

  lu.assertNotNil(result)
  lu.assertNotNil(result.content)
  lu.assertStrContains(result.content, 'already exists')
  lu.assertEquals(vim.fn.isdirectory(dir), 1)
end

function TestCreateDirectory:testCreatePathIsFile()
  local file = self.test_dir .. '/a_file.lua'
  vim.fn.writefile({ 'content' }, file)

  local result = tools.call('create_directory', {
    path = file,
  }, { cwd = vim.fs.normalize(vim.fn.getcwd()) })

  lu.assertNotNil(result)
  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'not a directory')
end

-- ============================
-- Error Cases
-- ============================

function TestCreateDirectory:testCreateMissingPath()
  local result = tools.call('create_directory', {}, { cwd = vim.fs.normalize(vim.fn.getcwd()) })

  lu.assertNotNil(result)
  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'path')
end

function TestCreateDirectory:testCreateEmptyPath()
  local result = tools.call('create_directory', {
    path = '',
  }, { cwd = vim.fs.normalize(vim.fn.getcwd()) })

  lu.assertNotNil(result)
  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'path')
end

function TestCreateDirectory:testCreateMissingCwd()
  local result = tools.call('create_directory', {
    path = self.test_dir .. '/no_cwd',
  }, { cwd = '' })

  lu.assertNotNil(result)
  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'cwd')
end

-- ============================
-- Security Tests
-- ============================

function TestCreateDirectory:testCreateSecurityOutsideCwd()
  local result = tools.call('create_directory', {
    path = '../../../tmp/malicious_dir',
  }, { cwd = vim.fs.normalize(vim.fn.getcwd()) })

  lu.assertNotNil(result)
  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'Security')
end

function TestCreateDirectory:testCreateSecurityNotAllowedPath()
  local temp_dir = vim.fn.tempname()
  vim.fn.mkdir(temp_dir, 'p')

  local result = tools.call('create_directory', {
    path = temp_dir .. '/new_sub',
  }, { cwd = temp_dir })

  lu.assertNotNil(result)
  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'allowed_path')

  vim.fn.delete(temp_dir, 'rf')
end

-- ============================
-- Scheme and Info Tests
-- ============================

function TestCreateDirectory:testCreateDirectoryScheme()
  local create_directory = require('chat.tools.create_directory')
  local scheme = create_directory.scheme()

  lu.assertNotNil(scheme)
  lu.assertEquals(scheme.type, 'function')
  lu.assertEquals(scheme['function'].name, 'create_directory')
  lu.assertEquals(scheme['function'].parameters.type, 'object')

  local required = scheme['function'].parameters.required
  lu.assertTrue(vim.tbl_contains(required, 'path'))
end

function TestCreateDirectory:testCreateDirectoryInfo()
  local create_directory = require('chat.tools.create_directory')
  local info = create_directory.info(
    '{"path":"./src/utils"}',
    { cwd = '/test' }
  )

  lu.assertNotNil(info)
  lu.assertStrContains(info, 'create_directory')
  lu.assertStrContains(info, 'utils')
end

function TestCreateDirectory:testCreateDirectoryInfoInvalidJson()
  local create_directory = require('chat.tools.create_directory')
  local info = create_directory.info('invalid json', { cwd = '/test' })
  lu.assertEquals(info, 'create_directory')
end

-- ============================
-- Tool Registration Test
-- ============================

function TestCreateDirectory:testCreateDirectoryRegistered()
  local available = tools.available_tools()
  local tool_names = {}
  for _, tool in ipairs(available) do
    table.insert(tool_names, tool['function'].name)
  end

  lu.assertTrue(
    vim.tbl_contains(tool_names, 'create_directory'),
    'create_directory should be in available_tools'
  )
end

return TestCreateDirectory

