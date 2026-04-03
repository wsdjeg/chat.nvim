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
  name = name or 'git_stash'
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

TestGitStash = {}

function TestGitStash:setUp()
  -- Reset to project directory
  set_allowed_path(vim.fn.getcwd())
end

function TestGitStash:tearDown()
  -- Reset to project directory
  set_allowed_path(vim.fn.getcwd())
end

function TestGitStash:testGitStashAvailable()
  local available = tools.available_tools()
  local tool_names = {}
  for _, tool in ipairs(available) do
    tool_names[tool['function'].name] = true
  end
  lu.assertTrue(tool_names['git_stash'], 'git_stash tool should be available')
end

function TestGitStash:testGitStashSecurityOutsideAllowedPath()
  -- Create a temp git repo
  local temp_dir = create_temp_git_repo('security')

  -- allowed_path is set to project dir in setUp, so temp_dir should be outside
  local result = tools.call('git_stash', {
    action = 'save',
    message = 'test stash',
  }, { cwd = temp_dir })

  lu.assertNotNil(result)
  lu.assertNotNil(result.error, 'Should reject path outside allowed_path')
  lu.assertStrContains(result.error, 'allowed')

  vim.fn.delete(temp_dir, 'rf')
end

function TestGitStash:testGitStashSave()
  if vim.fn.executable('git') ~= 1 then
    print('Skipping testGitStashSave: git not available')
    return
  end

  local git_repo = create_temp_git_repo('save')
  set_allowed_path(git_repo)

  local test_file = git_repo .. '/test.lua'
  vim.fn.writefile({ 'print("test")' }, test_file)
  vim.fn.system('git -C "' .. git_repo .. '" add ' .. test_file)
  vim.fn.system('git -C "' .. git_repo .. '" commit -m "Initial commit"')

  vim.fn.writefile({ 'print("modified")' }, test_file)

  local result = call_async_tool('git_stash', {
    action = 'save',
    message = 'Test stash',
  }, { cwd = git_repo }, 5000)

  lu.assertNotNil(result)
  lu.assertNotNil(
    result.content,
    'Expected content, got error: ' .. (result.error or 'unknown')
  )
  lu.assertStrContains(result.content:lower(), 'success')

  vim.fn.delete(git_repo, 'rf')
end

function TestGitStash:testGitStashList()
  if vim.fn.executable('git') ~= 1 then
    print('Skipping testGitStashList: git not available')
    return
  end

  local git_repo = create_temp_git_repo('list')
  set_allowed_path(git_repo)

  local test_file = git_repo .. '/test.lua'
  vim.fn.writefile({ 'print("test")' }, test_file)
  vim.fn.system('git -C "' .. git_repo .. '" add ' .. test_file)
  vim.fn.system('git -C "' .. git_repo .. '" commit -m "Initial commit"')

  vim.fn.writefile({ 'print("modified1")' }, test_file)
  vim.fn.system('git -C "' .. git_repo .. '" stash -m "Stash 1"')

  vim.fn.writefile({ 'print("modified2")' }, test_file)
  vim.fn.system('git -C "' .. git_repo .. '" stash -m "Stash 2"')

  local result = call_async_tool('git_stash', {
    action = 'list',
  }, { cwd = git_repo }, 3000)

  lu.assertNotNil(result)
  lu.assertNotNil(
    result.content,
    'Expected content, got error: ' .. (result.error or 'unknown')
  )
  lu.assertStrContains(result.content:lower(), 'stash')

  vim.fn.delete(git_repo, 'rf')
end

function TestGitStash:testGitStashApply()
  if vim.fn.executable('git') ~= 1 then
    print('Skipping testGitStashApply: git not available')
    return
  end

  local git_repo = create_temp_git_repo('apply')
  set_allowed_path(git_repo)

  local test_file = git_repo .. '/test.lua'
  vim.fn.writefile({ 'print("original")' }, test_file)
  vim.fn.system('git -C "' .. git_repo .. '" add ' .. test_file)
  vim.fn.system('git -C "' .. git_repo .. '" commit -m "Initial commit"')

  vim.fn.writefile({ 'print("stashed")' }, test_file)
  vim.fn.system('git -C "' .. git_repo .. '" stash')

  local result = call_async_tool('git_stash', {
    action = 'apply',
    index = 0,
  }, { cwd: git_repo }, 5000)

  lu.assertNotNil(result)
  lu.assertNotNil(
    result.content,
    'Expected content, got error: ' .. (result.error or 'unknown')
  )
  lu.assertStrContains(result.content:lower(), 'success')

  local content = table.concat(vim.fn.readfile(test_file), '\n')
  lu.assertStrContains(content, 'stashed')

  vim.fn.delete(git_repo, 'rf')
end

function TestGitStash:testGitStashDrop()
  if vim.fn.executable('git') ~= 1 then
    print('Skipping testGitStashDrop: git not available')
    return
  end

  local git_repo = create_temp_git_repo('drop')
  set_allowed_path(git_repo)

  local test_file = git_repo .. '/test.lua'
  vim.fn.writefile({ 'print("test")' }, test_file)
  vim.fn.system('git -C "' .. git_repo .. '" add ' .. test_file)
  vim.fn.system('git -C "' .. git_repo .. '" commit -m "Initial commit"')

  vim.fn.writefile({ 'print("stashed")' }, test_file)
  vim.fn.system('git -C "' .. git_repo .. '" stash')

  local result = call_async_tool('git_stash', {
    action = 'drop',
    index = 0,
  }, { cwd = git_repo }, 5000)

  lu.assertNotNil(result)
  lu.assertNotNil(
    result.content,
    'Expected content, got error: ' .. (result.error or 'unknown')
  )
  lu.assertStrContains(result.content:lower(), 'success')

  vim.fn.delete(git_repo, 'rf')
end

function TestGitStash:testGitStashClear()
  if vim.fn.executable('git') ~= 1 then
    print('Skipping testGitStashClear: git not available')
    return
  end

  local git_repo = create_temp_git_repo('clear')
  set_allowed_path(git_repo)

  local test_file = git_repo .. '/test.lua'
  vim.fn.writefile({ 'print("test")' }, test_file)
  vim.fn.system('git -C "' .. git_repo .. '" add ' .. test_file)
  vim.fn.system('git -C "' .. git_repo .. '" commit -m "Initial commit"')

  vim.fn.writefile({ 'print("stashed1")' }, test_file)
  vim.fn.system('git -C "' .. git_repo .. '" stash -m "Stash 1"')

  vim.fn.writefile({ 'print("stashed2")' }, test_file)
  vim.fn.system('git -C "' .. git_repo .. '" stash -m "Stash 2"')

  local result = call_async_tool('git_stash', {
    action = 'clear',
  }, { cwd = git_repo }, 5000)

  lu.assertNotNil(result)
  lu.assertNotNil(
    result.content,
    'Expected content, got error: ' .. (result.error or 'unknown')
  )
  lu.assertStrContains(result.content:lower(), 'success')

  vim.fn.delete(git_repo, 'rf')
end
