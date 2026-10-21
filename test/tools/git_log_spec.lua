local lu = require('luaunit')
local tools = require('chat.tools')
local config = require('chat.config')
local git_log = require('chat.tools.git_log')

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
  name = name or 'git_log'
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
  -- Hermetic config: disable GPG signing. Machines with
  -- tag.gpgsign/commit.gpgsign=true invoke gpg on tag/commit, which
  -- blocks headless nvim forever waiting for a passphrase.
  vim.fn.system('git -C "' .. temp_dir .. '" config commit.gpgsign false')
  vim.fn.system('git -C "' .. temp_dir .. '" config tag.gpgsign false')
  vim.fn.system(
    'git -C "' .. temp_dir .. '" config user.email "test@test.com"'
  )
  vim.fn.system('git -C "' .. temp_dir .. '" config user.name "Test User"')
  return vim.fs.normalize(temp_dir)
end

local function set_allowed_path(path)
  config.config.allowed_path = vim.fs.normalize(path)
end

TestGitLog = {}

function TestGitLog:setUp()
  set_allowed_path(vim.fn.getcwd())
end

function TestGitLog:tearDown()
  set_allowed_path(vim.fn.getcwd())
end

function TestGitLog:testGitLogAvailable()
  local available = tools.available_tools()
  local tool_names = {}
  for _, tool in ipairs(available) do
    tool_names[tool['function'].name] = true
  end
  lu.assertTrue(tool_names['git_log'], 'git_log tool should be available')
end

function TestGitLog:testGitLogSecurityOutsideAllowedPath()
  local temp_dir = create_temp_git_repo('security')
  local result = tools.call('git_log', {}, { cwd = temp_dir })
  lu.assertNotNil(result)
  lu.assertNotNil(result.error, 'Should reject path outside allowed_path')
  lu.assertStrContains(result.error, 'allowed')
  vim.fn.delete(temp_dir, 'rf')
end

function TestGitLog:testInfoDefault()
  local info = git_log.info('not json', { cwd = vim.fn.getcwd() })
  lu.assertEquals('git_log', info)
end

function TestGitLog:testInfoRange()
  local info = git_log.info(
    vim.json.encode({ from = 'v1.0.0', to = 'v2.0.0' }),
    { cwd = vim.fn.getcwd() }
  )
  lu.assertStrContains(info, 'range=v1.0.0..v2.0.0')
end

function TestGitLog:testInfoCountAndFlags()
  local info = git_log.info(
    vim.json.encode({
      count = 10,
      oneline = false,
      author = 'Alice',
      since = '2024-01-01',
      grep = 'fix',
    }),
    { cwd = vim.fn.getcwd() }
  )
  lu.assertStrContains(info, 'count=10')
  lu.assertStrContains(info, 'oneline=false')
  lu.assertStrContains(info, 'author="Alice"')
  lu.assertStrContains(info, 'since="2024-01-01"')
  lu.assertStrContains(info, 'grep="fix"')
end

function TestGitLog:testInfoPath()
  local info = git_log.info(
    vim.json.encode({ path = './src/main.lua' }),
    { cwd = vim.fn.getcwd() }
  )
  lu.assertStrContains(info, 'path="./src/main.lua"')
end

function TestGitLog:testScheme()
  local scheme = git_log.scheme()
  lu.assertEquals('function', scheme.type)
  lu.assertEquals('git_log', scheme['function'].name)
  lu.assertNotNil(scheme['function'].parameters.properties.count)
end

function TestGitLog:testGitLogDefault()
  if vim.fn.executable('git') ~= 1 then
    print('Skipping testGitLogDefault: git not available')
    return
  end
  local git_repo = create_temp_git_repo('default')
  set_allowed_path(git_repo)

  local test_file = git_repo .. '/test.lua'
  vim.fn.writefile({ 'print("test")' }, test_file)
  vim.fn.system('git -C "' .. git_repo .. '" add ' .. test_file)
  vim.fn.system('git -C "' .. git_repo .. '" commit -m "Initial commit"')

  local result = call_async_tool('git_log', {}, { cwd = git_repo }, 3000)
  lu.assertNotNil(result)
  lu.assertNotNil(result.content, 'Expected content, got error: ' .. (result.error or 'unknown'))
  lu.assertStrContains(result.content, 'Initial commit')

  vim.fn.delete(git_repo, 'rf')
end

function TestGitLog:testGitLogCountZero()
  if vim.fn.executable('git') ~= 1 then
    print('Skipping testGitLogCountZero: git not available')
    return
  end
  local git_repo = create_temp_git_repo('count_zero')
  set_allowed_path(git_repo)

  local test_file = git_repo .. '/test.lua'
  vim.fn.writefile({ 'print("test")' }, test_file)
  vim.fn.system('git -C "' .. git_repo .. '" add ' .. test_file)
  vim.fn.system('git -C "' .. git_repo .. '" commit -m "Initial commit"')

  local result = call_async_tool('git_log', { count = 0 }, { cwd = git_repo }, 3000)
  lu.assertNotNil(result)
  lu.assertNotNil(result.content, 'Expected content, got error: ' .. (result.error or 'unknown'))
  lu.assertStrContains(result.content, 'Initial commit')

  vim.fn.delete(git_repo, 'rf')
end

function TestGitLog:testGitLogWithFilters()
  if vim.fn.executable('git') ~= 1 then
    print('Skipping testGitLogWithFilters: git not available')
    return
  end
  local git_repo = create_temp_git_repo('filters')
  set_allowed_path(git_repo)

  local test_file = git_repo .. '/test.lua'
  vim.fn.writefile({ 'print("test")' }, test_file)
  vim.fn.system('git -C "' .. git_repo .. '" add ' .. test_file)
  vim.fn.system('git -C "' .. git_repo .. '" commit -m "fix a bug"')

  local result = call_async_tool('git_log', {
    author = 'Test',
    grep = 'fix',
    since = '2020-01-01',
  }, { cwd = git_repo }, 3000)
  lu.assertNotNil(result)
  lu.assertNotNil(result.content, 'Expected content, got error: ' .. (result.error or 'unknown'))
  lu.assertStrContains(result.content, 'fix a bug')

  vim.fn.delete(git_repo, 'rf')
end

function TestGitLog:testGitLogNoCommitsForPath()
  if vim.fn.executable('git') ~= 1 then
    print('Skipping testGitLogNoCommitsForPath: git not available')
    return
  end
  local git_repo = create_temp_git_repo('no_commits_path')
  set_allowed_path(git_repo)

  local test_file = git_repo .. '/test.lua'
  vim.fn.writefile({ 'print("test")' }, test_file)
  vim.fn.system('git -C "' .. git_repo .. '" add ' .. test_file)
  vim.fn.system('git -C "' .. git_repo .. '" commit -m "Initial commit"')

  local result = call_async_tool('git_log', {
    path = 'nonexistent.txt',
  }, { cwd = git_repo }, 3000)
  lu.assertNotNil(result)
  lu.assertNotNil(result.content, 'Expected content, got error: ' .. (result.error or 'unknown'))
  lu.assertStrContains(result.content, 'No commits found')

  vim.fn.delete(git_repo, 'rf')
end

function TestGitLog:testGitLogEmptyRepoFails()
  if vim.fn.executable('git') ~= 1 then
    print('Skipping testGitLogEmptyRepoFails: git not available')
    return
  end
  local git_repo = create_temp_git_repo('empty_repo')
  set_allowed_path(git_repo)

  local result = call_async_tool('git_log', {}, { cwd = git_repo }, 3000)
  lu.assertNotNil(result)
  lu.assertNotNil(result.error, 'Expected error in empty repo without commits')

  vim.fn.delete(git_repo, 'rf')
end

return TestGitLog
