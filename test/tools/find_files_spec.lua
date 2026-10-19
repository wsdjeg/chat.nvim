local lu = require('luaunit')
local tools = require('chat.tools')
local config = require('chat.config')
local find_files = require('chat.tools.find_files')

-- Helper function to test async tools
local function call_async_tool(func, arguments, ctx, timeout)
  timeout = timeout or 2000
  local result_received = false
  local actual_result = nil
  local result = tools.call(
    func,
    arguments,
    vim.tbl_extend('force', ctx, {
      callback = function(res)
        result_received = true
        actual_result = res
      end,
    })
  )
  if result.error then
    return result
  end
  local wait_ok = vim.wait(timeout, function()
    return result_received
  end, 50)
  if not wait_ok then
    return { error = 'Async tool did not complete within ' .. timeout .. 'ms' }
  end
  return actual_result
end

TestFindFiles = {}

function TestFindFiles:setUp()
  self.test_dir = vim.fs.normalize(vim.fn.getcwd()) .. '/test_temp_files'
  if vim.fn.isdirectory(self.test_dir) == 0 then
    vim.fn.mkdir(self.test_dir, 'p')
  end

  config.setup({
    allowed_path = vim.fs.normalize(vim.fn.getcwd()),
  })
end

function TestFindFiles:tearDown()
  if self.test_dir and vim.fn.isdirectory(self.test_dir) == 1 then
    vim.fn.delete(self.test_dir, 'rf')
  end
end

function TestFindFiles:testCallFindFiles()
  local test_file = self.test_dir .. '/test_find.lua'
  vim.fn.writefile({ '-- test file for find_files' }, test_file)

  local cwd = vim.fs.normalize(vim.fn.getcwd())

  local result = call_async_tool('find_files', {
    pattern = '**/test_find.lua',
  }, { cwd = cwd })

  lu.assertNotNil(result)
  lu.assertNotNil(
    result.content,
    'Expected content, got error: ' .. (result.error or 'unknown')
  )
  lu.assertStrContains(result.content, 'test_find.lua')
end

function TestFindFiles:testMissingPattern()
  local result = tools.call('find_files', {}, {
    cwd = vim.fs.normalize(vim.fn.getcwd()),
  })
  lu.assertNotNil(result)
  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'Pattern is required')
end

function TestFindFiles:testEmptyPattern()
  local result = tools.call('find_files', { pattern = '' }, {
    cwd = vim.fs.normalize(vim.fn.getcwd()),
  })
  lu.assertNotNil(result)
  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'Pattern is required')
end

function TestFindFiles:testSecurityOutsideAllowedPath()
  local temp_dir = vim.fs.normalize(vim.fn.stdpath('data')) .. '/find_out_' .. os.time()
  vim.fn.mkdir(temp_dir, 'p')
  local result = tools.call('find_files', { pattern = '*.lua' }, { cwd = temp_dir })
  lu.assertNotNil(result)
  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'non-allowed path')
  vim.fn.delete(temp_dir, 'rf')
end

function TestFindFiles:testDirectoryOutsideAllowedPath()
  local result = tools.call('find_files', {
    pattern = '*.lua',
    directory = '../outside',
  }, { cwd = vim.fs.normalize(vim.fn.getcwd()) })
  lu.assertNotNil(result)
  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'outside allowed path')
end

function TestFindFiles:testDirectoryDoesNotExist()
  local result = tools.call('find_files', {
    pattern = '*.lua',
    directory = './nonexistent_subdir_xyz',
  }, { cwd = vim.fs.normalize(vim.fn.getcwd()) })
  lu.assertNotNil(result)
  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'Directory does not exist')
end

function TestFindFiles:testInfoDefault()
  local info = find_files.info('not json', { cwd = vim.fn.getcwd() })
  lu.assertEquals('find_files', info)
end

function TestFindFiles:testInfoFull()
  local info = find_files.info(
    vim.json.encode({
      pattern = '*.lua',
      directory = './lua',
      hidden = true,
      no_ignore = true,
      exclude = { '*.test.lua' },
      max_results = 50,
    }),
    { cwd = vim.fn.getcwd() }
  )
  lu.assertStrContains(info, 'find_files "*.lua"')
  lu.assertStrContains(info, 'hidden')
  lu.assertStrContains(info, 'no_ignore')
  lu.assertStrContains(info, 'exclude=!*.test.lua')
  lu.assertStrContains(info, 'max_results=50')
end

function TestFindFiles:testInfoUppercasePattern()
  local info = find_files.info(
    vim.json.encode({ pattern = 'Makefile' }),
    { cwd = vim.fn.getcwd() }
  )
  lu.assertNotStrContains(info, 'ignore_case')
end

function TestFindFiles:testInfoExcludeString()
  local info = find_files.info(
    vim.json.encode({ pattern = '*.lua', exclude = '*.test.lua' }),
    { cwd = vim.fn.getcwd() }
  )
  lu.assertStrContains(info, 'exclude=!*.test.lua')
end

function TestFindFiles:testScheme()
  local scheme = find_files.scheme()
  lu.assertEquals('function', scheme.type)
  lu.assertEquals('find_files', scheme['function'].name)
  lu.assertNotNil(scheme['function'].parameters.properties.max_results)
end

function TestFindFiles:testNoMatches()
  local result = call_async_tool('find_files', {
    pattern = '*.zzzzz_no_match',
  }, { cwd = vim.fs.normalize(vim.fn.getcwd()) })
  lu.assertNotNil(result)
  lu.assertNotNil(
    result.content,
    'Expected content, got error: ' .. (result.error or 'unknown')
  )
  lu.assertStrContains(result.content, 'No files found')
end

function TestFindFiles:testWithExclude()
  local test_file = self.test_dir .. '/test_excl.lua'
  vim.fn.writefile({ '-- exclude me' }, test_file)

  local result = call_async_tool('find_files', {
    pattern = '*.lua',
    directory = self.test_dir,
    exclude = { '*excl*' },
  }, { cwd = vim.fs.normalize(vim.fn.getcwd()) })
  lu.assertNotNil(result)
  lu.assertNotNil(
    result.content,
    'Expected content, got error: ' .. (result.error or 'unknown')
  )
  lu.assertNotStrContains(result.content, 'test_excl.lua')
end

function TestFindFiles:testWithHiddenAndNoIgnore()
  local result = call_async_tool('find_files', {
    pattern = '*.lua',
    directory = self.test_dir,
    hidden = true,
    no_ignore = true,
    max_results = 5,
  }, { cwd = vim.fs.normalize(vim.fn.getcwd()) })
  lu.assertNotNil(result)
  lu.assertNotNil(
    result.content,
    'Expected content, got error: ' .. (result.error or 'unknown')
  )
end

return TestFindFiles
