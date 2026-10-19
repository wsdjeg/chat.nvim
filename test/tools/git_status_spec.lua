local lu = require('luaunit')
local tools = require('chat.tools')
local config = require('chat.config')
local git_status = require('chat.tools.git_status')

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
  name = name or 'git_status'
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

TestGitStatus = {}

function TestGitStatus:setUp()
  set_allowed_path(vim.fn.getcwd())
end

function TestGitStatus:tearDown()
  set_allowed_path(vim.fn.getcwd())
end

function TestGitStatus:testGitStatusAvailable()
  local available = tools.available_tools()
  local tool_names = {}
  for _, tool in ipairs(available) do
    tool_names[tool['function'].name] = true
  end
  lu.assertTrue(tool_names['git_status'], 'git_status tool should be available')
end

function TestGitStatus:testGitStatusSecurityOutsideAllowedPath()
  local temp_dir = create_temp_git_repo('security')
  local result = tools.call('git_status', { short = true }, { cwd = temp_dir })
  lu.assertNotNil(result)
  lu.assertNotNil(result.error, 'Should reject path outside allowed_path')
  lu.assertStrContains(result.error, 'allowed')
  vim.fn.delete(temp_dir, 'rf')
end

function TestGitStatus:testFormatStatusShortBranchLine()
  local out = git_status.format_status('## main\n M file.lua', true)
  lu.assertStrContains(out, 'Branch: main')
  lu.assertStrContains(out, 'M')
  lu.assertStrContains(out, 'file.lua')
end

function TestGitStatus:testFormatStatusLongPassthrough()
  local out = git_status.format_status('On branch main\nChanges not staged', false)
  lu.assertEquals('On branch main\nChanges not staged', out)
end

function TestGitStatus:testFormatStatusUnmatchedLine()
  local out = git_status.format_status('some weird line', true)
  lu.assertStrContains(out, 'some weird line')
end

function TestGitStatus:testStatusCodeDescription()
  lu.assertEquals(' (modified)', git_status.status_code_description(' M'))
  lu.assertEquals(' (staged)', git_status.status_code_description('M '))
  lu.assertEquals(' (untracked)', git_status.status_code_description('??'))
  lu.assertEquals(' (conflict)', git_status.status_code_description('UU'))
  lu.assertEquals('', git_status.status_code_description('ZZ'))
end

function TestGitStatus:testInfoDefault()
  local info = git_status.info('not json', { cwd = vim.fn.getcwd() })
  lu.assertEquals('git_status', info)
end

function TestGitStatus:testInfoPath()
  local info = git_status.info(
    vim.json.encode({ path = './src' }),
    { cwd = vim.fn.getcwd() }
  )
  lu.assertStrContains(info, '"./src"')
end

function TestGitStatus:testInfoShortFalse()
  local info = git_status.info(
    vim.json.encode({ short = false }),
    { cwd = vim.fn.getcwd() }
  )
  lu.assertStrContains(info, 'short=false')
end

function TestGitStatus:testScheme()
  local scheme = git_status.scheme()
  lu.assertEquals('function', scheme.type)
  lu.assertEquals('git_status', scheme['function'].name)
end

function TestGitStatus:testGitStatusClean()
  if vim.fn.executable('git') ~= 1 then
    print('Skipping testGitStatusClean: git not available')
    return
  end
  local git_repo = create_temp_git_repo('clean')
  set_allowed_path(git_repo)

  local test_file = git_repo .. '/test.lua'
  vim.fn.writefile({ 'print("test")' }, test_file)
  vim.fn.system('git -C "' .. git_repo .. '" add ' .. test_file)
  vim.fn.system('git -C "' .. git_repo .. '" commit -m "Initial commit"')

  local result = call_async_tool('git_status', {
    short = true,
    show_branch = false,
  }, { cwd = git_repo }, 3000)
  lu.assertNotNil(result)
  lu.assertNotNil(result.content, 'Expected content, got error: ' .. (result.error or 'unknown'))
  lu.assertStrContains(result.content, 'Working tree clean')

  vim.fn.delete(git_repo, 'rf')
end

function TestGitStatus:testGitStatusModified()
  if vim.fn.executable('git') ~= 1 then
    print('Skipping testGitStatusModified: git not available')
    return
  end
  local git_repo = create_temp_git_repo('modified')
  set_allowed_path(git_repo)

  local test_file = git_repo .. '/test.lua'
  vim.fn.writefile({ 'print("test")' }, test_file)
  vim.fn.system('git -C "' .. git_repo .. '" add ' .. test_file)
  vim.fn.system('git -C "' .. git_repo .. '" commit -m "Initial commit"')

  vim.fn.writefile({ 'print("modified")' }, test_file)

  local result = call_async_tool('git_status', { short = true }, { cwd = git_repo }, 3000)
  lu.assertNotNil(result)
  lu.assertNotNil(result.content, 'Expected content, got error: ' .. (result.error or 'unknown'))

  vim.fn.delete(git_repo, 'rf')
end

function TestGitStatus:testGitStatusLongFormat()
  if vim.fn.executable('git') ~= 1 then
    print('Skipping testGitStatusLongFormat: git not available')
    return
  end
  local git_repo = create_temp_git_repo('long')
  set_allowed_path(git_repo)

  local test_file = git_repo .. '/test.lua'
  vim.fn.writefile({ 'print("test")' }, test_file)
  vim.fn.system('git -C "' .. git_repo .. '" add ' .. test_file)
  vim.fn.system('git -C "' .. git_repo .. '" commit -m "Initial commit"')

  local result = call_async_tool('git_status', {
    short = false,
    show_branch = true,
  }, { cwd = git_repo }, 3000)
  lu.assertNotNil(result)
  lu.assertNotNil(result.content, 'Expected content, got error: ' .. (result.error or 'unknown'))

  vim.fn.delete(git_repo, 'rf')
end

function TestGitStatus:testGitStatusNonGitDirFails()
  if vim.fn.executable('git') ~= 1 then
    print('Skipping testGitStatusNonGitDirFails: git not available')
    return
  end
  local cache_dir = vim.fs.normalize(vim.fn.stdpath('data'))
  local temp_dir = cache_dir .. '/test_non_git_' .. os.time() .. '_' .. math.random(10000, 99999)
  vim.fn.mkdir(temp_dir, 'p')
  set_allowed_path(temp_dir)

  local result = call_async_tool('git_status', { short = true }, { cwd = temp_dir }, 3000)
  lu.assertNotNil(result)
  lu.assertNotNil(result.error, 'Expected error in non-git directory')

  vim.fn.delete(temp_dir, 'rf')
end

return TestGitStatus
