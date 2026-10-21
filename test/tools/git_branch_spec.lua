local lu = require('luaunit')
local tools = require('chat.tools')
local config = require('chat.config')
local git_branch = require('chat.tools.git_branch')

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
  name = name or 'git_branch'
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

TestGitBranch = {}

function TestGitBranch:setUp()
  set_allowed_path(vim.fn.getcwd())
end

function TestGitBranch:tearDown()
  set_allowed_path(vim.fn.getcwd())
end

function TestGitBranch:testGitBranchAvailable()
  local available = tools.available_tools()
  local tool_names = {}
  for _, tool in ipairs(available) do
    tool_names[tool['function'].name] = true
  end
  lu.assertTrue(tool_names['git_branch'], 'git_branch tool should be available')
end

function TestGitBranch:testGitBranchSecurityOutsideAllowedPath()
  local temp_dir = create_temp_git_repo('security')
  local result = tools.call('git_branch', { list = true }, { cwd = temp_dir })
  lu.assertNotNil(result)
  lu.assertNotNil(result.error, 'Should reject path outside allowed_path')
  lu.assertStrContains(result.error, 'allowed')
  vim.fn.delete(temp_dir, 'rf')
end

function TestGitBranch:testFormatBranchesCurrentAndLocal()
  local out = git_branch.format_branches('* main\n  develop\n  feature', false)
  lu.assertStrContains(out, 'Current: main')
  lu.assertStrContains(out, '→ main (current)')
  lu.assertStrContains(out, '  develop')
  lu.assertStrContains(out, '  feature')
end

function TestGitBranch:testFormatBranchesRemote()
  local out = git_branch.format_branches(
    '* main\n  remotes/origin/main\n  remotes/origin/dev',
    true
  )
  lu.assertStrContains(out, 'origin/main (remote)')
  lu.assertStrContains(out, 'origin/dev (remote)')
end

function TestGitBranch:testFormatBranchesWithoutAllSkipsRemoteLabel()
  local out = git_branch.format_branches('  remotes/origin/main', false)
  -- When all == false, a remote line is treated as a plain branch name
  lu.assertStrContains(out, 'remotes/origin/main')
end

function TestGitBranch:testFormatBranchesEmpty()
  local out = git_branch.format_branches('', false)
  lu.assertStrContains(out, 'Current: HEAD')
end

function TestGitBranch:testInfoDefault()
  local info = git_branch.info(vim.json.encode({}), { cwd = vim.fn.getcwd() })
  lu.assertEquals('git_branch', info)
end

function TestGitBranch:testInfoListAll()
  local info = git_branch.info(
    vim.json.encode({ list = true, all = true }),
    { cwd = vim.fn.getcwd() }
  )
  lu.assertStrContains(info, 'all=true')
end

function TestGitBranch:testInfoCreate()
  local info = git_branch.info(
    vim.json.encode({ branch = 'feature', create = true, force = true }),
    { cwd = vim.fn.getcwd() }
  )
  lu.assertStrContains(info, 'branch="feature"')
  lu.assertStrContains(info, 'create=true')
  lu.assertStrContains(info, 'force=true')
end

function TestGitBranch:testInfoDelete()
  local info = git_branch.info(
    vim.json.encode({ branch = 'old', delete = true }),
    { cwd = vim.fn.getcwd() }
  )
  lu.assertStrContains(info, 'branch="old"')
  lu.assertStrContains(info, 'delete=true')
end

function TestGitBranch:testInfoInvalidJson()
  local info = git_branch.info('not json', { cwd = vim.fn.getcwd() })
  lu.assertEquals('git_branch', info)
end

function TestGitBranch:testScheme()
  local scheme = git_branch.scheme()
  lu.assertEquals('function', scheme.type)
  lu.assertEquals('git_branch', scheme['function'].name)
  lu.assertNotNil(scheme['function'].parameters.properties.branch)
end

function TestGitBranch:testGitBranchList()
  if vim.fn.executable('git') ~= 1 then
    print('Skipping testGitBranchList: git not available')
    return
  end
  local git_repo = create_temp_git_repo('list')
  set_allowed_path(git_repo)

  local test_file = git_repo .. '/test.lua'
  vim.fn.writefile({ 'print("test")' }, test_file)
  vim.fn.system('git -C "' .. git_repo .. '" add ' .. test_file)
  vim.fn.system('git -C "' .. git_repo .. '" commit -m "Initial commit"')

  local result = call_async_tool('git_branch', { list = true }, { cwd = git_repo }, 3000)
  lu.assertNotNil(result)
  lu.assertNotNil(result.content, 'Expected content, got error: ' .. (result.error or 'unknown'))
  lu.assertStrContains(result.content, 'branches')
  lu.assertStrContains(result.content, 'Current')

  vim.fn.delete(git_repo, 'rf')
end

function TestGitBranch:testGitBranchCreate()
  if vim.fn.executable('git') ~= 1 then
    print('Skipping testGitBranchCreate: git not available')
    return
  end
  local git_repo = create_temp_git_repo('create')
  set_allowed_path(git_repo)

  local test_file = git_repo .. '/test.lua'
  vim.fn.writefile({ 'print("test")' }, test_file)
  vim.fn.system('git -C "' .. git_repo .. '" add ' .. test_file)
  vim.fn.system('git -C "' .. git_repo .. '" commit -m "Initial commit"')

  local result = call_async_tool('git_branch', {
    branch = 'feature',
    create = true,
  }, { cwd = git_repo }, 3000)

  lu.assertNotNil(result)
  lu.assertNotNil(result.content, 'Expected content, got error: ' .. (result.error or 'unknown'))

  local branches = vim.fn.system('git -C "' .. git_repo .. '" branch')
  lu.assertStrContains(branches, 'feature')

  vim.fn.delete(git_repo, 'rf')
end

function TestGitBranch:testGitBranchDelete()
  if vim.fn.executable('git') ~= 1 then
    print('Skipping testGitBranchDelete: git not available')
    return
  end
  local git_repo = create_temp_git_repo('delete')
  set_allowed_path(git_repo)

  local test_file = git_repo .. '/test.lua'
  vim.fn.writefile({ 'print("test")' }, test_file)
  vim.fn.system('git -C "' .. git_repo .. '" add ' .. test_file)
  vim.fn.system('git -C "' .. git_repo .. '" commit -m "Initial commit"')
  vim.fn.system('git -C "' .. git_repo .. '" branch feature')

  local result = call_async_tool('git_branch', {
    branch = 'feature',
    delete = true,
  }, { cwd = git_repo }, 3000)

  lu.assertNotNil(result)
  lu.assertNotNil(result.content, 'Expected content, got error: ' .. (result.error or 'unknown'))

  local branches = vim.fn.system('git -C "' .. git_repo .. '" branch')
  lu.assertNotStrContains(branches, 'feature')

  vim.fn.delete(git_repo, 'rf')
end

function TestGitBranch:testGitBranchDeleteNonexistentFails()
  if vim.fn.executable('git') ~= 1 then
    print('Skipping testGitBranchDeleteNonexistentFails: git not available')
    return
  end
  local git_repo = create_temp_git_repo('delete_fail')
  set_allowed_path(git_repo)

  local test_file = git_repo .. '/test.lua'
  vim.fn.writefile({ 'print("test")' }, test_file)
  vim.fn.system('git -C "' .. git_repo .. '" add ' .. test_file)
  vim.fn.system('git -C "' .. git_repo .. '" commit -m "Initial commit"')

  local result = call_async_tool('git_branch', {
    branch = 'does-not-exist',
    delete = true,
  }, { cwd = git_repo }, 3000)

  lu.assertNotNil(result)
  -- Deleting a non-existent branch fails with non-zero exit
  lu.assertTrue(result.error ~= nil or result.content == nil)

  vim.fn.delete(git_repo, 'rf')
end

function TestGitBranch:testGitBranchListAll()
  if vim.fn.executable('git') ~= 1 then
    print('Skipping testGitBranchListAll: git not available')
    return
  end
  local git_repo = create_temp_git_repo('list_all')
  set_allowed_path(git_repo)

  local test_file = git_repo .. '/test.lua'
  vim.fn.writefile({ 'print("test")' }, test_file)
  vim.fn.system('git -C "' .. git_repo .. '" add ' .. test_file)
  vim.fn.system('git -C "' .. git_repo .. '" commit -m "Initial commit"')

  local result = call_async_tool('git_branch', {
    list = true,
    all = true,
  }, { cwd = git_repo }, 3000)

  lu.assertNotNil(result)
  lu.assertNotNil(result.content, 'Expected content, got error: ' .. (result.error or 'unknown'))

  vim.fn.delete(git_repo, 'rf')
end

return TestGitBranch
