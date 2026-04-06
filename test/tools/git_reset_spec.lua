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
  name = name or 'git_reset'
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

TestGitReset = {}

function TestGitReset:setUp()
  -- Reset to project directory
  set_allowed_path(vim.fn.getcwd())
end

function TestGitReset:tearDown()
  -- Reset to project directory
  set_allowed_path(vim.fn.getcwd())
end

function TestGitReset:testGitResetAvailable()
  local available = tools.available_tools()
  local tool_names = {}
  for _, tool in ipairs(available) do
    tool_names[tool['function'].name] = true
  end
  lu.assertTrue(tool_names['git_reset'], 'git_reset tool should be available')
end

function TestGitReset:testGitResetSecurityOutsideAllowedPath()
  -- Create a temp git repo
  local temp_dir = create_temp_git_repo('security')

  -- allowed_path is set to project dir in setUp, so temp_dir should be outside
  local result = tools.call('git_reset', {
    mode = 'soft',
  }, { cwd = temp_dir })

  lu.assertNotNil(result)
  lu.assertNotNil(result.error, 'Should reject path outside allowed_path')
  lu.assertStrContains(result.error, 'allowed')

  vim.fn.delete(temp_dir, 'rf')
end

function TestGitReset:testGitResetSoft()
  if vim.fn.executable('git') ~= 1 then
    print('Skipping testGitResetSoft: git not available')
    return
  end

  local git_repo = create_temp_git_repo('soft')
  set_allowed_path(git_repo)

  local test_file = git_repo .. '/test.lua'
  vim.fn.writefile({ 'print("test1")' }, test_file)
  vim.fn.system('git -C "' .. git_repo .. '" add ' .. test_file)
  vim.fn.system('git -C "' .. git_repo .. '" commit -m "First commit"')

  vim.fn.writefile({ 'print("test2")' }, test_file)
  vim.fn.system('git -C "' .. git_repo .. '" add ' .. test_file)

  local result = call_async_tool('git_reset', {
    mode = 'soft',
    commit = 'HEAD',
  }, { cwd = git_repo }, 5000)

  lu.assertNotNil(result)
  lu.assertNotNil(
    result.content,
    'Expected content, got error: ' .. (result.error or 'unknown')
  )
  lu.assertStrContains(result.content:lower(), 'success')

  local status = vim.fn.system('git -C "' .. git_repo .. '" status --porcelain')
  lu.assertStrContains(status, 'test.lua')

  vim.fn.delete(git_repo, 'rf')
end

function TestGitReset:testGitResetMixed()
  if vim.fn.executable('git') ~= 1 then
    print('Skipping testGitResetMixed: git not available')
    return
  end

  local git_repo = create_temp_git_repo('mixed')
  set_allowed_path(git_repo)

  local test_file = git_repo .. '/test.lua'
  vim.fn.writefile({ 'print("test1")' }, test_file)
  vim.fn.system('git -C "' .. git_repo .. '" add ' .. test_file)
  vim.fn.system('git -C "' .. git_repo .. '" commit -m "First commit"')

  vim.fn.writefile({ 'print("test2")' }, test_file)
  vim.fn.system('git -C "' .. git_repo .. '" add ' .. test_file)

  local result = call_async_tool('git_reset', {
    mode = 'mixed',
    commit = 'HEAD',
  }, { cwd = git_repo }, 5000)

  lu.assertNotNil(result)
  lu.assertNotNil(
    result.content,
    'Expected content, got error: ' .. (result.error or 'unknown')
  )
  lu.assertStrContains(result.content:lower(), 'success')

  local status = vim.fn.system('git -C "' .. git_repo .. '" status --porcelain')
  lu.assertStrContains(status, 'test.lua')

  vim.fn.delete(git_repo, 'rf')
end

function TestGitReset:testGitResetHard()
  if vim.fn.executable('git') ~= 1 then
    print('Skipping testGitResetHard: git not available')
    return
  end

  local git_repo = create_temp_git_repo('hard')
  set_allowed_path(git_repo)

  local test_file = git_repo .. '/test.lua'
  vim.fn.writefile({ 'print("test1")' }, test_file)
  vim.fn.system('git -C "' .. git_repo .. '" add ' .. test_file)
  vim.fn.system('git -C "' .. git_repo .. '" commit -m "First commit"')

  vim.fn.writefile({ 'print("test2")' }, test_file)
  vim.fn.system('git -C "' .. git_repo .. '" add ' .. test_file)

  local result = call_async_tool('git_reset', {
    mode = 'hard',
    commit = 'HEAD',
  }, { cwd = git_repo }, 5000)

  lu.assertNotNil(result)
  lu.assertNotNil(
    result.content,
    'Expected content, got error: ' .. (result.error or 'unknown')
  )
  lu.assertStrContains(result.content:lower(), 'success')

  local content = table.concat(vim.fn.readfile(test_file), '\n')
  lu.assertStrContains(content, 'test1')

  vim.fn.delete(git_repo, 'rf')
end

function TestGitReset:testGitResetPath()
  if vim.fn.executable('git') ~= 1 then
    print('Skipping testGitResetPath: git not available')
    return
  end

  local git_repo = create_temp_git_repo('path')
  set_allowed_path(git_repo)

  local test_file1 = git_repo .. '/test1.lua'
  local test_file2 = git_repo .. '/test2.lua'

  -- 初始提交
  vim.fn.writefile({ 'print("test1")' }, test_file1)
  vim.fn.writefile({ 'print("test2")' }, test_file2)
  vim.fn.system('git -C "' .. git_repo .. '" add .')
  vim.fn.system('git -C "' .. git_repo .. '" commit -m "Initial commit"')

  -- 修改文件
  vim.fn.writefile({ 'print("modified1")' }, test_file1)
  vim.fn.writefile({ 'print("modified2")' }, test_file2)

  -- 👇 关键：先 staged，制造可被 reset 的状态
  vim.fn.system('git -C "' .. git_repo .. '" add .')

  -- 执行 git reset <path>（应只 unstage test1.lua）
  local result = call_async_tool('git_reset', {
    path = test_file1,
  }, { cwd = git_repo }, 5000)

  lu.assertNotNil(result)
  lu.assertNotNil(
    result.content,
    'Expected content, got error: ' .. (result.error or 'unknown')
  )
  lu.assertStrContains(result.content:lower(), 'success')

  -- 检查状态
  local status = vim.fn.system('git -C "' .. git_repo .. '" status --porcelain')

  -- test1.lua 被 unstage -> 工作区修改（前面有空格）
  lu.assertStrContains(status, ' M test1.lua')

  -- test2.lua 仍然 staged
  lu.assertStrContains(status, 'M  test2.lua')

  vim.fn.delete(git_repo, 'rf')
end
