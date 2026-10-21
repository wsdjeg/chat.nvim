local lu = require('luaunit')
local tools = require('chat.tools')
local config = require('chat.config')
local git_tag = require('chat.tools.git_tag')

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
  name = name or 'git_tag_extra'
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
  vim.fn.system('git -C "' .. temp_dir .. '" config user.email "test@test.com"')
  vim.fn.system('git -C "' .. temp_dir .. '" config user.name "Test User"')
  return vim.fs.normalize(temp_dir)
end

local function set_allowed_path(path)
  config.config.allowed_path = vim.fs.normalize(path)
end

TestGitTagExtra = {}

function TestGitTagExtra:setUp()
  set_allowed_path(vim.fn.getcwd())
end

function TestGitTagExtra:tearDown()
  set_allowed_path(vim.fn.getcwd())
end

function TestGitTagExtra:testInfoDefault()
  lu.assertEquals('git_tag', git_tag.info('not json', { cwd = vim.fn.getcwd() }))
end

function TestGitTagExtra:testInfoFull()
  local info = git_tag.info(
    vim.json.encode({
      action = 'create',
      name = 'v1.0.0',
      message = 'Release',
      force = true,
      remote = 'origin',
    }),
    { cwd = vim.fn.getcwd() }
  )
  lu.assertStrContains(info, 'action="create"')
  lu.assertStrContains(info, 'name="v1.0.0"')
  lu.assertStrContains(info, 'message="Release"')
  lu.assertStrContains(info, 'force=true')
  lu.assertStrContains(info, 'remote="origin"')
end

function TestGitTagExtra:testScheme()
  local scheme = git_tag.scheme()
  lu.assertEquals('git_tag', scheme['function'].name)
end

function TestGitTagExtra:testGitTagInvalidAction()
  local result = tools.call('git_tag', {
    action = 'bogus',
  }, { cwd = vim.fn.getcwd() })
  lu.assertNotNil(result)
  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'Invalid action')
end

function TestGitTagExtra:testGitTagCreateMissingName()
  local result = tools.call('git_tag', {
    action = 'create',
  }, { cwd = vim.fn.getcwd() })
  lu.assertNotNil(result)
  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'Tag name is required')
end

function TestGitTagExtra:testGitTagDeleteMissingName()
  local result = tools.call('git_tag', {
    action = 'delete',
  }, { cwd = vim.fn.getcwd() })
  lu.assertNotNil(result)
  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'Tag name is required')
end

function TestGitTagExtra:testGitTagPushNoNameFails()
  if vim.fn.executable('git') ~= 1 then
    print('Skipping testGitTagPushNoNameFails: git not available')
    return
  end
  local git_repo = create_temp_git_repo('push_no_name')
  set_allowed_path(git_repo)

  local result = call_async_tool('git_tag', {
    action = 'push',
  }, { cwd = git_repo }, 3000)
  lu.assertNotNil(result)
  -- push without remote fails; exercises command build + error path
  lu.assertTrue(result.error ~= nil)

  vim.fn.delete(git_repo, 'rf')
end

function TestGitTagExtra:testGitTagPushWithNameForce()
  if vim.fn.executable('git') ~= 1 then
    print('Skipping testGitTagPushWithNameForce: git not available')
    return
  end
  local git_repo = create_temp_git_repo('push_force')
  set_allowed_path(git_repo)

  local test_file = git_repo .. '/test.lua'
  vim.fn.writefile({ 'print("test")' }, test_file)
  vim.fn.system('git -C "' .. git_repo .. '" add ' .. test_file)
  vim.fn.system('git -C "' .. git_repo .. '" commit -m "Initial commit"')
  vim.fn.system('git -C "' .. git_repo .. '" tag v1.0.0')

  local result = call_async_tool('git_tag', {
    action = 'push',
    name = 'v1.0.0',
    force = true,
    remote = 'origin',
  }, { cwd = git_repo }, 3000)
  lu.assertNotNil(result)
  -- No remote configured -> push fails (non-zero exit)
  lu.assertTrue(result.error ~= nil)

  vim.fn.delete(git_repo, 'rf')
end

return TestGitTagExtra
