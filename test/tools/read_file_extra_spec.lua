local lu = require('luaunit')
local tools = require('chat.tools')
local config = require('chat.config')
local read_file = require('chat.tools.read_file')

TestReadFileExtra = {}

function TestReadFileExtra:setUp()
  self.cwd = vim.fs.normalize(vim.fn.getcwd())
  config.setup({ allowed_path = self.cwd })
  self.test_dir = self.cwd .. '/test_temp_files_extra'
  if vim.fn.isdirectory(self.test_dir) == 0 then
    vim.fn.mkdir(self.test_dir, 'p')
  end
end

function TestReadFileExtra:tearDown()
  if vim.fn.isdirectory(self.test_dir) == 1 then
    vim.fn.delete(self.test_dir, 'rf')
  end
end

function TestReadFileExtra:testMissingFilepath()
  local result = tools.call('read_file', {}, { cwd = self.cwd })
  lu.assertNotNil(result)
  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'filepath is required')
end

function TestReadFileExtra:testNonexistentFile()
  local result = tools.call('read_file', {
    filepath = self.test_dir .. '/does_not_exist.txt',
  }, { cwd = self.cwd })
  lu.assertNotNil(result)
  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'not readable')
end

function TestReadFileExtra:testLineStartNotNumber()
  local f = self.test_dir .. '/a.txt'
  vim.fn.writefile({ 'a', 'b', 'c' }, f)
  local result = tools.call('read_file', {
    filepath = f,
    line_start = 'not-a-number',
  }, { cwd = self.cwd })
  lu.assertNotNil(result)
  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'line_start must be a number')
end

function TestReadFileExtra:testLineStartBelowOne()
  local f = self.test_dir .. '/b.txt'
  vim.fn.writefile({ 'a', 'b', 'c' }, f)
  local result = tools.call('read_file', {
    filepath = f,
    line_start = 0,
  }, { cwd = self.cwd })
  lu.assertNotNil(result)
  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'line_start must be at least 1')
end

function TestReadFileExtra:testLineToNotNumber()
  local f = self.test_dir .. '/c.txt'
  vim.fn.writefile({ 'a', 'b', 'c' }, f)
  local result = tools.call('read_file', {
    filepath = f,
    line_to = 'x',
  }, { cwd = self.cwd })
  lu.assertNotNil(result)
  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'line_to must be a number')
end

function TestReadFileExtra:testLineToBelowOne()
  local f = self.test_dir .. '/d.txt'
  vim.fn.writefile({ 'a', 'b', 'c' }, f)
  local result = tools.call('read_file', {
    filepath = f,
    line_to = 0,
  }, { cwd = self.cwd })
  lu.assertNotNil(result)
  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'line_to must be at least 1')
end

function TestReadFileExtra:testLineStartGreaterThanLineTo()
  local f = self.test_dir .. '/e.txt'
  vim.fn.writefile({ 'a', 'b', 'c' }, f)
  local result = tools.call('read_file', {
    filepath = f,
    line_start = 5,
    line_to = 2,
  }, { cwd = self.cwd })
  lu.assertNotNil(result)
  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'cannot be greater than')
end

function TestReadFileExtra:testLineToExceedsFileLength()
  local f = self.test_dir .. '/f.txt'
  vim.fn.writefile({ 'a', 'b', 'c' }, f)
  local result = tools.call('read_file', {
    filepath = f,
    line_to = 10,
  }, { cwd = self.cwd })
  lu.assertNotNil(result)
  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'exceeds file length')
end

function TestReadFileExtra:testLineStartExceedsFileLength()
  local f = self.test_dir .. '/g.txt'
  vim.fn.writefile({ 'a', 'b', 'c' }, f)
  local result = tools.call('read_file', {
    filepath = f,
    line_start = 10,
  }, { cwd = self.cwd })
  lu.assertNotNil(result)
  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'exceeds file length')
end

function TestReadFileExtra:testOnlyLineStart()
  local f = self.test_dir .. '/h.txt'
  vim.fn.writefile({ 'a', 'b', 'c', 'd' }, f)
  local result = tools.call('read_file', {
    filepath = f,
    line_start = 2,
  }, { cwd = self.cwd })
  lu.assertNotNil(result)
  lu.assertNotNil(result.content)
  lu.assertStrContains(result.content, 'b')
  lu.assertStrContains(result.content, 'd')
  lu.assertNotStrContains(result.content, 'a\n')
end

function TestReadFileExtra:testOnlyLineTo()
  local f = self.test_dir .. '/i.txt'
  vim.fn.writefile({ 'a', 'b', 'c', 'd' }, f)
  local result = tools.call('read_file', {
    filepath = f,
    line_to = 2,
  }, { cwd = self.cwd })
  lu.assertNotNil(result)
  lu.assertNotNil(result.content)
  lu.assertStrContains(result.content, 'a')
  lu.assertStrContains(result.content, 'b')
  lu.assertNotStrContains(result.content, 'c')
end

function TestReadFileExtra:testNotAllowedPath()
  local outside = vim.fs.normalize(vim.fn.stdpath('data')) .. '/read_out_' .. os.time() .. '.txt'
  vim.fn.writefile({ 'secret' }, outside)
  local result = tools.call('read_file', {
    filepath = outside,
  }, { cwd = self.cwd })
  lu.assertNotNil(result)
  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'not allowed')

  vim.fn.delete(outside, 'rf')
end

function TestReadFileExtra:testMacFileShowsNote()
  local f = self.test_dir .. '/mac.txt'
  local fh = assert(io.open(f, 'wb'))
  fh:write('line1\rline2\r')
  fh:close()

  local result = tools.call('read_file', { filepath = f }, { cwd = self.cwd })
  lu.assertNotNil(result.content)
  lu.assertStrContains(result.content, 'mac line endings (CR)')
  lu.assertStrContains(result.content, 'fileformat="mac"')
end

function TestReadFileExtra:testInfoDefault()
  local info = read_file.info('not json', { cwd = self.cwd })
  lu.assertEquals('read_file', info)
end

function TestReadFileExtra:testInfoFilepath()
  local info = read_file.info(
    vim.json.encode({ filepath = 'a.txt' }),
    { cwd = self.cwd }
  )
  lu.assertStrContains(info, 'read_file ')
  lu.assertStrContains(info, 'a.txt')
end

function TestReadFileExtra:testInfoWithLines()
  local info = read_file.info(
    vim.json.encode({ filepath = 'a.txt', line_start = 3, line_to = 5 }),
    { cwd = self.cwd }
  )
  lu.assertStrContains(info, '(lines 3-5)')
end

function TestReadFileExtra:testInfoWithOnlyLineTo()
  local info = read_file.info(
    vim.json.encode({ filepath = 'a.txt', line_to = 5 }),
    { cwd = self.cwd }
  )
  lu.assertStrContains(info, '(lines 1-5)')
end

function TestReadFileExtra:testScheme()
  local scheme = read_file.scheme()
  lu.assertEquals('read_file', scheme['function'].name)
end

return TestReadFileExtra
