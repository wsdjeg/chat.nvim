local lu = require('luaunit')
local tools = require('chat.tools')
local config = require('chat.config')
local make_tool = require('chat.tools.make')
local storage = require('chat.sessions.storage')

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

local function make_temp_dir(name)
  local cache_dir = vim.fs.normalize(vim.fn.stdpath('data'))
  local temp_dir = cache_dir
    .. '/test_'
    .. name
    .. '_'
    .. os.time()
    .. '_'
    .. math.random(10000, 99999)
  vim.fn.mkdir(temp_dir, 'p')
  return vim.fs.normalize(temp_dir)
end

local function set_allowed_path(path)
  config.config.allowed_path = vim.fs.normalize(path)
end

TestMake = {}

function TestMake:setUp()
  set_allowed_path(vim.fn.getcwd())
end

function TestMake:tearDown()
  set_allowed_path(vim.fn.getcwd())
  storage.sessions = {}
end

function TestMake:testMakeAvailable()
  local available = tools.available_tools()
  local tool_names = {}
  for _, tool in ipairs(available) do
    tool_names[tool['function'].name] = true
  end
  lu.assertTrue(tool_names['make'], 'make tool should be available')
end

function TestMake:testMakeSecurityOutsideAllowedPath()
  local temp_dir = make_temp_dir('security')
  local result = tools.call('make', { target = 'test' }, { cwd = temp_dir })
  lu.assertNotNil(result)
  lu.assertNotNil(result.error, 'Should reject path outside allowed_path')
  lu.assertStrContains(result.error, 'allowed')
  vim.fn.delete(temp_dir, 'rf')
end

function TestMake:testMakeDirectoryOutsideWorkingDir()
  local temp_dir = make_temp_dir('dir_out')
  set_allowed_path(temp_dir)
  local result = tools.call('make', {
    directory = '../outside',
  }, { cwd = temp_dir })
  lu.assertNotNil(result)
  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'outside working directory')
  vim.fn.delete(temp_dir, 'rf')
end

function TestMake:testInfoDefault()
  local info = make_tool.info('not json', { cwd = vim.fn.getcwd() })
  lu.assertEquals('make', info)
end

function TestMake:testInfoFull()
  local info = make_tool.info(
    vim.json.encode({ target = 'test', args = { '-j4' }, directory = './sub' }),
    { cwd = vim.fn.getcwd() }
  )
  lu.assertStrContains(info, 'target="test"')
  lu.assertStrContains(info, 'args=')
  lu.assertStrContains(info, 'directory="./sub"')
end

function TestMake:testScheme()
  local scheme = make_tool.scheme()
  lu.assertEquals('function', scheme.type)
  lu.assertEquals('make', scheme['function'].name)
  lu.assertNotNil(scheme['function'].parameters.properties.args)
end

function TestMake:testMakeSuccess()
  if vim.fn.executable('make') ~= 1 then
    print('Skipping testMakeSuccess: make not available')
    return
  end
  local temp_dir = make_temp_dir('success')
  set_allowed_path(temp_dir)
  vim.fn.writefile({ 'all:', '\t@echo hello-from-make' }, temp_dir .. '/Makefile')

  local result = call_async_tool('make', { target = 'all' }, { cwd = temp_dir }, 5000)
  lu.assertNotNil(result)
  lu.assertNotNil(result.content, 'Expected content, got error: ' .. (result.error or 'unknown'))
  lu.assertStrContains(result.content, 'hello-from-make')
  lu.assertEquals(0, result.exit_code)

  vim.fn.delete(temp_dir, 'rf')
end

function TestMake:testMakeFailure()
  if vim.fn.executable('make') ~= 1 then
    print('Skipping testMakeFailure: make not available')
    return
  end
  local temp_dir = make_temp_dir('failure')
  set_allowed_path(temp_dir)
  vim.fn.writefile({ 'fail:', '\texit 1' }, temp_dir .. '/Makefile')

  local result = call_async_tool('make', { target = 'fail' }, { cwd = temp_dir }, 5000)
  lu.assertNotNil(result)
  lu.assertNotNil(result.content, 'Expected content, got error: ' .. (result.error or 'unknown'))
  lu.assertNotEquals(0, result.exit_code)

  vim.fn.delete(temp_dir, 'rf')
end

function TestMake:testMakeArgsAsString()
  if vim.fn.executable('make') ~= 1 then
    print('Skipping testMakeArgsAsString: make not available')
    return
  end
  local temp_dir = make_temp_dir('args_str')
  set_allowed_path(temp_dir)
  vim.fn.writefile({ 'all:', '\t@echo ok' }, temp_dir .. '/Makefile')

  local result = call_async_tool('make', {
    target = 'all',
    args = '-s',
  }, { cwd = temp_dir }, 5000)
  lu.assertNotNil(result)
  lu.assertNotNil(result.content, 'Expected content, got error: ' .. (result.error or 'unknown'))

  vim.fn.delete(temp_dir, 'rf')
end

function TestMake:testMakeMtimeBlocked()
  if vim.fn.executable('make') ~= 1 then
    print('Skipping testMakeMtimeBlocked: make not available')
    return
  end
  local temp_dir = make_temp_dir('mtime')
  set_allowed_path(temp_dir)
  vim.fn.writefile({ 'all:', '\t@echo ok' }, temp_dir .. '/Makefile')

  storage.sessions['test_session'] = { last_user_message_time = 0 }

  local result = tools.call('make', {
    target = 'all',
  }, {
    cwd = temp_dir,
    session = 'test_session',
    callback = function() end,
  })
  lu.assertNotNil(result)
  lu.assertNotNil(result.error, 'Expected Makefile mtime to block execution')
  lu.assertStrContains(result.error, 'Makefile was modified')

  vim.fn.delete(temp_dir, 'rf')
end

return TestMake
