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
  name = name or 'git_push'
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
  vim.fn.system(
    'git -C "' .. temp_dir .. '" config user.email "test@test.com"'
  )
  vim.fn.system('git -C "' .. temp_dir .. '" config user.name "Test User"')
  return vim.fs.normalize(temp_dir)
end

-- Set allowed path directly
local function set_allowed_path(path)
  config.config.allowed_path = vim.fs.normalize(path)
end

TestGitPush = {}

function TestGitPush:setUp()
  -- Reset to project directory
  set_allowed_path(vim.fn.getcwd())
end

function TestGitPush:tearDown()
  -- Reset to project directory
  set_allowed_path(vim.fn.getcwd())
end

function TestGitPush:testGitPushAvailable()
  local available = tools.available_tools()
  local tool_names = {}
  for _, tool in ipairs(available) do
    tool_names[tool['function'].name] = true
  end
  lu.assertTrue(tool_names['git_push'], 'git_push tool should be available')
end

function TestGitPush:testGitPushSecurityOutsideAllowedPath()
  -- Create a temp git repo
  local temp_dir = create_temp_git_repo('security')

  -- allowed_path is set to project dir in setUp, so temp_dir should be outside
  local result = tools.call('git_push', {}, { cwd = temp_dir })

  lu.assertNotNil(result)
  lu.assertNotNil(result.error, 'Should reject path outside allowed_path')
  lu.assertStrContains(result.error, 'allowed')

  vim.fn.delete(temp_dir, 'rf')
end

function TestGitPush:testGitPushNoGitRepo()
  if vim.fn.executable('git') ~= 1 then
    print('Skipping testGitPushNoGitRepo: git not available')
    return
  end

  -- Create temp directory in cache (no git repo)
  local cache_dir = vim.fs.normalize(vim.fn.stdpath('cache'))
  local temp_dir = cache_dir
    .. '/test_no_git_push_'
    .. os.time()
    .. '_'
    .. math.random(10000, 99999)
  vim.fn.mkdir(temp_dir, 'p')

  -- Update allowed_path to include temp directory
  set_allowed_path(temp_dir)

  local result = call_async_tool('git_push', {}, { cwd = temp_dir }, 3000)

  lu.assertNotNil(result)
  lu.assertNotNil(
    result.error,
    'Should fail in non-git directory, got: '
      .. (result.content or 'no content')
  )
  lu.assertStrContains(result.error:lower(), 'git')

  vim.fn.delete(temp_dir, 'rf')
end

function TestGitPush:testGitPushNoRemote()
  if vim.fn.executable('git') ~= 1 then
    print('Skipping testGitPushNoRemote: git not available')
    return
  end

  local git_repo = create_temp_git_repo('no_remote')

  -- Update allowed_path to include the temp git repo
  set_allowed_path(git_repo)

  -- Create a commit
  local test_file = git_repo .. '/test.lua'
  vim.fn.writefile({ 'print("hello")' }, test_file)
  vim.fn.system('git -C "' .. git_repo .. '" add test.lua')
  vim.fn.system('git -C "' .. git_repo .. '" commit -m "initial commit"')

  -- Try to push without remote
  local result = call_async_tool('git_push', {}, { cwd = git_repo }, 5000)

  lu.assertNotNil(result)
  lu.assertNotNil(
    result.error,
    'Should fail without remote, got: ' .. (result.content or 'no content')
  )
  lu.assertStrContains(result.error:lower(), 'remote')

  vim.fn.delete(git_repo, 'rf')
end

function TestGitPush:testGitPushWithBranch()
  if vim.fn.executable('git') ~= 1 then
    print('Skipping testGitPushWithBranch: git not available')
    return
  end

  local git_repo = create_temp_git_repo('branch')

  -- Update allowed_path to include the temp git repo
  set_allowed_path(git_repo)

  -- Create a commit
  local test_file = git_repo .. '/test.lua'
  vim.fn.writefile({ 'print("hello")' }, test_file)
  vim.fn.system('git -C "' .. git_repo .. '" add test.lua')
  vim.fn.system('git -C "' .. git_repo .. '" commit -m "initial commit"')

  -- Add a fake remote (will fail to push but tests command construction)
  vim.fn.system(
    'git -C "'
      .. git_repo
      .. '" remote add origin https://example.com/test.git'
  )

  local result = call_async_tool('git_push', {
    branch = 'main',
  }, { cwd = git_repo }, 5000)

  lu.assertNotNil(result)
  -- Should fail with network error (no actual remote), but command construction is correct
  lu.assertNotNil(result.error, 'Should fail with network error')

  vim.fn.delete(git_repo, 'rf')
end

function TestGitPush:testGitPushInfo()
  local info = tools.info({
    ['function'] = {
      name = 'git_push',
      arguments = vim.json.encode({
        branch = 'main',
        remote = 'origin',
        force = true,
      }),
    },
  }, { cwd = vim.fn.getcwd() })

  lu.assertStrContains(info, 'git_push')
  lu.assertStrContains(info, 'branch="main"')
  lu.assertStrContains(info, 'remote="origin"')
  lu.assertStrContains(info, 'force=true')
end
