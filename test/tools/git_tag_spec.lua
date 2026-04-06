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
  name = name or 'git_tag'
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

TestGitTag = {}

function TestGitTag:setUp()
  -- Reset to project directory
  set_allowed_path(vim.fn.getcwd())
end

function TestGitTag:tearDown()
  -- Reset to project directory
  set_allowed_path(vim.fn.getcwd())
end

function TestGitTag:testGitTagAvailable()
  local available = tools.available_tools()
  local tool_names = {}
  for _, tool in ipairs(available) do
    tool_names[tool['function'].name] = true
  end
  lu.assertTrue(tool_names['git_tag'], 'git_tag tool should be available')
end

function TestGitTag:testGitTagSecurityOutsideAllowedPath()
  -- Create a temp git repo
  local temp_dir = create_temp_git_repo('security')

  -- allowed_path is set to project dir in setUp, so temp_dir should be outside
  local result = tools.call('git_tag', {
    action = 'create',
    name = 'v1.0.0',
  }, { cwd = temp_dir })

  lu.assertNotNil(result)
  lu.assertNotNil(result.error, 'Should reject path outside allowed_path')
  lu.assertStrContains(result.error, 'allowed')

  vim.fn.delete(temp_dir, 'rf')
end

function TestGitTag:testGitTagCreateAnnotated()
  if vim.fn.executable('git') ~= 1 then
    print('Skipping testGitTagCreateAnnotated: git not available')
    return
  end

  local git_repo = create_temp_git_repo('annotate')
  set_allowed_path(git_repo)
  vim.fn.system({ 'git', '-C', git_repo, 'config', 'commit.gpgSign', 'false' })
  vim.fn.system({ 'git', '-C', git_repo, 'config', 'tag.gpgSign', 'false' })
  local test_file = git_repo .. '/test.lua'
  vim.fn.writefile({ 'print("test")' }, test_file)
  vim.fn.system('git -C "' .. git_repo .. '" add ' .. test_file)
  vim.fn.system('git -C "' .. git_repo .. '" commit -m "Initial commit"')

  local result = call_async_tool('git_tag', {
    action = 'create',
    name = 'v1.0.0',
    message = 'Release version 1.0.0',
  }, { cwd = git_repo }, 5000)

  lu.assertNotNil(result)
  lu.assertNotNil(
    result.content,
    'Expected content, got error: ' .. (result.error or 'unknown')
  )
  lu.assertStrContains(result.content:lower(), 'success')

  local tags = vim.fn.system('git -C "' .. git_repo .. '" tag')
  lu.assertStrContains(tags, 'v1.0.0')

  local tag_info = vim.fn.system('git -C "' .. git_repo .. '" tag -n v1.0.0')
  lu.assertStrContains(tag_info, 'Release version 1.0.0')

  vim.fn.delete(git_repo, 'rf')
end

function TestGitTag:testGitTagCreateLightweight()
  if vim.fn.executable('git') ~= 1 then
    print('Skipping testGitTagCreateLightweight: git not available')
    return
  end

  local git_repo = create_temp_git_repo('lightweight')
  set_allowed_path(git_repo)
  vim.fn.system({ 'git', '-C', git_repo, 'config', 'commit.gpgSign', 'false' })
  vim.fn.system({ 'git', '-C', git_repo, 'config', 'tag.gpgSign', 'false' })

  local test_file = git_repo .. '/test.lua'
  vim.fn.writefile({ 'print("test")' }, test_file)
  vim.fn.system('git -C "' .. git_repo .. '" add ' .. test_file)
  vim.fn.system('git -C "' .. git_repo .. '" commit -m "Initial commit"')

  local result = call_async_tool('git_tag', {
    action = 'create',
    name = 'v1.0.0',
  }, { cwd = git_repo }, 5000)

  lu.assertNotNil(result)
  lu.assertNotNil(
    result.content,
    'Expected content, got error: ' .. (result.error or 'unknown')
  )
  lu.assertStrContains(result.content:lower(), 'success')

  local tags = vim.fn.system('git -C "' .. git_repo .. '" tag')
  lu.assertStrContains(tags, 'v1.0.0')

  vim.fn.delete(git_repo, 'rf')
end

function TestGitTag:testGitTagList()
  if vim.fn.executable('git') ~= 1 then
    print('Skipping testGitTagList: git not available')
    return
  end

  local git_repo = create_temp_git_repo('list')
  set_allowed_path(git_repo)

  vim.fn.system({ 'git', '-C', git_repo, 'config', 'commit.gpgSign', 'false' })
  vim.fn.system({ 'git', '-C', git_repo, 'config', 'tag.gpgSign', 'false' })

  local test_file = git_repo .. '/test.lua'
  vim.fn.writefile({ 'print("test")' }, test_file)
  vim.fn.system('git -C "' .. git_repo .. '" add ' .. test_file)
  vim.fn.system('git -C "' .. git_repo .. '" commit -m "Initial commit"')

  vim.fn.system('git -C "' .. git_repo .. '" tag v1.0.0')
  vim.fn.system('git -C "' .. git_repo .. '" tag v2.0.0')

  local result = call_async_tool('git_tag', {
    action = 'list',
  }, { cwd = git_repo }, 3000)

  lu.assertNotNil(result)
  lu.assertNotNil(
    result.content,
    'Expected content, got error: ' .. (result.error or 'unknown')
  )
  lu.assertStrContains(result.content, 'v1.0.0')
  lu.assertStrContains(result.content, 'v2.0.0')

  vim.fn.delete(git_repo, 'rf')
end

function TestGitTag:testGitTagDelete()
  if vim.fn.executable('git') ~= 1 then
    print('Skipping testGitTagDelete: git not available')
    return
  end

  local git_repo = create_temp_git_repo('delete')
  set_allowed_path(git_repo)

  vim.fn.system({ 'git', '-C', git_repo, 'config', 'commit.gpgSign', 'false' })
  vim.fn.system({ 'git', '-C', git_repo, 'config', 'tag.gpgSign', 'false' })

  local test_file = git_repo .. '/test.lua'
  vim.fn.writefile({ 'print("test")' }, test_file)
  vim.fn.system('git -C "' .. git_repo .. '" add ' .. test_file)
  vim.fn.system('git -C "' .. git_repo .. '" commit -m "Initial commit"')

  vim.fn.system('git -C "' .. git_repo .. '" tag v1.0.0')

  local result = call_async_tool('git_tag', {
    action = 'delete',
    name = 'v1.0.0',
  }, { cwd = git_repo }, 5000)

  lu.assertNotNil(result)
  lu.assertNotNil(
    result.content,
    'Expected content, got error: ' .. (result.error or 'unknown')
  )
  lu.assertStrContains(result.content:lower(), 'success')

  local tags = vim.fn.system('git -C "' .. git_repo .. '" tag')
  lu.assertNotStrContains(tags, 'v1.0.0')

  vim.fn.delete(git_repo, 'rf')
end

function TestGitTag:testGitTagForce()
  if vim.fn.executable('git') ~= 1 then
    print('Skipping testGitTagForce: git not available')
    return
  end

  local git_repo = create_temp_git_repo('force')
  set_allowed_path(git_repo)

  vim.fn.system({ 'git', '-C', git_repo, 'config', 'commit.gpgSign', 'false' })
  vim.fn.system({ 'git', '-C', git_repo, 'config', 'tag.gpgSign', 'false' })

  local test_file = git_repo .. '/test.lua'
  vim.fn.writefile({ 'print("test")' }, test_file)
  vim.fn.system('git -C "' .. git_repo .. '" add ' .. test_file)
  vim.fn.system('git -C "' .. git_repo .. '" commit -m "Initial commit"')

  vim.fn.system('git -C "' .. git_repo .. '" tag v1.0.0')

  vim.fn.writefile({ 'print("test2")' }, test_file)
  vim.fn.system('git -C "' .. git_repo .. '" add ' .. test_file)
  vim.fn.system('git -C "' .. git_repo .. '" commit -m "Second commit"')

  local result = call_async_tool('git_tag', {
    action = 'create',
    name = 'v1.0.0',
    message = 'Force update tag',
    force = true,
  }, { cwd = git_repo }, 5000)

  lu.assertNotNil(result)
  lu.assertNotNil(
    result.content,
    'Expected content, got error: ' .. (result.error or 'unknown')
  )
  lu.assertStrContains(result.content:lower(), 'success')

  local tag_info = vim.fn.system('git -C "' .. git_repo .. '" tag -n v1.0.0')
  lu.assertStrContains(tag_info, 'Force update tag')

  vim.fn.delete(git_repo, 'rf')
end
