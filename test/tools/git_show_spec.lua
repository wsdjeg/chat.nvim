local lu = require('luaunit')
local tools = require('chat.tools')
local config = require('chat.config')
local git_show = require('chat.tools.git_show')

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
  name = name or 'git_show'
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

TestGitShow = {}

function TestGitShow:setUp()
  set_allowed_path(vim.fn.getcwd())
end

function TestGitShow:tearDown()
  set_allowed_path(vim.fn.getcwd())
end

function TestGitShow:testGitShowAvailable()
  local available = tools.available_tools()
  local tool_names = {}
  for _, tool in ipairs(available) do
    tool_names[tool['function'].name] = true
  end
  lu.assertTrue(tool_names['git_show'], 'git_show tool should be available')
end

function TestGitShow:testGitShowSecurityOutsideAllowedPath()
  local temp_dir = create_temp_git_repo('security')
  local result = tools.call('git_show', { commit = 'HEAD' }, { cwd = temp_dir })
  lu.assertNotNil(result)
  lu.assertNotNil(result.error, 'Should reject path outside allowed_path')
  lu.assertStrContains(result.error, 'allowed')
  vim.fn.delete(temp_dir, 'rf')
end

function TestGitShow:testGitShowMissingCommit()
  local result = tools.call('git_show', {}, { cwd = vim.fn.getcwd() })
  lu.assertNotNil(result)
  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'commit parameter is required')
end

function TestGitShow:testGitShowEmptyCommit()
  local result = tools.call('git_show', { commit = '' }, { cwd = vim.fn.getcwd() })
  lu.assertNotNil(result)
  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'commit parameter is required')
end

function TestGitShow:testGitShowDangerousCommit()
  local result = tools.call('git_show', { commit = 'HEAD; rm -rf /' }, { cwd = vim.fn.getcwd() })
  lu.assertNotNil(result)
  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'Invalid commit format')
end

function TestGitShow:testGitShowPathOutsideCwd()
  local temp_dir = create_temp_git_repo('path_out')
  set_allowed_path(temp_dir)
  local result = tools.call('git_show', {
    commit = 'HEAD',
    path = '../outside',
  }, { cwd = temp_dir })
  lu.assertNotNil(result)
  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'outside working directory')
  vim.fn.delete(temp_dir, 'rf')
end

function TestGitShow:testInfoDefault()
  local info = git_show.info('not json', { cwd = vim.fn.getcwd() })
  lu.assertEquals('git_show', info)
end

function TestGitShow:testInfoCommit()
  local info = git_show.info(
    vim.json.encode({ commit = 'HEAD', stat = true, path = 'src/main.lua' }),
    { cwd = vim.fn.getcwd() }
  )
  lu.assertStrContains(info, 'HEAD')
  lu.assertStrContains(info, 'stat=true')
  lu.assertStrContains(info, 'path="src/main.lua"')
end

function TestGitShow:testScheme()
  local scheme = git_show.scheme()
  lu.assertEquals('function', scheme.type)
  lu.assertEquals('git_show', scheme['function'].name)
  lu.assertNotNil(scheme['function'].parameters.required)
end

function TestGitShow:testGitShowCommit()
  if vim.fn.executable('git') ~= 1 then
    print('Skipping testGitShowCommit: git not available')
    return
  end
  local git_repo = create_temp_git_repo('commit')
  set_allowed_path(git_repo)

  local test_file = git_repo .. '/test.lua'
  vim.fn.writefile({ 'print("test")' }, test_file)
  vim.fn.system('git -C "' .. git_repo .. '" add ' .. test_file)
  vim.fn.system('git -C "' .. git_repo .. '" commit -m "Initial commit"')

  local result = call_async_tool('git_show', { commit = 'HEAD' }, { cwd = git_repo }, 3000)
  lu.assertNotNil(result)
  lu.assertNotNil(result.content, 'Expected content, got error: ' .. (result.error or 'unknown'))
  lu.assertStrContains(result.content, 'Initial commit')

  vim.fn.delete(git_repo, 'rf')
end

function TestGitShow:testGitShowStat()
  if vim.fn.executable('git') ~= 1 then
    print('Skipping testGitShowStat: git not available')
    return
  end
  local git_repo = create_temp_git_repo('stat')
  set_allowed_path(git_repo)

  local test_file = git_repo .. '/test.lua'
  vim.fn.writefile({ 'print("test")' }, test_file)
  vim.fn.system('git -C "' .. git_repo .. '" add ' .. test_file)
  vim.fn.system('git -C "' .. git_repo .. '" commit -m "Initial commit"')

  local result = call_async_tool('git_show', {
    commit = 'HEAD',
    stat = true,
  }, { cwd = git_repo }, 3000)
  lu.assertNotNil(result)
  lu.assertNotNil(result.content, 'Expected content, got error: ' .. (result.error or 'unknown'))
  lu.assertStrContains(result.content, 'stat only')

  vim.fn.delete(git_repo, 'rf')
end

function TestGitShow:testGitShowWithPath()
  if vim.fn.executable('git') ~= 1 then
    print('Skipping testGitShowWithPath: git not available')
    return
  end
  local git_repo = create_temp_git_repo('with_path')
  set_allowed_path(git_repo)

  local test_file = git_repo .. '/test.lua'
  vim.fn.writefile({ 'print("test")' }, test_file)
  vim.fn.system('git -C "' .. git_repo .. '" add ' .. test_file)
  vim.fn.system('git -C "' .. git_repo .. '" commit -m "Initial commit"')

  local result = call_async_tool('git_show', {
    commit = 'HEAD',
    path = 'test.lua',
  }, { cwd = git_repo }, 3000)
  lu.assertNotNil(result)
  lu.assertNotNil(result.content, 'Expected content, got error: ' .. (result.error or 'unknown'))

  vim.fn.delete(git_repo, 'rf')
end

function TestGitShow:testGitShowNonexistentCommitFails()
  if vim.fn.executable('git') ~= 1 then
    print('Skipping testGitShowNonexistentCommitFails: git not available')
    return
  end
  local git_repo = create_temp_git_repo('fail')
  set_allowed_path(git_repo)

  local test_file = git_repo .. '/test.lua'
  vim.fn.writefile({ 'print("test")' }, test_file)
  vim.fn.system('git -C "' .. git_repo .. '" add ' .. test_file)
  vim.fn.system('git -C "' .. git_repo .. '" commit -m "Initial commit"')

  local result = call_async_tool('git_show', {
    commit = 'does-not-exist-commit',
  }, { cwd = git_repo }, 3000)
  lu.assertNotNil(result)
  lu.assertNotNil(result.error, 'Expected error for nonexistent commit')

  vim.fn.delete(git_repo, 'rf')
end

return TestGitShow
