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
  name = name or 'git_merge'
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

TestGitMerge = {}

function TestGitMerge:setUp()
  -- Reset to project directory
  set_allowed_path(vim.fn.getcwd())
end

function TestGitMerge:tearDown()
  -- Reset to project directory
  set_allowed_path(vim.fn.getcwd())
end

function TestGitMerge:testGitMergeAvailable()
  local available = tools.available_tools()
  local tool_names = {}
  for _, tool in ipairs(available) do
    tool_names[tool['function'].name] = true
  end
  lu.assertTrue(tool_names['git_merge'], 'git_merge tool should be available')
end

function TestGitMerge:testGitMergeSecurityOutsideAllowedPath()
  -- Create a temp git repo
  local temp_dir = create_temp_git_repo('security')

  -- allowed_path is set to project dir in setUp, so temp_dir should be outside
  local result = tools.call('git_merge', {
    branch = 'feature',
  }, { cwd = temp_dir })

  lu.assertNotNil(result)
  lu.assertNotNil(result.error, 'Should reject path outside allowed_path')
  lu.assertStrContains(result.error, 'allowed')

  vim.fn.delete(temp_dir, 'rf')
end

function TestGitMerge:testGitMergeFastForward()
  if vim.fn.executable('git') ~= 1 then
    print('Skipping testGitMergeFastForward: git not available')
    return
  end

  local git_repo = create_temp_git_repo('ff')
  set_allowed_path(git_repo)

  local test_file = git_repo .. '/test.lua'
  vim.fn.writefile({ 'print("main")' }, test_file)
  vim.fn.system('git -C "' .. git_repo .. '" add ' .. test_file)
  vim.fn.system('git -C "' .. git_repo .. '" commit -m "Initial commit"')

  vim.fn.system('git -C "' .. git_repo .. '" checkout -b feature')
  vim.fn.writefile({ 'print("feature")' }, test_file)
  vim.fn.system('git -C "' .. git_repo .. '" add ' .. test_file)
  vim.fn.system('git -C "' .. git_repo .. '" commit -m "Feature commit"')

  vim.fn.system('git -C "' .. git_repo .. '" checkout main')

  local result = call_async_tool('git_merge', {
    branch = 'feature',
  }, { cwd = git_repo }, 5000)

  lu.assertNotNil(result)
  lu.assertNotNil(
    result.content,
    'Expected content, got error: ' .. (result.error or 'unknown')
  )
  lu.assertStrContains(result.content:lower(), 'success')

  local branches = vim.fn.system('git -C "' .. git_repo .. '" branch --merged')
  lu.assertStrContains(branches, 'feature')

  vim.fn.delete(git_repo, 'rf')
end

function TestGitMerge:testGitMergeNoFastForward()
  if vim.fn.executable('git') ~= 1 then
    print('Skipping testGitMergeNoFastForward: git not available')
    return
  end

  local git_repo = create_temp_git_repo('no-ff')
  set_allowed_path(git_repo)

  local test_file = git_repo .. '/test.lua'
  vim.fn.writefile({ 'print("main")' }, test_file)
  vim.fn.system('git -C "' .. git_repo .. '" add ' .. test_file)
  vim.fn.system('git -C "' .. git_repo .. '" commit -m "Initial commit"')

  vim.fn.system('git -C "' .. git_repo .. '" checkout -b feature')
  vim.fn.writefile({ 'print("feature line")' }, test_file)
  vim.fn.system('git -C "' .. git_repo .. '" add ' .. test_file)
  vim.fn.system('git -C "' .. git_repo .. '" commit -m "Feature commit"')

  vim.fn.system('git -C "' .. git_repo .. '" checkout main')
  vim.fn.writefile({ 'print("main line")' }, test_file)
  vim.fn.system('git -C "' .. git_repo .. '" add ' .. test_file)
  vim.fn.system('git -C "' .. git_repo .. '" commit -m "Main commit"')

  local result = call_async_tool('git_merge', {
    branch = 'feature',
  }, { cwd = git_repo }, 5000)

  lu.assertNotNil(result)
  lu.assertNotNil(
    result.content,
    'Expected content, got error: ' .. (result.error or 'unknown')
  )
  lu.assertStrContains(result.content:lower(), 'success')

  local log = vim.fn.system('git -C "' .. git_repo .. '" log --oneline')
  lu.assertStrContains(log, 'Merge')
  lu.assertStrContains(log, 'Feature commit')
  lu.assertStrContains(log, 'Main commit')

  vim.fn.delete(git_repo, 'rf')
end

function TestGitMerge:testGitMergeNoFastForwardOption()
  if vim.fn.executable('git') ~= 1 then
    print('Skipping testGitMergeNoFastForwardOption: git not available')
    return
  end

  local git_repo = create_temp_git_repo('no-ff-option')
  set_allowed_path(git_repo)

  local test_file = git_repo .. '/test.lua'
  vim.fn.writefile({ 'print("main")' }, test_file)
  vim.fn.system('git -C "' .. git_repo .. '" add ' .. test_file)
  vim.fn.system('git -C "' .. git_repo .. '" commit -m "Initial commit"')

  vim.fn.system('git -C "' .. git_repo .. '" checkout -b feature')
  vim.fn.writefile({ 'print("feature line")' }, test_file)
  vim.fn.system('git -C "' .. git_repo .. '" add ' .. test_file)
  vim.fn.system('git -C "' .. git_repo .. '" commit -m "Feature commit"')

  vim.fn.system('git -C "' .. git_repo .. '" checkout main')

  local result = call_async_tool('git_merge', {
    branch = 'feature',
    no_ff = true,
  }, { cwd = git_repo }, 5000)

  lu.assertNotNil(result)
  lu.assertNotNil(
    result.content,
    'Expected content, got error: ' .. (result.error or 'unknown')
  )
  lu.assertStrContains(result.content:lower(), 'success')

  local log = vim.fn.system('git -C "' .. git_repo .. '" log --oneline')
  lu.assertStrContains(log, 'Merge')

  vim.fn.delete(git_repo, 'rf')
end

function TestGitMerge:testGitMergeFastForwardOnly()
  if vim.fn.executable('git') ~= 1 then
    print('Skipping testGitMergeFastForwardOnly: git not available')
    return
  end

  local git_repo = create_temp_git_repo('ff-only')
  set_allowed_path(git_repo)

  local test_file = git_repo .. '/test.lua'
  vim.fn.writefile({ 'print("main")' }, test_file)
  vim.fn.system('git -C "' .. git_repo .. '" add ' .. test_file)
  vim.fn.system('git -C "' .. git_repo .. '" commit -m "Initial commit"')

  vim.fn.system('git -C "' .. git_repo .. '" checkout -b feature')
  vim.fn.writefile({ 'print("feature line")' }, test_file)
  vim.fn.system('git -C "' .. git_repo .. '" add ' .. test_file)
  vim.fn.system('git -C "' .. git_repo .. '" commit -m "Feature commit"')

  vim.fn.system('git -C "' .. git_repo .. '" checkout main')
  vim.fn.writefile({ 'print("main line")' }, test_file)
  vim.fn.system('git -C "' .. git_repo .. '" add ' .. test_file)
  vim.fn.system('git -C "' .. git_repo .. '" commit -m "Main commit"')

  local result = call_async_tool('git_merge', {
    branch = 'feature',
    ff_only = true,
  }, { cwd = git_repo }, 5000)

  lu.assertNotNil(result)
  lu.assertNotNil(result.error, 'Should fail when fast-forward not possible')
  lu.assertStrContains(result.error:lower(), 'merge')

  vim.fn.delete(git_repo, 'rf')
end

function TestGitMerge:testGitMergeAbort()
  if vim.fn.executable('git') ~= 1 then
    print('Skipping testGitMergeAbort: git not available')
    return
  end

  local git_repo = create_temp_git_repo('abort')
  set_allowed_path(git_repo)

  local test_file = git_repo .. '/test.lua'
  vim.fn.writefile({ 'print("main")' }, test_file)
  vim.fn.system('git -C "' .. git_repo .. '" add ' .. test_file)
  vim.fn.system('git -C "' .. git_repo .. '" commit -m "Initial commit"')

  vim.fn.system('git -C "' .. git_repo .. '" checkout -b feature')
  vim.fn.writefile({ 'print("feature")' }, test_file)
  vim.fn.system('git -C "' .. git_repo .. '" add ' .. test_file)
  vim.fn.system('git -C "' .. git_repo .. '" commit -m "Feature commit"')

  vim.fn.system('git -C "' .. git_repo .. '" checkout main')
  vim.fn.writefile({ 'print("main conflict")' }, test_file)
  vim.fn.system('git -C "' .. git_repo .. '" add ' .. test_file)
  vim.fn.system('git -C "' .. git_repo .. '" commit -m "Main commit"')

  vim.fn.system('git -C "' .. git_repo .. '" merge feature', true)

  local result = call_async_tool('git_merge', {
    abort = true,
  }, { cwd = git_repo }, 5000)

  lu.assertNotNil(result)
  lu.assertNotNil(
    result.content,
    'Expected content, got error: ' .. (result.error or 'unknown')
  )
  lu.assertStrContains(result.content:lower(), 'success')

  local status = vim.fn.system('git -C "' .. git_repo .. '" status --porcelain')
  lu.assertNotStrContains(status, 'UU')

  vim.fn.delete(git_repo, 'rf')
end

function TestGitMerge:testGitMergeContinue()
  if vim.fn.executable('git') ~= 1 then
    print('Skipping testGitMergeContinue: git not available')
    return
  end

  local git_repo = create_temp_git_repo('continue')
  set_allowed_path(git_repo)

  local test_file = git_repo .. '/test.lua'
  vim.fn.writefile({ 'print("main")' }, test_file)
  vim.fn.system('git -C "' .. git_repo .. '" add ' .. test_file)
  vim.fn.system('git -C "' .. git_repo .. '" commit -m "Initial commit"')

  vim.fn.system('git -C "' .. git_repo .. '" checkout -b feature')
  vim.fn.writefile({ 'print("feature")' }, test_file)
  vim.fn.system('git -C "' .. git_repo .. '" add ' .. test_file)
  vim.fn.system('git -C "' .. git_repo .. '" commit -m "Feature commit"')

  vim.fn.system('git -C "' .. git_repo .. '" checkout main')
  vim.fn.writefile({ 'print("main conflict")' }, test_file)
  vim.fn.system('git -C "' .. git_repo .. '" add ' .. test_file)
  vim.fn.system('git -C "' .. git_repo .. '" commit -m "Main commit"')

  vim.fn.system('git -C "' .. git_repo .. '" merge feature', true)

  vim.fn.writefile({ 'print("resolved")' }, test_file)
  vim.fn.system('git -C "' .. git_repo .. '" add ' .. test_file)

  local result = call_async_tool('git_merge', {
    continue = true,
  }, { cwd = git_repo }, 5000)

  lu.assertNotNil(result)
  lu.assertNotNil(
    result.content,
    'Expected content, got error: ' .. (result.error or 'unknown')
  )
  lu.assertStrContains(result.content:lower(), 'success')

  local log = vim.fn.system('git -C "' .. git_repo .. '" log --oneline')
  lu.assertStrContains(log, 'Merge')

  vim.fn.delete(git_repo, 'rf')
end
