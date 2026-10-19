local lu = require('luaunit')
local tools = require('chat.tools')
local config = require('chat.config')
local git_remote = require('chat.tools.git_remote')

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

local function create_temp_git_repo(name)
  name = name or 'git_remote'
  local cache_dir = vim.fs.normalize(vim.fn.stdpath('data'))
  local temp_dir = cache_dir
    .. '/test_'
    .. name
    .. '_'
    .. os.time()
    .. '_'
    .. math.random(10000, 99999)
  vim.fn.mkdir(temp_dir, 'p')
  vim.fn.system('git -C "' .. temp_dir .. '" init')
  vim.fn.system(
    'git -C "' .. temp_dir .. '" config user.email "test@test.com"'
  )
  vim.fn.system('git -C "' .. temp_dir .. '" config user.name "Test User"')
  return vim.fs.normalize(temp_dir)
end

local function set_allowed_path(path)
  config.config.allowed_path = vim.fs.normalize(path)
end

TestGitRemote = {}

function TestGitRemote:setUp()
  set_allowed_path(vim.fn.getcwd())
end

function TestGitRemote:tearDown()
  set_allowed_path(vim.fn.getcwd())
end

function TestGitRemote:testGitRemoteAvailable()
  local available = tools.available_tools()
  local tool_names = {}
  for _, tool in ipairs(available) do
    tool_names[tool['function'].name] = true
  end
  lu.assertTrue(tool_names['git_remote'], 'git_remote tool should be available')
end

function TestGitRemote:testGitRemoteSecurityOutsideAllowedPath()
  local temp_dir = create_temp_git_repo('security')
  local result = tools.call('git_remote', { action = 'list' }, { cwd = temp_dir })
  lu.assertNotNil(result)
  lu.assertNotNil(result.error, 'Should reject path outside allowed_path')
  lu.assertStrContains(result.error, 'allowed')
  vim.fn.delete(temp_dir, 'rf')
end

function TestGitRemote:testGitRemoteGetUrlMissingName()
  local result = tools.call('git_remote', {
    action = 'get-url',
  }, { cwd = vim.fn.getcwd() })
  lu.assertNotNil(result)
  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'Remote name is required')
end

function TestGitRemote:testGitRemoteUnknownAction()
  local result = tools.call('git_remote', {
    action = 'bogus',
  }, { cwd = vim.fn.getcwd() })
  lu.assertNotNil(result)
  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'Unknown action')
end

function TestGitRemote:testInfoDefault()
  local info = git_remote.info('not json', { cwd = vim.fn.getcwd() })
  lu.assertEquals('git_remote', info)
end

function TestGitRemote:testInfoAction()
  local info = git_remote.info(
    vim.json.encode({ action = 'get-url', name = 'origin', push = true }),
    { cwd = vim.fn.getcwd() }
  )
  lu.assertStrContains(info, 'action="get-url"')
  lu.assertStrContains(info, 'name="origin"')
  lu.assertStrContains(info, 'push=true')
end

function TestGitRemote:testInfoDefaultList()
  local info = git_remote.info(
    vim.json.encode({}),
    { cwd = vim.fn.getcwd() }
  )
  lu.assertStrContains(info, 'action="list"')
end

function TestGitRemote:testScheme()
  local scheme = git_remote.scheme()
  lu.assertEquals('function', scheme.type)
  lu.assertEquals('git_remote', scheme['function'].name)
  lu.assertNotNil(scheme['function'].parameters.properties.action)
end

function TestGitRemote:testGitRemoteList()
  if vim.fn.executable('git') ~= 1 then
    print('Skipping testGitRemoteList: git not available')
    return
  end
  local git_repo = create_temp_git_repo('list')
  set_allowed_path(git_repo)
  vim.fn.system('git -C "' .. git_repo .. '" remote add origin https://example.com/repo.git')

  local result = call_async_tool('git_remote', { action = 'list' }, { cwd = git_repo }, 3000)
  lu.assertNotNil(result)
  lu.assertNotNil(result.content, 'Expected content, got error: ' .. (result.error or 'unknown'))
  lu.assertStrContains(result.content, 'origin')

  vim.fn.delete(git_repo, 'rf')
end

function TestGitRemote:testGitRemoteGetUrl()
  if vim.fn.executable('git') ~= 1 then
    print('Skipping testGitRemoteGetUrl: git not available')
    return
  end
  local git_repo = create_temp_git_repo('get_url')
  set_allowed_path(git_repo)
  vim.fn.system('git -C "' .. git_repo .. '" remote add origin https://example.com/repo.git')

  local result = call_async_tool('git_remote', {
    action = 'get-url',
    name = 'origin',
  }, { cwd = git_repo }, 3000)
  lu.assertNotNil(result)
  lu.assertNotNil(result.content, 'Expected content, got error: ' .. (result.error or 'unknown'))
  lu.assertStrContains(result.content, 'https://example.com/repo.git')

  vim.fn.delete(git_repo, 'rf')
end

function TestGitRemote:testGitRemoteGetUrlFails()
  if vim.fn.executable('git') ~= 1 then
    print('Skipping testGitRemoteGetUrlFails: git not available')
    return
  end
  local git_repo = create_temp_git_repo('get_url_fail')
  set_allowed_path(git_repo)

  local result = call_async_tool('git_remote', {
    action = 'get-url',
    name = 'nonexistent',
  }, { cwd = git_repo }, 3000)
  lu.assertNotNil(result)
  lu.assertNotNil(result.error, 'Expected error for nonexistent remote')

  vim.fn.delete(git_repo, 'rf')
end

return TestGitRemote
