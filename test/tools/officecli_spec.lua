local lu = require('luaunit')
local tools = require('chat.tools')
local config = require('chat.config')
local officecli = require('chat.tools.officecli')

-- Force the cached "officecli available" flag so we can exercise the
-- post-availability branches (mode validation, browser flag) in CI where
-- officecli itself is not installed.
local function set_officecli_available(val)
  local i = 1
  while true do
    local name, v = debug.getupvalue(officecli.officecli, i)
    if not name then
      break
    end
    if name == 'is_officecli_available' then
      local j = 1
      while true do
        local n2, v2 = debug.getupvalue(v, j)
        if not n2 then
          break
        end
        if n2 == 'officecli_available' then
          debug.setupvalue(v, j, val)
          return
        end
        j = j + 1
      end
    end
    i = i + 1
  end
end

TestOfficeCli = {}

function TestOfficeCli:setUp()
  self.cwd = vim.fs.normalize(vim.fn.getcwd())
  config.setup({ allowed_path = self.cwd })
  self.test_file = self.cwd .. '/office_test_' .. os.time() .. '.xlsx'
  vim.fn.writefile({ 'fake xlsx' }, self.test_file)
end

function TestOfficeCli:tearDown()
  if vim.fn.filereadable(self.test_file) == 1 then
    vim.fn.delete(self.test_file)
  end
end

function TestOfficeCli:testUnsupportedCommand()
  local result = tools.call('officecli', {
    command = 'edit',
    filepath = self.test_file,
  }, { cwd = self.cwd })
  lu.assertNotNil(result)
  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'unsupported command')
end

function TestOfficeCli:testMissingFilepath()
  local result = tools.call('officecli', {
    command = 'view',
  }, { cwd = self.cwd })
  lu.assertNotNil(result)
  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'filepath is required')
end

function TestOfficeCli:testNotReadable()
  local result = tools.call('officecli', {
    command = 'view',
    filepath = self.cwd .. '/does_not_exist.xlsx',
  }, { cwd = self.cwd })
  lu.assertNotNil(result)
  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'not readable')
end

function TestOfficeCli:testNotAllowedPath()
  local outside = vim.fs.normalize(vim.fn.stdpath('data')) .. '/office_out_' .. os.time() .. '.xlsx'
  vim.fn.writefile({ 'x' }, outside)
  local result = tools.call('officecli', {
    command = 'view',
    filepath = outside,
  }, { cwd = self.cwd })
  lu.assertNotNil(result)
  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'not allowed path')

  vim.fn.delete(outside, 'rf')
end

function TestOfficeCli:testInvalidMode()
  set_officecli_available(true)
  local result = tools.call('officecli', {
    command = 'view',
    filepath = self.test_file,
    mode = 'bogus',
  }, { cwd = self.cwd })
  lu.assertNotNil(result)
  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'invalid mode')
end

function TestOfficeCli:testBrowserOnlyValidForHtml()
  set_officecli_available(true)
  local result = tools.call('officecli', {
    command = 'view',
    filepath = self.test_file,
    mode = 'text',
    browser = true,
  }, { cwd = self.cwd })
  lu.assertNotNil(result)
  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'browser flag is only valid')
end

function TestOfficeCli:testNotInstalled()
  -- Force officecli_available to false (nil cache) to exercise the
  -- "not installed" branch when real officecli is absent.
  set_officecli_available(false)
  local result = tools.call('officecli', {
    command = 'view',
    filepath = self.test_file,
    mode = 'text',
  }, { cwd = self.cwd })
  lu.assertNotNil(result)
  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'not installed')
end

function TestOfficeCli:testInfoDefault()
  local info = officecli.info('not json', { cwd = self.cwd })
  lu.assertEquals('officecli', info)
end

function TestOfficeCli:testInfoFull()
  local info = officecli.info(
    vim.json.encode({
      command = 'view',
      filepath = 'data.xlsx',
      mode = 'text',
      start = 1,
      ['end'] = 50,
      cols = 'A,B',
      max_lines = 10,
      json = true,
      browser = true,
    }),
    { cwd = self.cwd }
  )
  lu.assertStrContains(info, 'officecli')
  lu.assertStrContains(info, 'view')
  lu.assertStrContains(info, 'filepath=')
  lu.assertStrContains(info, 'mode=text')
  lu.assertStrContains(info, 'start=1')
  lu.assertStrContains(info, 'end=50')
  lu.assertStrContains(info, 'cols=A,B')
  lu.assertStrContains(info, 'max_lines=10')
  lu.assertStrContains(info, 'json=true')
  lu.assertStrContains(info, 'browser=true')
end

function TestOfficeCli:testScheme()
  local scheme = officecli.scheme()
  lu.assertEquals('function', scheme.type)
  lu.assertEquals('officecli', scheme['function'].name)
  lu.assertNotNil(scheme['function'].parameters.properties.mode)
end

return TestOfficeCli
