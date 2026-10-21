local lu = require('luaunit')
local tools = require('chat.tools')
local config = require('chat.config')
local git_pull = require('chat.tools.git_pull')

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

local function make_repo(dir)
  vim.fn.mkdir(dir, 'p')
  vim.fn.system('git -C "' .. dir .. '" init')
  -- Hermetic config: disable GPG signing. Machines with
  -- tag.gpgsign/commit.gpgsign=true invoke gpg on tag/commit, which
  -- blocks headless nvim forever waiting for a passphrase.
  vim.fn.system('git -C "' .. dir .. '" config commit.gpgsign false')
  vim.fn.system('git -C "' .. dir .. '" config tag.gpgsign false')
  vim.fn.system('git -C "' .. dir .. '" config user.email "test@test.com"')
  vim.fn.system('git -C "' .. dir .. '" config user.name "Test User"')
  return vim.fs.normalize(dir)
end

local function create_temp_git_repo(name)
  name = name or 'git_pull'
  local cache_dir = vim.fs.normalize(vim.fn.stdpath('data'))
  local temp_dir = cache_dir
    .. '/test_'
    .. name
    .. '_'
    .. os.time()
    .. '_'
    .. math.random(10000, 99999)
  return make_repo(temp_dir)
end

local function commit_file(repo, filename, content, msg)
  local f = repo .. '/' .. filename
  vim.fn.writefile({ content }, f)
  vim.fn.system('git -C "' .. repo .. '" add ' .. f)
  vim.fn.system('git -C "' .. repo .. '" commit -m "' .. msg .. '"')
end

local function set_allowed_path(path)
  config.config.allowed_path = vim.fs.normalize(path)
end

TestGitPull = {}

function TestGitPull:setUp()
  set_allowed_path(vim.fn.getcwd())
end

function TestGitPull:tearDown()
  set_allowed_path(vim.fn.getcwd())
end

function TestGitPull:testGitPullAvailable()
  local available = tools.available_tools()
  local tool_names = {}
  for _, tool in ipairs(available) do
    tool_names[tool['function'].name] = true
  end
  lu.assertTrue(tool_names['git_pull'], 'git_pull tool should be available')
end

function TestGitPull:testGitPullSecurityOutsideAllowedPath()
  local temp_dir = create_temp_git_repo('security')
  local result = tools.call('git_pull', {}, { cwd = temp_dir })
  lu.assertNotNil(result)
  lu.assertNotNil(result.error, 'Should reject path outside allowed_path')
  lu.assertStrContains(result.error, 'allowed')
  vim.fn.delete(temp_dir, 'rf')
end

function TestGitPull:testInfoDefault()
  local info = git_pull.info('not json', { cwd = vim.fn.getcwd() })
  lu.assertEquals('git_pull', info)
end

function TestGitPull:testInfoFull()
  local info = git_pull.info(
    vim.json.encode({
      remote = 'upstream',
      branch = 'main',
      rebase = true,
      force = true,
    }),
    { cwd = vim.fn.getcwd() }
  )
  lu.assertStrContains(info, 'remote="upstream"')
  lu.assertStrContains(info, 'branch="main"')
  lu.assertStrContains(info, 'rebase=true')
  lu.assertStrContains(info, 'force=true')
end

function TestGitPull:testScheme()
  local scheme = git_pull.scheme()
  lu.assertEquals('function', scheme.type)
  lu.assertEquals('git_pull', scheme['function'].name)
  lu.assertNotNil(scheme['function'].parameters.properties.rebase)
end

function TestGitPull:testGitPullNoRemoteFails()
  if vim.fn.executable('git') ~= 1 then
    print('Skipping testGitPullNoRemoteFails: git not available')
    return
  end
  local git_repo = create_temp_git_repo('no_remote')
  set_allowed_path(git_repo)
  commit_file(git_repo, 'a.txt', 'a', 'A')

  local result = call_async_tool('git_pull', {}, { cwd = git_repo }, 3000)
  lu.assertNotNil(result)
  lu.assertNotNil(result.error, 'Expected error when no remote configured')

  vim.fn.delete(git_repo, 'rf')
end

function TestGitPull:testGitPullWithFlagsBuildsCommand()
  if vim.fn.executable('git') ~= 1 then
    print('Skipping testGitPullWithFlagsBuildsCommand: git not available')
    return
  end
  local git_repo = create_temp_git_repo('flags')
  set_allowed_path(git_repo)
  commit_file(git_repo, 'a.txt', 'a', 'A')

  -- No remote + branch specified -> still fails, but exercises command build
  local result = call_async_tool('git_pull', {
    branch = 'main',
    rebase = true,
    force = true,
  }, { cwd = git_repo }, 3000)
  lu.assertNotNil(result)

  vim.fn.delete(git_repo, 'rf')
end

function TestGitPull:testGitPullUpToDate()
  if vim.fn.executable('git') ~= 1 then
    print('Skipping testGitPullUpToDate: git not available')
    return
  end
  local cache_dir = vim.fs.normalize(vim.fn.stdpath('data'))
  local base = cache_dir .. '/test_pull_' .. os.time() .. '_' .. math.random(10000, 99999)
  local origin = make_repo(base .. '_origin')
  commit_file(origin, 'a.txt', 'a', 'A')

  local work = base .. '_work'
  vim.fn.system('git clone "' .. origin .. '" "' .. work .. '"')
  set_allowed_path(vim.fs.normalize(work))

  local result = call_async_tool('git_pull', {}, { cwd = vim.fs.normalize(work) }, 5000)
  lu.assertNotNil(result)
  lu.assertNotNil(result.content, 'Expected content, got error: ' .. (result.error or 'unknown'))

  vim.fn.delete(base .. '_origin', 'rf')
  vim.fn.delete(work, 'rf')
end

function TestGitPull:testGitPullWithUpdates()
  if vim.fn.executable('git') ~= 1 then
    print('Skipping testGitPullWithUpdates: git not available')
    return
  end
  local cache_dir = vim.fs.normalize(vim.fn.stdpath('data'))
  local base = cache_dir .. '/test_pull_upd_' .. os.time() .. '_' .. math.random(10000, 99999)
  local origin = make_repo(base .. '_origin')
  commit_file(origin, 'a.txt', 'a', 'A')

  local work = base .. '_work'
  vim.fn.system('git clone "' .. origin .. '" "' .. work .. '"')

  -- Add new commit to origin
  commit_file(origin, 'b.txt', 'b', 'B')

  set_allowed_path(vim.fs.normalize(work))
  local result = call_async_tool('git_pull', {}, { cwd = vim.fs.normalize(work) }, 5000)
  lu.assertNotNil(result)
  lu.assertNotNil(result.content, 'Expected content, got error: ' .. (result.error or 'unknown'))

  vim.fn.delete(base .. '_origin', 'rf')
  vim.fn.delete(work, 'rf')
end

return TestGitPull
