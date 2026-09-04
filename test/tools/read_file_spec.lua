local lu = require('luaunit')
local tools = require('chat.tools')
local config = require('chat.config')

TestReadFile = {}

function TestReadFile:setUp()
  self.test_dir = vim.fs.normalize(vim.fn.getcwd()) .. '/test_temp_files'
  if vim.fn.isdirectory(self.test_dir) == 0 then
    vim.fn.mkdir(self.test_dir, 'p')
  end

  config.setup({
    allowed_path = vim.fs.normalize(vim.fn.getcwd()),
  })
end

function TestReadFile:tearDown()
  if self.test_dir and vim.fn.isdirectory(self.test_dir) == 1 then
    vim.fn.delete(self.test_dir, 'rf')
  end
end

function TestReadFile:testCallReadFile()
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

  lu.assertNotNil(result)
  lu.assertNotNil(
    result.content,
    'Expected content, got error: ' .. (result.error or 'unknown')
  )
  lu.assertStrContains(result.content, 'test content line 1')
end

function TestReadFile:testCallReadFileWithLines()
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

  lu.assertNotNil(result)
  lu.assertNotNil(
    result.content,
    'Expected content, got error: ' .. (result.error or 'unknown')
  )
  lu.assertStrContains(result.content, 'Line 3')
  lu.assertStrContains(result.content, 'Line 5')
end

function TestReadFile:testReadDosFileShowsNote()
  local test_file = self.test_dir .. '/test_read_dos.lua'
  local f = assert(io.open(test_file, 'wb'))
  f:write('line 1\r\nline 2\r\n')
  f:close()

  local result = tools.call('read_file', {
    filepath = test_file,
  }, { cwd = vim.fs.normalize(vim.fn.getcwd()) })

  lu.assertNotNil(
    result.content,
    'Expected content, got error: ' .. (result.error or 'unknown')
  )
  -- CR characters are stripped from the content itself
  lu.assertStrContains(result.content, 'line 1\nline 2')
  lu.assertNotStrContains(result.content, 'line 1\r\n')
  -- A note about the line endings is appended
  lu.assertStrContains(result.content, 'dos line endings (CRLF)')
  lu.assertStrContains(result.content, 'fileformat="dos"')
end

function TestReadFile:testReadUnixFileHasNoNote()
  local test_file = self.test_dir .. '/test_read_unix.lua'
  vim.fn.writefile({ 'line 1', 'line 2' }, test_file)

  local result = tools.call('read_file', {
    filepath = test_file,
  }, { cwd = vim.fs.normalize(vim.fn.getcwd()) })

  lu.assertNotNil(
    result.content,
    'Expected content, got error: ' .. (result.error or 'unknown')
  )
  lu.assertNotStrContains(result.content, 'line endings')
end

