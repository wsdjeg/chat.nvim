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
  name = name or 'git_commit'
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

TestGitCommit = {}

function TestGitCommit:setUp()
  -- Reset to project directory
  set_allowed_path(vim.fn.getcwd())
end

function TestGitCommit:tearDown()
  -- Reset to project directory
  set_allowed_path(vim.fn.getcwd())
end

function TestGitCommit:testGitCommitAvailable()
  local available = tools.available_tools()
  local tool_names = {}
  for _, tool in ipairs(available) do
    tool_names[tool['function'].name] = true
  end
  lu.assertTrue(
    tool_names['git_commit'],
    'git_commit tool should be available'
  )
end

function TestGitCommit:testGitCommitNoMessage()
  local result = tools.call(
    'git_commit',
    {},
    { cwd = vim.fs.normalize(vim.fn.getcwd()) }
  )

  lu.assertNotNil(result)
  lu.assertNotNil(result.error, 'Should require commit message')
  lu.assertStrContains(result.error:lower(), 'message')
end

function TestGitCommit:testGitCommitEmptyMessage()
  local result = tools.call('git_commit', {
    message = '',
  }, { cwd = vim.fs.normalize(vim.fn.getcwd()) })

  lu.assertNotNil(result)
  lu.assertNotNil(result.error, 'Should reject empty commit message')
  lu.assertStrContains(result.error:lower(), 'message')
end

function TestGitCommit:testGitCommitSecurityOutsideAllowedPath()
  -- Create a temp git repo
  local temp_dir = create_temp_git_repo('security')

  -- allowed_path is set to project dir in setUp, so temp_dir should be outside
  local result = tools.call('git_commit', {
    message = 'test commit',
  }, { cwd = temp_dir })

  lu.assertNotNil(result)
  lu.assertNotNil(result.error, 'Should reject path outside allowed_path')
  lu.assertStrContains(result.error, 'allowed')

  vim.fn.delete(temp_dir, 'rf')
end

function TestGitCommit:testGitCommitNothingToCommit()
  if vim.fn.executable('git') ~= 1 then
    print('Skipping testGitCommitNothingToCommit: git not available')
    return
  end

  local git_repo = create_temp_git_repo('nothing')

  -- Update allowed_path to include the temp git repo
  set_allowed_path(git_repo)

  local result = call_async_tool('git_commit', {
    message = 'test commit',
  }, { cwd = git_repo }, 5000)

  lu.assertNotNil(result)
  lu.assertNotNil(
    result.error,
    'Should fail when nothing to commit, got: '
      .. (result.content or 'no content')
  )
  lu.assertStrContains(result.error:lower(), 'nothing')

  vim.fn.delete(git_repo, 'rf')
end

function TestGitCommit:testGitCommitWithStagedChanges()
  if vim.fn.executable('git') ~= 1 then
    print('Skipping testGitCommitWithStagedChanges: git not available')
    return
  end

  local git_repo = create_temp_git_repo('staged')

  -- Update allowed_path to include the temp git repo
  set_allowed_path(git_repo)

  local test_file = git_repo .. '/test.lua'
  vim.fn.writefile({ 'print("test")' }, test_file)
  vim.fn.system('git -C "' .. git_repo .. '" add ' .. test_file)

  local result = call_async_tool('git_commit', {
    message = 'Initial commit',
  }, { cwd = git_repo }, 5000)

  lu.assertNotNil(result)
  lu.assertNotNil(
    result.content,
    'Expected content, got error: ' .. (result.error or 'unknown')
  )
  lu.assertStrContains(result.content:lower(), 'success')
  lu.assertStrContains(result.content, 'Initial commit')

  vim.fn.delete(git_repo, 'rf')
end

function TestGitCommit:testGitCommitAllowEmpty()
  if vim.fn.executable('git') ~= 1 then
    print('Skipping testGitCommitAllowEmpty: git not available')
    return
  end

  local git_repo = create_temp_git_repo('empty')

  -- Update allowed_path to include the temp git repo
  set_allowed_path(git_repo)

  local result = call_async_tool('git_commit', {
    message = 'Empty commit',
    allow_empty = true,
  }, { cwd = git_repo }, 5000)

  lu.assertNotNil(result)
  lu.assertNotNil(
    result.content,
    'Expected content, got error: ' .. (result.error or 'unknown')
  )
  lu.assertStrContains(result.content:lower(), 'success')

  vim.fn.delete(git_repo, 'rf')
end

function TestGitCommit:testGitCommitAmend()
  if vim.fn.executable('git') ~= 1 then
    print('Skipping testGitCommitAmend: git not available')
    return
  end

  local git_repo = create_temp_git_repo('amend')

  -- Update allowed_path to include the temp git repo
  set_allowed_path(git_repo)

  local test_file = git_repo .. '/test.lua'
  vim.fn.writefile({ 'print("test")' }, test_file)
  vim.fn.system('git -C "' .. git_repo .. '" add ' .. test_file)
  vim.fn.system('git -C "' .. git_repo .. '" commit -m "Initial commit"')

  local result = call_async_tool('git_commit', {
    message = 'Amended commit',
    amend = true,
  }, { cwd = git_repo }, 5000)

  lu.assertNotNil(result)
  lu.assertNotNil(
    result.content,
    'Expected content, got error: ' .. (result.error or 'unknown')
  )
  lu.assertStrContains(result.content:lower(), 'success')

  vim.fn.delete(git_repo, 'rf')
end
