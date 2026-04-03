local lu = require('luaunit')
local tools = require('chat.tools')
local config = require('chat.config')

-- Helper function to test async tools
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

-- Create a temporary git repo in cache directory
local function create_temp_git_repo(name)
  name = name or 'git_config'
  local cache_dir = vim.fs.normalize(vim.fn.stdpath('cache'))
  local temp_dir = cache_dir
    .. '/test_'
    .. name
    .. '_'
    .. os.time()
    .. '_'
    .. math.random(10000, 99999)
  vim.fn.mkdir(temp_dir, 'p')
  vim.fn.system('git -C "' .. temp_dir .. '" init')
  return vim.fs.normalize(temp_dir)
end

-- Set allowed path directly
local function set_allowed_path(path)
  config.config.allowed_path = vim.fs.normalize(path)
end

TestGitConfig = {}

function TestGitConfig:setUp()
  -- Reset to project directory
  set_allowed_path(vim.fn.getcwd())
end

function TestGitConfig:tearDown()
  -- Reset to project directory
  set_allowed_path(vim.fn.getcwd())
end

function TestGitConfig:testGitConfigAvailable()
  local available = tools.available_tools()
  local tool_names = {}
  for _, tool in ipairs(available) do
    tool_names[tool['function'].name] = true
  end
  lu.assertTrue(tool_names['git_config'], 'git_config tool should be available')
end

function TestGitConfig:testGitConfigSecurityOutsideAllowedPath()
  -- Create a temp git repo
  local temp_dir = create_temp_git_repo('security')

  -- allowed_path is set to project dir in setUp, so temp_dir should be outside
  local result = tools.call('git_config', {
    action = 'get',
    key = 'user.name',
  }, { cwd = temp_dir })

  lu.assertNotNil(result)
  lu.assertNotNil(result.error, 'Should reject path outside allowed_path')
  lu.assertStrContains(result.error, 'allowed')

  vim.fn.delete(temp_dir, 'rf')
end

function TestGitConfig:testGitConfigGet()
  if vim.fn.executable('git') ~= 1 then
    print('Skipping testGitConfigGet: git not available')
    return
  end

  local git_repo = create_temp_git_repo('get')
  set_allowed_path(git_repo)

  vim.fn.system('git -C "' .. git_repo .. '" config user.email "test@example.com"')
  vim.fn.system('git -C "' .. git_repo .. '" config user.name "Test User"')

  local result = call_async_tool('git_config', {
    action = 'get',
    key = 'user.email',
  }, { cwd = git_repo }, 3000)

  lu.assertNotNil(result)
  lu.assertNotNil(
    result.content,
    'Expected content, got error: ' .. (result.error or 'unknown')
  )
  lu.assertStrContains(result.content, 'test@example.com')

  vim.fn.delete(git_repo, 'rf')
end

function TestGitConfig:testGitConfigSet()
  if vim.fn.executable('git') ~= 1 then
    print('Skipping testGitConfigSet: git not available')
    return
  end

  local git_repo = create_temp_git_repo('set')
  set_allowed_path(git_repo)

  local result = call_async_tool('git_config', {
    action = 'set',
    key = 'user.name',
    value = 'Git Test User',
  }, { cwd = git_repo }, 5000)

  lu.assertNotNil(result)
  lu.assertNotNil(
    result.content,
    'Expected content, got error: ' .. (result.error or 'unknown')
  )
  lu.assertStrContains(result.content:lower(), 'success')

  local value = vim.fn.system('git -C "' .. git_repo .. '" config user.name')
  lu.assertStrContains(value, 'Git Test User')

  vim.fn.delete(git_repo, 'rf')
end

function TestGitConfig:testGitConfigList()
  if vim.fn.executable('git') ~= 1 then
    print('Skipping testGitConfigList: git not available')
    return
  end

  local git_repo = create_temp_git_repo('list')
  set_allowed_path(git_repo)

  vim.fn.system('git -C "' .. git_repo .. '" config user.email "list@test.com"')
  vim.fn.system('git -C "' .. git_repo .. '" config user.name "List User"')

  local result = call_async_tool('git_config', {
    action = 'list',
  }, { cwd = git_repo }, 5000)

  lu.assertNotNil(result)
  lu.assertNotNil(
    result.content,
    'Expected content, got error: ' .. (result.error or 'unknown')
  )
  lu.assertStrContains(result.content, 'user.email')
  lu.assertStrContains(result.content, 'user.name')

  vim.fn.delete(git_repo, 'rf')
end

function TestGitConfig:testGitConfigListGlobal()
  if vim.fn.executable('git') ~= 1 then
    print('Skipping testGitConfigListGlobal: git not available')
    return
  end

  local git_repo = create_temp_git_repo('list_global')
  set_allowed_path(git_repo)

  local result = call_async_tool('git_config', {
    action = 'list',
    global = true,
  }, { cwd = git_repo }, 5000)

  lu.assertNotNil(result)
  lu.assertNotNil(
    result.content,
    'Expected content, got error: ' .. (result.error or 'unknown')
  )

  vim.fn.delete(git_repo, 'rf')
end

function TestGitConfig:testGitConfigUnset()
  if vim.fn.executable('git') ~= 1 then
    print('Skipping testGitConfigUnset: git not available')
    return
  end

  local git_repo = create_temp_git_repo('unset')
  set_allowed_path(git_repo)

  vim.fn.system('git -C "' .. git_repo .. '" config user.name "Test User"')

  local result = call_async_tool('git_config', {
    action = 'unset',
    key = 'user.name',
  }, { cwd = git_repo }, 5000)

  lu.assertNotNil(result)
  lu.assertNotNil(
    result.content,
    'Expected content, got error: ' .. (result.error or 'unknown')
  )
  lu.assertStrContains(result.content:lower(), 'success')

  local result_check = call_async_tool('git_config', {
    action = 'get',
    key = 'user.name',
  }, { cwd = git_repo }, 3000)

  lu.assertTrue(result_check.error ~= nil or result_check.content == '')

  vim.fn.delete(git_repo, 'rf')
end

function TestGitConfig:testGitConfigFile()
  if vim.fn.executable('git') ~= 1 then
    print('Skipping testGitConfigFile: git not available')
    return
  end

  local git_repo = create_temp_git_repo('file')
  set_allowed_path(git_repo)

  local config_file = git_repo .. '/custom.config'
  vim.fn.writefile({ '[user]', '\tname = Custom User' }, config_file)

  local result = call_async_tool('git_config', {
    action = 'list',
    file = config_file,
  }, { cwd = git_repo }, 5000)

  lu.assertNotNil(result)
  lu.assertNotNil(
    result.content,
    'Expected content, got error: ' .. (result.error or 'unknown')
  )
  lu.assertStrContains(result.content, 'user.name')

  vim.fn.delete(git_repo, 'rf')
end
