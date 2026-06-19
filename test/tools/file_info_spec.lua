local lu = require('luaunit')
local tools = require('chat.tools')
local config = require('chat.config')

TestFileInfo = {}

function TestFileInfo:setUp()
  self.test_dir = vim.fs.normalize(vim.fn.getcwd()) .. '/test_temp_fileinfo'
  if vim.fn.isdirectory(self.test_dir) == 0 then
    vim.fn.mkdir(self.test_dir, 'p')
  end

  config.setup({
    allowed_path = vim.fs.normalize(vim.fn.getcwd()),
  })
end

function TestFileInfo:tearDown()
  if self.test_dir and vim.fn.isdirectory(self.test_dir) == 1 then
    vim.fn.delete(self.test_dir, 'rf')
  end
end

-- ============================
-- File Info Tests
-- ============================

function TestFileInfo:testFileInfoBasic()
  local file = self.test_dir .. '/test.lua'
  vim.fn.writefile({ 'line 1', 'line 2', 'line 3' }, file)

  local result = tools.call('file_info', {
    filepath = file,
  }, { cwd = vim.fs.normalize(vim.fn.getcwd()) })

  lu.assertNotNil(result)
  lu.assertNotNil(result.content, 'Expected content, got error: ' .. (result.error or 'unknown'))
  lu.assertStrContains(result.content, 'Path:')
  lu.assertStrContains(result.content, 'Type:       file')
  lu.assertStrContains(result.content, 'Size:')
  lu.assertStrContains(result.content, 'Modified:')
  lu.assertStrContains(result.content, 'Permissions:')
  lu.assertStrContains(result.content, 'Lines:      3')
end

function TestFileInfo:testFileInfoShowsSize()
  local file = self.test_dir .. '/sized.lua'
  vim.fn.writefile({ 'hello world this is content' }, file)

  local result = tools.call('file_info', {
    filepath = file,
  }, { cwd = vim.fs.normalize(vim.fn.getcwd()) })

  lu.assertNotNil(result)
  lu.assertNotNil(result.content)
  lu.assertStrContains(result.content, 'Size:')
  -- Should contain bytes info
  lu.assertStrContains(result.content, 'bytes')
end

function TestFileInfo:testFileInfoEmptyFile()
  local file = self.test_dir .. '/empty.lua'
  vim.fn.writefile({ '' }, file)

  local result = tools.call('file_info', {
    filepath = file,
  }, { cwd = vim.fs.normalize(vim.fn.getcwd()) })

  lu.assertNotNil(result)
  lu.assertNotNil(result.content)
  lu.assertStrContains(result.content, 'Type:       file')
end

-- ============================
-- Directory Info Tests
-- ============================

function TestFileInfo:testDirInfoBasic()
  local dir = self.test_dir .. '/info_dir'
  vim.fn.mkdir(dir, 'p')
  vim.fn.writefile({ 'a' }, dir .. '/a.lua')
  vim.fn.writefile({ 'b' }, dir .. '/b.lua')

  local result = tools.call('file_info', {
    filepath = dir,
  }, { cwd = vim.fs.normalize(vim.fn.getcwd()) })

  lu.assertNotNil(result)
  lu.assertNotNil(result.content)
  lu.assertStrContains(result.content, 'Type:       dir')
  lu.assertStrContains(result.content, 'Entries:    2')
end

function TestFileInfo:testDirInfoEmpty()
  local dir = self.test_dir .. '/empty_dir'
  vim.fn.mkdir(dir, 'p')

  local result = tools.call('file_info', {
    filepath = dir,
  }, { cwd = vim.fs.normalize(vim.fn.getcwd()) })

  lu.assertNotNil(result)
  lu.assertNotNil(result.content)
  lu.assertStrContains(result.content, 'Entries:    0')
end

-- ============================
-- Error Cases
-- ============================

function TestFileInfo:testFileInfoNonExistent()
  local result = tools.call('file_info', {
    filepath = self.test_dir .. '/nonexistent.lua',
  }, { cwd = vim.fs.normalize(vim.fn.getcwd()) })

  lu.assertNotNil(result)
  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'does not exist')
end

function TestFileInfo:testFileInfoMissingPath()
  local result = tools.call('file_info', {}, { cwd = vim.fs.normalize(vim.fn.getcwd()) })

  lu.assertNotNil(result)
  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'filepath')
end

function TestFileInfo:testFileInfoMissingCwd()
  local file = self.test_dir .. '/no_cwd.lua'
  vim.fn.writefile({ 'content' }, file)

  local result = tools.call('file_info', {
    filepath = file,
  }, { cwd = '' })

  lu.assertNotNil(result)
  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'cwd')
end

-- ============================
-- Security Tests
-- ============================

function TestFileInfo:testFileInfoSecurityOutsideCwd()
  local result = tools.call('file_info', {
    filepath = '../../../etc/passwd',
  }, { cwd = vim.fs.normalize(vim.fn.getcwd()) })

  lu.assertNotNil(result)
  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'Security')
end

function TestFileInfo:testFileInfoSecurityNotAllowedPath()
  local temp_dir = vim.fn.tempname()
  vim.fn.mkdir(temp_dir, 'p')
  local temp_file = temp_dir .. '/test.lua'
  vim.fn.writefile({ 'content' }, temp_file)

  local result = tools.call('file_info', {
    filepath = temp_file,
  }, { cwd = temp_dir })

  lu.assertNotNil(result)
  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'allowed_path')

  vim.fn.delete(temp_dir, 'rf')
end

-- ============================
-- Scheme and Info Tests
-- ============================

function TestFileInfo:testFileInfoScheme()
  local file_info = require('chat.tools.file_info')
  local scheme = file_info.scheme()

  lu.assertNotNil(scheme)
  lu.assertEquals(scheme.type, 'function')
  lu.assertEquals(scheme['function'].name, 'file_info')
  lu.assertEquals(scheme['function'].parameters.type, 'object')

  local required = scheme['function'].parameters.required
  lu.assertTrue(vim.tbl_contains(required, 'filepath'))
end

function TestFileInfo:testFileInfoInfo()
  local file_info = require('chat.tools.file_info')
  local info = file_info.info(
    '{"filepath":"./src/main.lua"}',
    { cwd = '/test' }
  )

  lu.assertNotNil(info)
  lu.assertStrContains(info, 'file_info')
  lu.assertStrContains(info, 'main.lua')
end

function TestFileInfo:testFileInfoInfoInvalidJson()
  local file_info = require('chat.tools.file_info')
  local info = file_info.info('invalid json', { cwd = '/test' })
  lu.assertEquals(info, 'file_info')
end

-- ============================
-- Tool Registration Test
-- ============================

function TestFileInfo:testFileInfoRegistered()
  local available = tools.available_tools()
  local tool_names = {}
  for _, tool in ipairs(available) do
    table.insert(tool_names, tool['function'].name)
  end

  lu.assertTrue(
    vim.tbl_contains(tool_names, 'file_info'),
    'file_info should be in available_tools'
  )
end

return TestFileInfo

