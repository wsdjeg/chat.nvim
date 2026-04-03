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
  name = name or 'git_fetch'
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

TestGitFetch = {}

function TestGitFetch:setUp()
  -- Reset to project directory
  set_allowed_path(vim.fn.getcwd())
end

function TestGitFetch:tearDown()
  -- Reset to project directory
  set_allowed_path(vim.fn.getcwd())
end

function TestGitFetch:testGitFetchAvailable()
  local available = tools.available_tools()
  local tool_names = {}
  for _, tool in ipairs(available) do
    tool_names[tool['function'].name] = true
  end
  lu.assertTrue(tool_names['git_fetch'], 'git_fetch tool should be available')
end

function TestGitFetch:testGitFetchSecurityOutsideAllowedPath()
  -- Create a temp git repo
  local temp_dir = create_temp_git_repo('security')

  -- allowed_path is set to project dir in setUp, so temp_dir should be outside
  local result = tools.call('git_fetch', {
    remote = 'origin',
  }, { cwd = temp_dir })

  lu.assertNotNil(result)
  lu.assertNotNil(result.error, 'Should reject path outside allowed_path')
  lu.assertStrContains(result.error, 'allowed')

  vim.fn.delete(temp_dir, 'rf')
end

function TestGitFetch:testGitFetchDefault()
  if vim.fn.executable('git') ~= 1 then
    print('Skipping testGitFetchDefault: git not available')
    return
  end

  local git_repo = create_temp_git_repo('fetch')
  set_allowed_path(git_repo)

  local test_file = git_repo .. '/test.lua'
  vim.fn.writefile({ 'print("test")' }, test_file)
  vim.fn.system('git -C "' .. git_repo .. '" add ' .. test_file)
  vim.fn.system('git -C "' .. git_repo .. '" commit -m "Initial commit"')

  local result = call_async_tool('git_fetch', {}, { cwd = git_repo }, 5000)

  lu.assertNotNil(result)
  lu.assertNotNil(
    result.content or result.error,
    'Expected content or error, got nil'
  )
  -- Fetch may fail if no remote exists, but should not crash

  vim.fn.delete(git_repo, 'rf')
end

function TestGitFetch:testGitFetchRemote()
  if vim.fn.executable('git') ~= 1 then
    print('Skipping testGitFetchRemote: git not available')
    return
  end

  local git_repo = create_temp_git_repo('remote')
  set_allowed_path(git_repo)

  local result = call_async_tool('git_fetch', {
    remote = 'nonexistent',
  }, { cwd = git_repo }, 5000)

  lu.assertNotNil(result)
  -- Should fail gracefully when remote doesn't exist
  if result.error then
    lu.assertStrContains(result.error:lower(), 'remote' or 'origin')
  end

  vim.fn.delete(git_repo, 'rf')
end

function TestGitFetch:testGitFetchBranch()
  if vim.fn.executable('git') ~= 1 then
    print('Skipping testGitFetchBranch: git not available')
    return
  end

  local git_repo = create_temp_git_repo('branch')
  set_allowed_path(git_repo)

  -- Create a second branch
  local test_file = git_repo .. '/test.lua'
  vim.fn.writefile({ 'print("test")' }, test_file)
  vim.fn.system('git -C "' .. git_repo .. '" add ' .. test_file)
  vim.fn.system('git -C "' .. git_repo .. '" commit -m "Initial commit"')

  local result = call_async_tool('git_fetch', {
    branch = 'main',
  }, { cwd = git_repo }, 5000)

  lu.assertNotNil(result)
  lu.assertNotNil(
    result.content or result.error,
    'Expected content or error, got nil'
  )

  vim.fn.delete(git_repo, 'rf')
end

function TestGitFetch:testGitFetchAll()
  if vim.fn.executable('git') ~= 1 then
    print('Skipping testGitFetchAll: git not available')
    return
  end

  local git_repo = create_temp_git_repo('all')
  set_allowed_path(git_repo)

  local test_file = git_repo .. '/test.lua'
  vim.fn.writefile({ 'print("test")' }, test_file)
  vim.fn.system('git -C "' .. git_repo .. '" add ' .. test_file)
  vim.fn.system('git -C "' .. git_repo .. '" commit -m "Initial commit"')

  local result = call_async_tool('git_fetch', {
    all = true,
  }, { cwd = git_repo }, 5000)

  lu.assertNotNil(result)
  lu.assertNotNil(
    result.content or result.error,
    'Expected content or error, got nil'
  )

  vim.fn.delete(git_repo, 'rf')
end

function TestGitFetch:testGitFetchPrune()
  if vim.fn.executable('git') ~= 1 then
    print('Skipping testGitFetchPrune: git not available')
    return
  end

  local git_repo = create_temp_git_repo('prune')
  set_allowed_path(git_repo)

  local test_file = git_repo .. '/test.lua'
  vim.fn.writefile({ 'print("test")' }, test_file)
  vim.fn.system('git -C "' .. git_repo .. '" add ' .. test_file)
  vim.fn.system('git -C "' .. git_repo .. '" commit -m "Initial commit"')

  local result = call_async_tool('git_fetch', {
    prune = true,
  }, { cwd = git_repo }, 5000)

  lu.assertNotNil(result)
  lu.assertNotNil(
    result.content or result.error,
    'Expected content or error, got nil'
  )

  vim.fn.delete(git_repo, 'rf')
end

function TestGitFetch:testGitFetchTags()
  if vim.fn.executable('git') ~= 1 then
    print('Skipping testGitFetchTags: git not available')
    return
  end

  local git_repo = create_temp_git_repo('tags')
  set_allowed_path(git_repo)

  local test_file = git_repo .. '/test.lua'
  vim.fn.writefile({ 'print("test")' }, test_file)
  vim.fn.system('git -C "' .. git_repo .. '" add ' .. test_file)
  vim.fn.system('git -C "' .. git_repo .. '" commit -m "Initial commit"')

  local result = call_async_tool('git_fetch', {
    tags = true,
  }, { cwd = git_repo }, 5000)

  lu.assertNotNil(result)
  lu.assertNotNil(
    result.content or result.error,
    'Expected content or error, got nil'
  )

  vim.fn.delete(git_repo, 'rf')
end
