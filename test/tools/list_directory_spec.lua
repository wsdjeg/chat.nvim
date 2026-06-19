local lu = require('luaunit')
local tools = require('chat.tools')
local config = require('chat.config')

TestListDirectory = {}

function TestListDirectory:setUp()
  self.test_dir = vim.fs.normalize(vim.fn.getcwd()) .. '/test_temp_listdir'
  if vim.fn.isdirectory(self.test_dir) == 0 then
    vim.fn.mkdir(self.test_dir, 'p')
  end

  config.setup({
    allowed_path = vim.fs.normalize(vim.fn.getcwd()),
  })
end

function TestListDirectory:tearDown()
  if self.test_dir and vim.fn.isdirectory(self.test_dir) == 1 then
    vim.fn.delete(self.test_dir, 'rf')
  end
end

-- ============================
-- Basic Listing Tests
-- ============================

function TestListDirectory:testListBasic()
  local dir = self.test_dir .. '/basic'
  vim.fn.mkdir(dir, 'p')
  vim.fn.writefile({ 'a' }, dir .. '/file_a.lua')
  vim.fn.writefile({ 'b' }, dir .. '/file_b.lua')

  local result = tools.call('list_directory', {
    path = dir,
  }, { cwd = vim.fs.normalize(vim.fn.getcwd()) })

  lu.assertNotNil(result)
  lu.assertNotNil(result.content, 'Expected content, got error: ' .. (result.error or 'unknown'))
  lu.assertStrContains(result.content, 'file_a.lua')
  lu.assertStrContains(result.content, 'file_b.lua')
  lu.assertStrContains(result.content, '2 items')
end

function TestListDirectory:testListEmptyDirectory()
  local dir = self.test_dir .. '/empty'
  vim.fn.mkdir(dir, 'p')

  local result = tools.call('list_directory', {
    path = dir,
  }, { cwd = vim.fs.normalize(vim.fn.getcwd()) })

  lu.assertNotNil(result)
  lu.assertNotNil(result.content)
  lu.assertStrContains(result.content, 'empty')
end

function TestListDirectory:testListWithDirectories()
  local dir = self.test_dir .. '/with_dirs'
  vim.fn.mkdir(dir, 'p')
  vim.fn.mkdir(dir .. '/subdir', 'p')
  vim.fn.writefile({ 'file' }, dir .. '/file.lua')

  local result = tools.call('list_directory', {
    path = dir,
  }, { cwd = vim.fs.normalize(vim.fn.getcwd()) })

  lu.assertNotNil(result)
  lu.assertNotNil(result.content)
  lu.assertStrContains(result.content, 'subdir')
  lu.assertStrContains(result.content, 'file.lua')
  -- Should show 2 items
  lu.assertStrContains(result.content, '2 items')
end

-- ============================
-- Recursive Listing Tests
-- ============================

function TestListDirectory:testListRecursive()
  local dir = self.test_dir .. '/recursive'
  vim.fn.mkdir(dir .. '/sub', 'p')
  vim.fn.writefile({ 'top' }, dir .. '/top.lua')
  vim.fn.writefile({ 'deep' }, dir .. '/sub/deep.lua')

  local result = tools.call('list_directory', {
    path = dir,
    recursive = true,
  }, { cwd = vim.fs.normalize(vim.fn.getcwd()) })

  lu.assertNotNil(result)
  lu.assertNotNil(result.content)
  lu.assertStrContains(result.content, 'top.lua')
  lu.assertStrContains(result.content, 'sub/deep.lua')
end

function TestListDirectory:testListNonRecursiveOmitsSubdirectoryContents()
  local dir = self.test_dir .. '/non_recursive'
  vim.fn.mkdir(dir .. '/sub', 'p')
  vim.fn.writefile({ 'deep' }, dir .. '/sub/deep.lua')
  vim.fn.writefile({ 'top' }, dir .. '/top.lua')

  local result = tools.call('list_directory', {
    path = dir,
    recursive = false,
  }, { cwd = vim.fs.normalize(vim.fn.getcwd()) })

  lu.assertNotNil(result)
  lu.assertNotNil(result.content)
  -- Should see the directory and top file
  lu.assertStrContains(result.content, 'sub')
  lu.assertStrContains(result.content, 'top.lua')
  -- Should NOT see the deep file
  lu.assertNotStrContains(result.content, 'deep.lua')
end

-- ============================
-- Hidden Files Tests
-- ============================

function TestListDirectory:testListHiddenFilesDefault()
  local dir = self.test_dir .. '/hidden_default'
  vim.fn.mkdir(dir, 'p')
  vim.fn.writefile({ 'visible' }, dir .. '/visible.lua')
  vim.fn.writefile({ 'hidden' }, dir .. '/.hidden.lua')

  local result = tools.call('list_directory', {
    path = dir,
  }, { cwd = vim.fs.normalize(vim.fn.getcwd()) })

  lu.assertNotNil(result)
  lu.assertNotNil(result.content)
  lu.assertStrContains(result.content, 'visible.lua')
  lu.assertNotStrContains(result.content, '.hidden.lua')
end

function TestListDirectory:testListShowHidden()
  local dir = self.test_dir .. '/show_hidden'
  vim.fn.mkdir(dir, 'p')
  vim.fn.writefile({ 'visible' }, dir .. '/visible.lua')
  vim.fn.writefile({ 'hidden' }, dir .. '/.hidden.lua')

  local result = tools.call('list_directory', {
    path = dir,
    show_hidden = true,
  }, { cwd = vim.fs.normalize(vim.fn.getcwd()) })

  lu.assertNotNil(result)
  lu.assertNotNil(result.content)
  lu.assertStrContains(result.content, 'visible.lua')
  lu.assertStrContains(result.content, '.hidden.lua')
end

-- ============================
-- Max Results Tests
-- ============================

function TestListDirectory:testListMaxResults()
  local dir = self.test_dir .. '/max_results'
  vim.fn.mkdir(dir, 'p')
  for i = 1, 10 do
    vim.fn.writefile({ 'file ' .. i }, dir .. '/file_' .. i .. '.lua')
  end

  local result = tools.call('list_directory', {
    path = dir,
    max_results = 3,
  }, { cwd = vim.fs.normalize(vim.fn.getcwd()) })

  lu.assertNotNil(result)
  lu.assertNotNil(result.content)
  lu.assertStrContains(result.content, 'truncated')
end

-- ============================
-- Error Cases
-- ============================

function TestListDirectory:testListNonExistentDirectory()
  local result = tools.call('list_directory', {
    path = self.test_dir .. '/nonexistent',
  }, { cwd = vim.fs.normalize(vim.fn.getcwd()) })

  lu.assertNotNil(result)
  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'does not exist')
end

function TestListDirectory:testListFileNotDirectory()
  local file = self.test_dir .. '/not_a_dir.lua'
  vim.fn.writefile({ 'content' }, file)

  local result = tools.call('list_directory', {
    path = file,
  }, { cwd = vim.fs.normalize(vim.fn.getcwd()) })

  lu.assertNotNil(result)
  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'not a directory')
end

function TestListDirectory:testListMissingPath()
  local result = tools.call('list_directory', {}, { cwd = vim.fs.normalize(vim.fn.getcwd()) })

  lu.assertNotNil(result)
  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'path')
end

function TestListDirectory:testListMissingCwd()
  local dir = self.test_dir .. '/no_cwd'
  vim.fn.mkdir(dir, 'p')

  local result = tools.call('list_directory', {
    path = dir,
  }, { cwd = '' })

  lu.assertNotNil(result)
  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'cwd')
end

-- ============================
-- Security Tests
-- ============================

function TestListDirectory:testListSecurityOutsideCwd()
  local result = tools.call('list_directory', {
    path = '../../../etc',
  }, { cwd = vim.fs.normalize(vim.fn.getcwd()) })

  lu.assertNotNil(result)
  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'Security')
end

function TestListDirectory:testListSecurityNotAllowedPath()
  local temp_dir = vim.fn.tempname()
  vim.fn.mkdir(temp_dir, 'p')

  local result = tools.call('list_directory', {
    path = temp_dir,
  }, { cwd = temp_dir })

  lu.assertNotNil(result)
  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'allowed_path')

  vim.fn.delete(temp_dir, 'rf')
end

-- ============================
-- Scheme and Info Tests
-- ============================

function TestListDirectory:testListDirectoryScheme()
  local list_directory = require('chat.tools.list_directory')
  local scheme = list_directory.scheme()

  lu.assertNotNil(scheme)
  lu.assertEquals(scheme.type, 'function')
  lu.assertEquals(scheme['function'].name, 'list_directory')
  lu.assertEquals(scheme['function'].parameters.type, 'object')

  local required = scheme['function'].parameters.required
  lu.assertTrue(vim.tbl_contains(required, 'path'))
end

function TestListDirectory:testListDirectoryInfo()
  local list_directory = require('chat.tools.list_directory')
  local info = list_directory.info(
    '{"path":"./src"}',
    { cwd = '/test' }
  )

  lu.assertNotNil(info)
  lu.assertStrContains(info, 'list_directory')
  lu.assertStrContains(info, 'src')
end

function TestListDirectory:testListDirectoryInfoWithFlags()
  local list_directory = require('chat.tools.list_directory')
  local info = list_directory.info(
    '{"path":"./src","recursive":true,"show_hidden":true}',
    { cwd = '/test' }
  )

  lu.assertNotNil(info)
  lu.assertStrContains(info, 'recursive')
  lu.assertStrContains(info, 'hidden')
end

function TestListDirectory:testListDirectoryInfoInvalidJson()
  local list_directory = require('chat.tools.list_directory')
  local info = list_directory.info('invalid json', { cwd = '/test' })
  lu.assertEquals(info, 'list_directory')
end

-- ============================
-- Tool Registration Test
-- ============================

function TestListDirectory:testListDirectoryRegistered()
  local available = tools.available_tools()
  local tool_names = {}
  for _, tool in ipairs(available) do
    table.insert(tool_names, tool['function'].name)
  end

  lu.assertTrue(
    vim.tbl_contains(tool_names, 'list_directory'),
    'list_directory should be in available_tools'
  )
end

return TestListDirectory

