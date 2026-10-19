local lu = require('luaunit')
local tools = require('chat.tools')
local config = require('chat.config')
local search_text = require('chat.tools.search_text')

local function call_async_tool(func, arguments, ctx, timeout)
  timeout = timeout or 5000
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

TestSearchText = {}

function TestSearchText:setUp()
  self.cwd = vim.fs.normalize(vim.fn.getcwd())
  config.setup({ allowed_path = self.cwd })
  self.test_dir = self.cwd .. '/search_test_dir_' .. os.time() .. '_' .. math.random(1000, 9999)
  vim.fn.mkdir(self.test_dir, 'p')
  vim.fn.writefile({ 'hello world foo bar', 'second line foo' }, self.test_dir .. '/a.txt')
  vim.fn.writefile({ 'another foo here' }, self.test_dir .. '/b.txt')
end

function TestSearchText:tearDown()
  if vim.fn.isdirectory(self.test_dir) == 1 then
    vim.fn.delete(self.test_dir, 'rf')
  end
end

function TestSearchText:testMissingPattern()
  local result = tools.call('search_text', {}, { cwd = self.cwd })
  lu.assertNotNil(result)
  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'Pattern is required')
end

function TestSearchText:testEmptyPattern()
  local result = tools.call('search_text', { pattern = '' }, { cwd = self.cwd })
  lu.assertNotNil(result)
  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'Pattern is required')
end

function TestSearchText:testFileTypesNonTable()
  local result = tools.call('search_text', {
    pattern = 'foo',
    file_types = 123,
  }, { cwd = self.cwd })
  lu.assertNotNil(result)
  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'file_types must be an array')
end

function TestSearchText:testExcludePatternsNonTable()
  local result = tools.call('search_text', {
    pattern = 'foo',
    exclude_patterns = 123,
  }, { cwd = self.cwd })
  lu.assertNotNil(result)
  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'exclude_patterns must be an array')
end

function TestSearchText:testDirectoryDoesNotExist()
  local result = tools.call('search_text', {
    pattern = 'foo',
    directory = './nonexistent_dir_xyz',
  }, { cwd = self.cwd })
  lu.assertNotNil(result)
  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'Directory does not exist')
end

function TestSearchText:testInfoDefault()
  local info = search_text.info('not json', { cwd = self.cwd })
  lu.assertEquals('search_text', info)
end

function TestSearchText:testInfoFull()
  local info = search_text.info(
    vim.json.encode({
      pattern = 'foo',
      ignore_case = true,
      whole_word = true,
      regex = false,
      file_types = { '*.lua', '*.md' },
      max_results = 50,
      context_lines = 2,
    }),
    { cwd = self.cwd }
  )
  lu.assertStrContains(info, 'search_text "foo"')
  lu.assertStrContains(info, 'ignore_case')
  lu.assertStrContains(info, 'whole_word')
  lu.assertStrContains(info, 'no_regex')
  lu.assertStrContains(info, 'file_types: ["*.lua", "*.md"]')
  lu.assertStrContains(info, 'max: 50')
  lu.assertStrContains(info, 'context: 2')
end

function TestSearchText:testScheme()
  local scheme = search_text.scheme()
  lu.assertEquals('function', scheme.type)
  lu.assertEquals('search_text', scheme['function'].name)
  lu.assertNotNil(scheme['function'].parameters.required)
end

function TestSearchText:testSearchMatches()
  if vim.fn.executable('rg') ~= 1 then
    print('Skipping testSearchMatches: rg not available')
    return
  end
  local result = call_async_tool('search_text', {
    pattern = 'foo',
    directory = self.test_dir,
  }, { cwd = self.cwd })
  lu.assertNotNil(result)
  lu.assertNotNil(result.content, 'Expected content, got error: ' .. (result.error or 'unknown'))
  lu.assertStrContains(result.content, 'Found')
  lu.assertStrContains(result.content, 'foo')

  vim.fn.delete(self.test_dir, 'rf')
end

function TestSearchText:testSearchNoMatches()
  if vim.fn.executable('rg') ~= 1 then
    print('Skipping testSearchNoMatches: rg not available')
    return
  end
  local result = call_async_tool('search_text', {
    pattern = 'zzzz_no_match_xyz',
    directory = self.test_dir,
  }, { cwd = self.cwd })
  lu.assertNotNil(result)
  lu.assertNotNil(result.content, 'Expected content, got error: ' .. (result.error or 'unknown'))
  lu.assertStrContains(result.content, 'No matches found')
end

function TestSearchText:testSearchWithFileTypes()
  if vim.fn.executable('rg') ~= 1 then
    print('Skipping testSearchWithFileTypes: rg not available')
    return
  end
  local result = call_async_tool('search_text', {
    pattern = 'foo',
    directory = self.test_dir,
    file_types = { '*.txt' },
    ignore_case = true,
    whole_word = true,
  }, { cwd = self.cwd })
  lu.assertNotNil(result)
  lu.assertNotNil(result.content, 'Expected content, got error: ' .. (result.error or 'unknown'))
end

function TestSearchText:testSearchWithRegexDisabled()
  if vim.fn.executable('rg') ~= 1 then
    print('Skipping testSearchWithRegexDisabled: rg not available')
    return
  end
  local result = call_async_tool('search_text', {
    pattern = 'foo',
    directory = self.test_dir,
    regex = false,
    max_results = 5,
    context_lines = 1,
  }, { cwd = self.cwd })
  lu.assertNotNil(result)
  lu.assertNotNil(result.content, 'Expected content, got error: ' .. (result.error or 'unknown'))
end

function TestSearchText:testSearchFileTypesAsString()
  if vim.fn.executable('rg') ~= 1 then
    print('Skipping testSearchFileTypesAsString: rg not available')
    return
  end
  local result = call_async_tool('search_text', {
    pattern = 'foo',
    directory = self.test_dir,
    file_types = '*.txt',
    exclude_patterns = '*.log',
  }, { cwd = self.cwd })
  lu.assertNotNil(result)
  lu.assertNotNil(result.content, 'Expected content, got error: ' .. (result.error or 'unknown'))
end

return TestSearchText
