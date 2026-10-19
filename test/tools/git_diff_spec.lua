local lu = require('luaunit')
local tools = require('chat.tools')
local config = require('chat.config')
local git_diff = require('chat.tools.git_diff')

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
  name = name or 'git_diff'
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

local function set_allowed_path(path)
  config.config.allowed_path = vim.fs.normalize(path)
end

TestGitDiff = {}

function TestGitDiff:setUp()
  set_allowed_path(vim.fn.getcwd())
end

function TestGitDiff:tearDown()
  set_allowed_path(vim.fn.getcwd())
end

function TestGitDiff:testGitDiffAvailable()
  local available = tools.available_tools()
  local tool_names = {}
  for _, tool in ipairs(available) do
    tool_names[tool['function'].name] = true
  end
  lu.assertTrue(tool_names['git_diff'], 'git_diff tool should be available')
end

function TestGitDiff:testGitDiffSecurityOutsideAllowedPath()
  local temp_dir = create_temp_git_repo('security')
  local result = tools.call('git_diff', {}, { cwd = temp_dir })
  lu.assertNotNil(result)
  lu.assertNotNil(result.error, 'Should reject path outside allowed_path')
  lu.assertStrContains(result.error, 'allowed')
  vim.fn.delete(temp_dir, 'rf')
end

function TestGitDiff:testGitDiffPathOutsideCwd()
  local temp_dir = create_temp_git_repo('path_out')
  set_allowed_path(temp_dir)
  local result = tools.call('git_diff', {
    path = '../outside',
  }, { cwd = temp_dir })
  lu.assertNotNil(result)
  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'outside working directory')
  vim.fn.delete(temp_dir, 'rf')
end

function TestGitDiff:testInfoDefault()
  local info = git_diff.info('not json', { cwd = vim.fn.getcwd() })
  lu.assertEquals('git_diff', info)
end

function TestGitDiff:testInfoPath()
  local info = git_diff.info(
    vim.json.encode({ path = './src/main.lua', cached = true }),
    { cwd = vim.fn.getcwd() }
  )
  lu.assertStrContains(info, '"./src/main.lua"')
  lu.assertStrContains(info, 'cached=true')
end

function TestGitDiff:testInfoBranch()
  local info = git_diff.info(
    vim.json.encode({ branch = 'main' }),
    { cwd = vim.fn.getcwd() }
  )
  lu.assertStrContains(info, 'branch="main"')
end

function TestGitDiff:testScheme()
  local scheme = git_diff.scheme()
  lu.assertEquals('function', scheme.type)
  lu.assertEquals('git_diff', scheme['function'].name)
  lu.assertNotNil(scheme['function'].parameters.properties.cached)
end

function TestGitDiff:testGitDiffNoChanges()
  if vim.fn.executable('git') ~= 1 then
    print('Skipping testGitDiffNoChanges: git not available')
    return
  end
  local git_repo = create_temp_git_repo('no_changes')
  set_allowed_path(git_repo)

  local test_file = git_repo .. '/test.lua'
  vim.fn.writefile({ 'print("test")' }, test_file)
  vim.fn.system('git -C "' .. git_repo .. '" add ' .. test_file)
  vim.fn.system('git -C "' .. git_repo .. '" commit -m "Initial commit"')

  local result = call_async_tool('git_diff', {}, { cwd = git_repo }, 3000)
  lu.assertNotNil(result)
  lu.assertNotNil(result.content, 'Expected content, got error: ' .. (result.error or 'unknown'))
  lu.assertStrContains(result.content, 'No changes found')

  vim.fn.delete(git_repo, 'rf')
end

function TestGitDiff:testGitDiffCached()
  if vim.fn.executable('git') ~= 1 then
    print('Skipping testGitDiffCached: git not available')
    return
  end
  local git_repo = create_temp_git_repo('cached')
  set_allowed_path(git_repo)

  local test_file = git_repo .. '/test.lua'
  vim.fn.writefile({ 'print("test")' }, test_file)
  vim.fn.system('git -C "' .. git_repo .. '" add ' .. test_file)
  vim.fn.system('git -C "' .. git_repo .. '" commit -m "Initial commit"')
  vim.fn.writefile({ 'print("modified")' }, test_file)
  vim.fn.system('git -C "' .. git_repo .. '" add ' .. test_file)

  local result = call_async_tool('git_diff', {
    cached = true,
  }, { cwd = git_repo }, 3000)
  lu.assertNotNil(result)
  lu.assertNotNil(result.content, 'Expected content, got error: ' .. (result.error or 'unknown'))
  lu.assertStrContains(result.content, 'staged changes')

  vim.fn.delete(git_repo, 'rf')
end

function TestGitDiff:testGitDiffWorkingChanges()
  if vim.fn.executable('git') ~= 1 then
    print('Skipping testGitDiffWorkingChanges: git not available')
    return
  end
  local git_repo = create_temp_git_repo('working')
  set_allowed_path(git_repo)

  local test_file = git_repo .. '/test.lua'
  vim.fn.writefile({ 'print("test")' }, test_file)
  vim.fn.system('git -C "' .. git_repo .. '" add ' .. test_file)
  vim.fn.system('git -C "' .. git_repo .. '" commit -m "Initial commit"')
  vim.fn.writefile({ 'print("modified")' }, test_file)

  local result = call_async_tool('git_diff', {}, { cwd = git_repo }, 3000)
  lu.assertNotNil(result)
  lu.assertNotNil(result.content, 'Expected content, got error: ' .. (result.error or 'unknown'))
  lu.assertStrContains(result.content, 'print("modified")')

  vim.fn.delete(git_repo, 'rf')
end

function TestGitDiff:testGitDiffWithPath()
  if vim.fn.executable('git') ~= 1 then
    print('Skipping testGitDiffWithPath: git not available')
    return
  end
  local git_repo = create_temp_git_repo('with_path')
  set_allowed_path(git_repo)

  local test_file = git_repo .. '/test.lua'
  vim.fn.writefile({ 'print("test")' }, test_file)
  vim.fn.system('git -C "' .. git_repo .. '" add ' .. test_file)
  vim.fn.system('git -C "' .. git_repo .. '" commit -m "Initial commit"')

  local result = call_async_tool('git_diff', {
    path = 'test.lua',
  }, { cwd = git_repo }, 3000)
  lu.assertNotNil(result)
  lu.assertNotNil(result.content, 'Expected content, got error: ' .. (result.error or 'unknown'))

  vim.fn.delete(git_repo, 'rf')
end

function TestGitDiff:testGitDiffNonexistentBranchFails()
  if vim.fn.executable('git') ~= 1 then
    print('Skipping testGitDiffNonexistentBranchFails: git not available')
    return
  end
  local git_repo = create_temp_git_repo('fail')
  set_allowed_path(git_repo)

  local test_file = git_repo .. '/test.lua'
  vim.fn.writefile({ 'print("test")' }, test_file)
  vim.fn.system('git -C "' .. git_repo .. '" add ' .. test_file)
  vim.fn.system('git -C "' .. git_repo .. '" commit -m "Initial commit"')

  local result = call_async_tool('git_diff', {
    branch = 'does-not-exist',
  }, { cwd = git_repo }, 3000)
  lu.assertNotNil(result)
  lu.assertNotNil(result.error, 'Expected error for nonexistent branch')

  vim.fn.delete(git_repo, 'rf')
end

return TestGitDiff
