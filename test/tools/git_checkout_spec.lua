local lu = require('luaunit')
local tools = require('chat.tools')
local config = require('chat.config')
local git_checkout = require('chat.tools.git_checkout')

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
  name = name or 'git_checkout'
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

TestGitCheckout = {}

function TestGitCheckout:setUp()
  set_allowed_path(vim.fn.getcwd())
end

function TestGitCheckout:tearDown()
  set_allowed_path(vim.fn.getcwd())
end

function TestGitCheckout:testGitCheckoutAvailable()
  local available = tools.available_tools()
  local tool_names = {}
  for _, tool in ipairs(available) do
    tool_names[tool['function'].name] = true
  end
  lu.assertTrue(tool_names['git_checkout'], 'git_checkout tool should be available')
end

function TestGitCheckout:testGitCheckoutSecurityOutsideAllowedPath()
  local temp_dir = create_temp_git_repo('security')
  local result = tools.call('git_checkout', { branch = 'main' }, { cwd = temp_dir })
  lu.assertNotNil(result)
  lu.assertNotNil(result.error, 'Should reject path outside allowed_path')
  lu.assertStrContains(result.error, 'allowed')
  vim.fn.delete(temp_dir, 'rf')
end

function TestGitCheckout:testGitCheckoutMissingTarget()
  local result = tools.call('git_checkout', {}, { cwd = vim.fn.getcwd() })
  lu.assertNotNil(result)
  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'specify either')
end

function TestGitCheckout:testInfoDefault()
  local info = git_checkout.info('not json', { cwd = vim.fn.getcwd() })
  lu.assertEquals('git_checkout', info)
end

function TestGitCheckout:testInfoNewBranch()
  local info = git_checkout.info(
    vim.json.encode({ new_branch = 'feature', force = true }),
    { cwd = vim.fn.getcwd() }
  )
  lu.assertStrContains(info, 'new_branch="feature"')
  lu.assertStrContains(info, 'force=true')
end

function TestGitCheckout:testInfoBranchTrackDetach()
  local info = git_checkout.info(
    vim.json.encode({ branch = 'origin/main', track = true, detach = true }),
    { cwd = vim.fn.getcwd() }
  )
  lu.assertStrContains(info, 'branch="origin/main"')
  lu.assertStrContains(info, 'track=true')
  lu.assertStrContains(info, 'detach=true')
end

function TestGitCheckout:testInfoFile()
  local info = git_checkout.info(
    vim.json.encode({ file = 'src/main.lua' }),
    { cwd = vim.fn.getcwd() }
  )
  lu.assertStrContains(info, 'file="src/main.lua"')
end

function TestGitCheckout:testScheme()
  local scheme = git_checkout.scheme()
  lu.assertEquals('function', scheme.type)
  lu.assertEquals('git_checkout', scheme['function'].name)
  lu.assertNotNil(scheme['function'].parameters.properties.new_branch)
end

function TestGitCheckout:testGitCheckoutNewBranch()
  if vim.fn.executable('git') ~= 1 then
    print('Skipping testGitCheckoutNewBranch: git not available')
    return
  end
  local git_repo = create_temp_git_repo('new_branch')
  set_allowed_path(git_repo)

  local test_file = git_repo .. '/test.lua'
  vim.fn.writefile({ 'print("test")' }, test_file)
  vim.fn.system('git -C "' .. git_repo .. '" add ' .. test_file)
  vim.fn.system('git -C "' .. git_repo .. '" commit -m "Initial commit"')

  local result = call_async_tool('git_checkout', {
    new_branch = 'feature',
  }, { cwd = git_repo }, 3000)

  lu.assertNotNil(result)
  lu.assertNotNil(result.content, 'Expected content, got error: ' .. (result.error or 'unknown'))
  lu.assertStrContains(result.content, 'feature')

  local branch = vim.fn.system('git -C "' .. git_repo .. '" rev-parse --abbrev-ref HEAD')
  lu.assertStrContains(branch, 'feature')

  vim.fn.delete(git_repo, 'rf')
end

function TestGitCheckout:testGitCheckoutBranch()
  if vim.fn.executable('git') ~= 1 then
    print('Skipping testGitCheckoutBranch: git not available')
    return
  end
  local git_repo = create_temp_git_repo('branch')
  set_allowed_path(git_repo)

  local test_file = git_repo .. '/test.lua'
  vim.fn.writefile({ 'print("test")' }, test_file)
  vim.fn.system('git -C "' .. git_repo .. '" add ' .. test_file)
  vim.fn.system('git -C "' .. git_repo .. '" commit -m "Initial commit"')
  vim.fn.system('git -C "' .. git_repo .. '" branch develop')

  local result = call_async_tool('git_checkout', {
    branch = 'develop',
  }, { cwd = git_repo }, 3000)

  lu.assertNotNil(result)
  lu.assertNotNil(result.content, 'Expected content, got error: ' .. (result.error or 'unknown'))

  local branch = vim.fn.system('git -C "' .. git_repo .. '" rev-parse --abbrev-ref HEAD')
  lu.assertStrContains(branch, 'develop')

  vim.fn.delete(git_repo, 'rf')
end

function TestGitCheckout:testGitCheckoutFile()
  if vim.fn.executable('git') ~= 1 then
    print('Skipping testGitCheckoutFile: git not available')
    return
  end
  local git_repo = create_temp_git_repo('file')
  set_allowed_path(git_repo)

  local test_file = git_repo .. '/test.lua'
  vim.fn.writefile({ 'print("original")' }, test_file)
  vim.fn.system('git -C "' .. git_repo .. '" add ' .. test_file)
  vim.fn.system('git -C "' .. git_repo .. '" commit -m "Initial commit"')

  vim.fn.writefile({ 'print("modified")' }, test_file)

  local result = call_async_tool('git_checkout', {
    file = 'test.lua',
  }, { cwd = git_repo }, 3000)

  lu.assertNotNil(result)
  lu.assertNotNil(result.content, 'Expected content, got error: ' .. (result.error or 'unknown'))

  local content = table.concat(vim.fn.readfile(test_file), '\n')
  lu.assertStrContains(content, 'original')

  vim.fn.delete(git_repo, 'rf')
end

function TestGitCheckout:testGitCheckoutFileWithOutput()
  if vim.fn.executable('git') ~= 1 then
    print('Skipping testGitCheckoutFileWithOutput: git not available')
    return
  end
  local git_repo = create_temp_git_repo('file_output')
  set_allowed_path(git_repo)

  local test_file = git_repo .. '/test.lua'
  vim.fn.writefile({ 'print("original")' }, test_file)
  vim.fn.system('git -C "' .. git_repo .. '" add ' .. test_file)
  vim.fn.system('git -C "' .. git_repo .. '" commit -m "Initial commit"')

  vim.fn.writefile({ 'print("modified")' }, test_file)

  local result = call_async_tool('git_checkout', {
    file = 'test.lua',
    force = true,
  }, { cwd = git_repo }, 3000)

  lu.assertNotNil(result)
  lu.assertNotNil(result.content, 'Expected content, got error: ' .. (result.error or 'unknown'))

  vim.fn.delete(git_repo, 'rf')
end

function TestGitCheckout:testGitCheckoutNonexistentBranchFails()
  if vim.fn.executable('git') ~= 1 then
    print('Skipping testGitCheckoutNonexistentBranchFails: git not available')
    return
  end
  local git_repo = create_temp_git_repo('fail')
  set_allowed_path(git_repo)

  local test_file = git_repo .. '/test.lua'
  vim.fn.writefile({ 'print("test")' }, test_file)
  vim.fn.system('git -C "' .. git_repo .. '" add ' .. test_file)
  vim.fn.system('git -C "' .. git_repo .. '" commit -m "Initial commit"')

  local result = call_async_tool('git_checkout', {
    branch = 'does-not-exist',
  }, { cwd = git_repo }, 3000)

  lu.assertNotNil(result)
  lu.assertNotNil(result.error, 'Expected error for nonexistent branch')

  vim.fn.delete(git_repo, 'rf')
end

return TestGitCheckout
