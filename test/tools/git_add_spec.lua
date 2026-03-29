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
  name = name or 'git_add'
  local cache_dir = vim.fs.normalize(vim.fn.stdpath('cache'))
  local temp_dir = cache_dir .. '/test_' .. name .. '_' .. os.time() .. '_' .. math.random(10000, 99999)
  vim.fn.mkdir(temp_dir, 'p')
  vim.fn.system('git -C "' .. temp_dir .. '" init')
  vim.fn.system('git -C "' .. temp_dir .. '" config user.email "test@test.com"')
  vim.fn.system('git -C "' .. temp_dir .. '" config user.name "Test User"')
  return vim.fs.normalize(temp_dir)
end

-- Set allowed path directly
local function set_allowed_path(path)
  config.config.allowed_path = vim.fs.normalize(path)
end

TestGitAdd = {}

function TestGitAdd:setUp()
  -- Reset to project directory
  set_allowed_path(vim.fn.getcwd())
end

function TestGitAdd:tearDown()
  -- Reset to project directory
  set_allowed_path(vim.fn.getcwd())
end

function TestGitAdd:testGitAddAvailable()
  local available = tools.available_tools()
  local tool_names = {}
  for _, tool in ipairs(available) do
    tool_names[tool['function'].name] = true
  end
  lu.assertTrue(tool_names['git_add'], 'git_add tool should be available')
end

function TestGitAdd:testGitAddSecurityOutsideAllowedPath()
  -- Create a temp git repo
  local temp_dir = create_temp_git_repo('security')
  
  -- allowed_path is set to project dir in setUp, so temp_dir should be outside
  local result = tools.call('git_add', {
    path = temp_dir .. '/test.lua',
  }, { cwd = temp_dir })

  lu.assertNotNil(result)
  lu.assertNotNil(result.error, 'Should reject path outside allowed_path')
  lu.assertStrContains(result.error, 'allowed')

  vim.fn.delete(temp_dir, 'rf')
end

function TestGitAdd:testGitAddNoGitRepo()
  if vim.fn.executable('git') ~= 1 then
    print('Skipping testGitAddNoGitRepo: git not available')
    return
  end

  -- Create temp directory in cache (no git repo)
  local cache_dir = vim.fs.normalize(vim.fn.stdpath('cache'))
  local temp_dir = cache_dir .. '/test_no_git_' .. os.time() .. '_' .. math.random(10000, 99999)
  vim.fn.mkdir(temp_dir, 'p')
  
  -- Update allowed_path to include temp directory
  set_allowed_path(temp_dir)

  local test_file = temp_dir .. '/test.lua'
  vim.fn.writefile({ '-- test file' }, test_file)

  local result = call_async_tool('git_add', {
    path = test_file,
  }, { cwd = temp_dir }, 3000)

  lu.assertNotNil(result)
  lu.assertNotNil(result.error, 'Should fail in non-git directory, got: ' .. (result.content or 'no content'))
  lu.assertStrContains(result.error:lower(), 'git')

  vim.fn.delete(temp_dir, 'rf')
end

function TestGitAdd:testGitAddInGitRepo()
  if vim.fn.executable('git') ~= 1 then
    print('Skipping testGitAddInGitRepo: git not available')
    return
  end

  local git_repo = create_temp_git_repo('repo')
  
  -- Update allowed_path to include the temp git repo
  set_allowed_path(git_repo)

  local test_file = git_repo .. '/test.lua'
  vim.fn.writefile({ 'print("hello")' }, test_file)

  local result = call_async_tool('git_add', {
    path = test_file,
  }, { cwd = git_repo }, 5000)

  lu.assertNotNil(result)
  lu.assertNotNil(result.content, 'Expected content, got error: ' .. (result.error or 'unknown'))
  lu.assertStrContains(result.content:lower(), 'success')

  vim.fn.delete(git_repo, 'rf')
end

function TestGitAdd:testGitAddMultipleFiles()
  if vim.fn.executable('git') ~= 1 then
    print('Skipping testGitAddMultipleFiles: git not available')
    return
  end

  local git_repo = create_temp_git_repo('multi')
  
  -- Update allowed_path to include the temp git repo
  set_allowed_path(git_repo)

  local test_file1 = git_repo .. '/file1.lua'
  local test_file2 = git_repo .. '/file2.lua'
  vim.fn.writefile({ '-- file 1' }, test_file1)
  vim.fn.writefile({ '-- file 2' }, test_file2)

  local result = call_async_tool('git_add', {
    path = { test_file1, test_file2 },
  }, { cwd = git_repo }, 5000)

  lu.assertNotNil(result)
  lu.assertNotNil(result.content, 'Expected content, got error: ' .. (result.error or 'unknown'))
  lu.assertStrContains(result.content:lower(), 'success')

  vim.fn.delete(git_repo, 'rf')
end

function TestGitAdd:testGitAddAll()
  if vim.fn.executable('git') ~= 1 then
    print('Skipping testGitAddAll: git not available')
    return
  end

  local git_repo = create_temp_git_repo('all')
  
  -- Update allowed_path to include the temp git repo
  set_allowed_path(git_repo)

  vim.fn.writefile({ '-- test 1' }, git_repo .. '/test1.lua')
  vim.fn.writefile({ '-- test 2' }, git_repo .. '/test2.lua')

  local result = call_async_tool('git_add', {
    all = true,
  }, { cwd = git_repo }, 5000)

  lu.assertNotNil(result)
  lu.assertNotNil(result.content, 'Expected content, got error: ' .. (result.error or 'unknown'))
  lu.assertStrContains(result.content:lower(), 'success')

  vim.fn.delete(git_repo, 'rf')
end

