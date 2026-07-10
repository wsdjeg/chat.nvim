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
  name = name or 'git_rebase'
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

-- Set allowed path directly
local function set_allowed_path(path)
  config.config.allowed_path = vim.fs.normalize(path)
end

TestGitRebase = {}

function TestGitRebase:setUp()
  set_allowed_path(vim.fn.getcwd())
end

function TestGitRebase:tearDown()
  set_allowed_path(vim.fn.getcwd())
end

function TestGitRebase:testGitRebaseAvailable()
  local available = tools.available_tools()
  local tool_names = {}
  for _, tool in ipairs(available) do
    tool_names[tool['function'].name] = true
  end
  lu.assertTrue(
    tool_names['git_rebase'],
    'git_rebase tool should be available'
  )
end

function TestGitRebase:testGitRebaseSecurityOutsideAllowedPath()
  local temp_dir = create_temp_git_repo('security')

  local result = tools.call('git_rebase', {
    branch = 'feature',
  }, { cwd = temp_dir })

  lu.assertNotNil(result)
  lu.assertNotNil(result.error, 'Should reject path outside allowed_path')
  lu.assertStrContains(result.error, 'allowed')

  vim.fn.delete(temp_dir, 'rf')
end

function TestGitRebase:testGitRebaseOntoBranch()
  if vim.fn.executable('git') ~= 1 then
    print('Skipping testGitRebaseOntoBranch: git not available')
    return
  end

  local git_repo = create_temp_git_repo('onto')
  set_allowed_path(git_repo)

  local test_file = git_repo .. '/test.lua'
  vim.fn.writefile({ 'print("main")' }, test_file)
  vim.fn.system('git -C "' .. git_repo .. '" add ' .. test_file)
  vim.fn.system('git -C "' .. git_repo .. '" commit -m "Initial commit"')

  -- Create feature branch with a commit
  vim.fn.system('git -C "' .. git_repo .. '" checkout -b feature')
  vim.fn.writefile({ 'print("feature")' }, test_file)
  vim.fn.system('git -C "' .. git_repo .. '" add ' .. test_file)
  vim.fn.system('git -C "' .. git_repo .. '" commit -m "Feature commit"')

  -- Go back to master and add a commit
  vim.fn.system('git -C "' .. git_repo .. '" checkout master')
  local other_file = git_repo .. '/other.lua'
  vim.fn.writefile({ 'print("other")' }, other_file)
  vim.fn.system('git -C "' .. git_repo .. '" add ' .. other_file)
  vim.fn.system('git -C "' .. git_repo .. '" commit -m "Other commit"')

  -- Rebase feature onto master
  vim.fn.system('git -C "' .. git_repo .. '" checkout feature')

  local result = call_async_tool('git_rebase', {
    branch = 'master',
  }, { cwd = git_repo }, 5000)

  lu.assertNotNil(result)
  lu.assertNotNil(
    result.content,
    'Expected content, got error: ' .. (result.error or 'unknown')
  )
  lu.assertStrContains(result.content:lower(), 'success')

  -- Verify linear history: feature commit should be after other commit
  local log = vim.fn.system('git -C "' .. git_repo .. '" log --oneline')
  lu.assertStrContains(log, 'Feature commit')
  lu.assertStrContains(log, 'Other commit')

  vim.fn.delete(git_repo, 'rf')
end

function TestGitRebaseAbort()
  if vim.fn.executable('git') ~= 1 then
    print('Skipping testGitRebaseAbort: git not available')
    return
  end

  local git_repo = create_temp_git_repo('abort')
  set_allowed_path(git_repo)

  local test_file = git_repo .. '/test.lua'
  vim.fn.writefile({ 'print("main")' }, test_file)
  vim.fn.system('git -C "' .. git_repo .. '" add ' .. test_file)
  vim.fn.system('git -C "' .. git_repo .. '" commit -m "Initial commit"')

  -- Create feature branch with conflicting commit
  vim.fn.system('git -C "' .. git_repo .. '" checkout -b feature')
  vim.fn.writefile({ 'print("feature")' }, test_file)
  vim.fn.system('git -C "' .. git_repo .. '" add ' .. test_file)
  vim.fn.system('git -C "' .. git_repo .. '" commit -m "Feature commit"')

  -- Go back to master and add conflicting commit
  vim.fn.system('git -C "' .. git_repo .. '" checkout master')
  vim.fn.writefile({ 'print("main conflict")' }, test_file)
  vim.fn.system('git -C "' .. git_repo .. '" add ' .. test_file)
  vim.fn.system('git -C "' .. git_repo .. '" commit -m "Main commit"')

  -- Start rebase which will conflict
  vim.fn.system('git -C "' .. git_repo .. '" checkout feature')
  vim.fn.system('git -C "' .. git_repo .. '" rebase master', true)

  -- Abort the rebase
  local result = call_async_tool('git_rebase', {
    abort = true,
  }, { cwd = git_repo }, 5000)

  lu.assertNotNil(result)
  lu.assertNotNil(
    result.content,
    'Expected content, got error: ' .. (result.error or 'unknown')
  )
  lu.assertStrContains(result.content:lower(), 'success')

  -- Verify no rebase in progress
  local status =
    vim.fn.system('git -C "' .. git_repo .. '" status --porcelain')
  lu.assertNotStrContains(status, 'rebase')

  vim.fn.delete(git_repo, 'rf')
end

function TestGitRebaseContinue()
  if vim.fn.executable('git') ~= 1 then
    print('Skipping testGitRebaseContinue: git not available')
    return
  end

  local git_repo = create_temp_git_repo('continue')
  set_allowed_path(git_repo)

  local test_file = git_repo .. '/test.lua'
  vim.fn.writefile({ 'print("main")' }, test_file)
  vim.fn.system('git -C "' .. git_repo .. '" add ' .. test_file)
  vim.fn.system('git -C "' .. git_repo .. '" commit -m "Initial commit"')

  -- Create feature branch with conflicting commit
  vim.fn.system('git -C "' .. git_repo .. '" checkout -b feature')
  vim.fn.writefile({ 'print("feature")' }, test_file)
  vim.fn.system('git -C "' .. git_repo .. '" add ' .. test_file)
  vim.fn.system('git -C "' .. git_repo .. '" commit -m "Feature commit"')

  -- Go back to master and add conflicting commit
  vim.fn.system('git -C "' .. git_repo .. '" checkout master')
  vim.fn.writefile({ 'print("main conflict")' }, test_file)
  vim.fn.system('git -C "' .. git_repo .. '" add ' .. test_file)
  vim.fn.system('git -C "' .. git_repo .. '" commit -m "Main commit"')

  -- Start rebase which will conflict
  vim.fn.system('git -C "' .. git_repo .. '" checkout feature')
  vim.fn.system('git -C "' .. git_repo .. '" rebase master', true)

  -- Resolve conflict
  vim.fn.writefile({ 'print("resolved")' }, test_file)
  vim.fn.system('git -C "' .. git_repo .. '" add ' .. test_file)

  -- Continue the rebase
  local result = call_async_tool('git_rebase', {
    continue = true,
  }, { cwd = git_repo }, 5000)

  lu.assertNotNil(result)
  lu.assertNotNil(
    result.content,
    'Expected content, got error: ' .. (result.error or 'unknown')
  )
  lu.assertStrContains(result.content:lower(), 'success')

  -- Verify rebase completed: log should have both commits
  local log = vim.fn.system('git -C "' .. git_repo .. '" log --oneline')
  lu.assertStrContains(log, 'Feature commit')
  lu.assertStrContains(log, 'Main commit')

  vim.fn.delete(git_repo, 'rf')
end

function TestGitRebaseSkip()
  if vim.fn.executable('git') ~= 1 then
    print('Skipping testGitRebaseSkip: git not available')
    return
  end

  local git_repo = create_temp_git_repo('skip')
  set_allowed_path(git_repo)

  local test_file = git_repo .. '/test.lua'
  vim.fn.writefile({ 'print("main")' }, test_file)
  vim.fn.system('git -C "' .. git_repo .. '" add ' .. test_file)
  vim.fn.system('git -C "' .. git_repo .. '" commit -m "Initial commit"')

  -- Create feature branch with conflicting commit
  vim.fn.system('git -C "' .. git_repo .. '" checkout -b feature')
  vim.fn.writefile({ 'print("feature")' }, test_file)
  vim.fn.system('git -C "' .. git_repo .. '" add ' .. test_file)
  vim.fn.system('git -C "' .. git_repo .. '" commit -m "Feature commit"')

  -- Go back to master and add conflicting commit
  vim.fn.system('git -C "' .. git_repo .. '" checkout master')
  vim.fn.writefile({ 'print("main conflict")' }, test_file)
  vim.fn.system('git -C "' .. git_repo .. '" add ' .. test_file)
  vim.fn.system('git -C "' .. git_repo .. '" commit -m "Main commit"')

  -- Start rebase which will conflict
  vim.fn.system('git -C "' .. git_repo .. '" checkout feature')
  vim.fn.system('git -C "' .. git_repo .. '" rebase master', true)

  -- Skip the conflicting commit
  local result = call_async_tool('git_rebase', {
    skip = true,
  }, { cwd = git_repo }, 5000)

  lu.assertNotNil(result)
  lu.assertNotNil(
    result.content,
    'Expected content, got error: ' .. (result.error or 'unknown')
  )
  lu.assertStrContains(result.content:lower(), 'success')

  -- Verify rebase completed: feature commit should be skipped
  local log = vim.fn.system('git -C "' .. git_repo .. '" log --oneline')
  lu.assertStrContains(log, 'Main commit')

  vim.fn.delete(git_repo, 'rf')
end

function TestGitRebaseNoBranch()
  if vim.fn.executable('git') ~= 1 then
    print('Skipping testGitRebaseNoBranch: git not available')
    return
  end

  local git_repo = create_temp_git_repo('no-branch')
  set_allowed_path(git_repo)

  local test_file = git_repo .. '/test.lua'
  vim.fn.writefile({ 'print("main")' }, test_file)
  vim.fn.system('git -C "' .. git_repo .. '" add ' .. test_file)
  vim.fn.system('git -C "' .. git_repo .. '" commit -m "Initial commit"')

  local result = tools.call('git_rebase', {}, { cwd = git_repo })

  lu.assertNotNil(result)
  lu.assertNotNil(result.error, 'Should require branch or abort/continue/skip')
  lu.assertStrContains(result.error:lower(), 'branch')

  vim.fn.delete(git_repo, 'rf')
end

