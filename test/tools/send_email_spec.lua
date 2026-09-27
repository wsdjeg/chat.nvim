local lu = require('luaunit')
local tools = require('chat.tools')
local config = require('chat.config')
local send_email = require('chat.tools.send_email')

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

local function is_windows()
  return vim.fn.has('win32') == 1
end

--- Create a fake `mail` executable that records its arguments and stdin
--- to files, then exits with the given code.
---@param exit_code string Exit status of the fake command
---@return string dir Fake bin directory
---@return string args_file
---@return string stdin_file
local function create_fake_mail(exit_code)
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, 'p')
  local args_file = dir .. '/args.txt'
  local stdin_file = dir .. '/stdin.txt'
  local sh = vim.fn.exepath('sh')
  local script = table.concat({
    '#!' .. sh,
    string.format("printf '%%s\\n' \"$@\" > '%s'", args_file),
    string.format("cat > '%s'", stdin_file),
    'exit ' .. exit_code,
  }, '\n')
  local script_path = dir .. '/mail'
  vim.fn.writefile(vim.split(script, '\n'), script_path)
  vim.fn.setfperm(script_path, 'rwx------')
  return dir, args_file, stdin_file
end

--- Prepend a directory to PATH and reset the availability cache
---@param dir string Directory containing the fake `mail`
---@return string original_path
local function with_fake_mail_in_path(dir)
  local original_path = vim.fn.getenv('PATH') or ''
  vim.fn.setenv('PATH', dir .. ':' .. original_path)
  send_email._reset_availability_cache()
  return original_path
end

--- Restore PATH and reset the availability cache
local function restore_path(original_path)
  vim.fn.setenv('PATH', original_path)
  send_email._reset_availability_cache()
end

TestSendEmail = {}

function TestSendEmail:setUp()
  self.test_cwd = vim.fs.normalize(vim.fn.getcwd())
  config.setup({
    allowed_path = self.test_cwd,
  })
  send_email._reset_availability_cache()
end

function TestSendEmail:tearDown()
  send_email._reset_availability_cache()
end

-- ============================
-- Scheme Tests
-- ============================

function TestSendEmail:testScheme()
  local scheme = send_email.scheme()

  lu.assertNotNil(scheme)
  lu.assertEquals(scheme.type, 'function')
  lu.assertEquals(scheme['function'].name, 'send_email')
  lu.assertEquals(scheme['function'].parameters.type, 'object')

  local required = scheme['function'].parameters.required
  lu.assertTrue(vim.tbl_contains(required, 'to'))
  lu.assertTrue(vim.tbl_contains(required, 'subject'))

  local props = scheme['function'].parameters.properties
  lu.assertNotNil(props.to)
  lu.assertNotNil(props.subject)
  lu.assertNotNil(props.body)
  lu.assertNotNil(props.cc)
  lu.assertNotNil(props.bcc)
end

-- ============================
-- Info Tests
-- ============================

function TestSendEmail:testInfoBasic()
  local info = send_email.info(
    '{"to":"user@example.com","subject":"Hello"}',
    { cwd = '/test' }
  )

  lu.assertNotNil(info)
  lu.assertStrContains(info, 'send_email')
  lu.assertStrContains(info, 'user@example.com')
  lu.assertStrContains(info, 'Hello')
end

function TestSendEmail:testInfoWithCcBcc()
  local info = send_email.info(
    '{"to":"a@x.com","subject":"S","cc":"c@x.com","bcc":"b@x.com"}',
    { cwd = '/test' }
  )

  lu.assertStrContains(info, 'cc="c@x.com"')
  lu.assertStrContains(info, 'bcc="b@x.com"')
end

function TestSendEmail:testInfoInvalidJson()
  local info = send_email.info('invalid json', { cwd = '/test' })
  lu.assertEquals(info, 'send_email')
end

-- ============================
-- Registration Test
-- ============================

function TestSendEmail:testRegistered()
  local available = tools.available_tools()
  local tool_names = {}
  for _, tool in ipairs(available) do
    table.insert(tool_names, tool['function'].name)
  end

  lu.assertTrue(
    vim.tbl_contains(tool_names, 'send_email'),
    'send_email should be in available_tools'
  )
end

-- ============================
-- Validation Tests
-- (All run before the mail availability check, so they pass on
--  every platform even without the mail command installed.)
-- ============================

function TestSendEmail:testMissingTo()
  local result = tools.call('send_email', {
    subject = 'Hello',
  }, { cwd = self.test_cwd })

  lu.assertNotNil(result)
  lu.assertNotNil(result.error)
  lu.assertNil(result.jobid, 'Must not start a mail process')
  lu.assertStrContains(result.error, 'to')
end

function TestSendEmail:testEmptyTo()
  local result = tools.call('send_email', {
    to = '',
    subject = 'Hello',
  }, { cwd = self.test_cwd })

  lu.assertNotNil(result)
  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'to')
end

function TestSendEmail:testInvalidTo()
  local result = tools.call('send_email', {
    to = 'not-an-email',
    subject = 'Hello',
  }, { cwd = self.test_cwd })

  lu.assertNotNil(result)
  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'invalid')
  lu.assertStrContains(result.error, 'not-an-email')
end

function TestSendEmail:testInvalidToPartial()
  local result = tools.call('send_email', {
    to = 'user@example.com,broken',
    subject = 'Hello',
  }, { cwd = self.test_cwd })

  lu.assertNotNil(result)
  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'invalid')
end

function TestSendEmail:testOptionInjectionInTo()
  -- An option-like address must be rejected: it would otherwise be
  -- interpreted as a flag by the mail command.
  local result = tools.call('send_email', {
    to = '-b evil@example.com',
    subject = 'Hello',
  }, { cwd = self.test_cwd })

  lu.assertNotNil(result)
  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'option')
end

function TestSendEmail:testOptionInjectionInCc()
  local result = tools.call('send_email', {
    to = 'user@example.com',
    subject = 'Hello',
    cc = '-s injected subject',
  }, { cwd = self.test_cwd })

  lu.assertNotNil(result)
  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'option')
end

function TestSendEmail:testMissingSubject()
  local result = tools.call('send_email', {
    to = 'user@example.com',
  }, { cwd = self.test_cwd })

  lu.assertNotNil(result)
  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'subject')
end

function TestSendEmail:testEmptySubject()
  local result = tools.call('send_email', {
    to = 'user@example.com',
    subject = '',
  }, { cwd = self.test_cwd })

  lu.assertNotNil(result)
  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'subject')
end

function TestSendEmail:testInvalidCc()
  local result = tools.call('send_email', {
    to = 'user@example.com',
    subject = 'Hello',
    cc = 'nonsense',
  }, { cwd = self.test_cwd })

  lu.assertNotNil(result)
  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'cc')
end

function TestSendEmail:testInvalidBcc()
  local result = tools.call('send_email', {
    to = 'user@example.com',
    subject = 'Hello',
    bcc = 'nonsense',
  }, { cwd = self.test_cwd })

  lu.assertNotNil(result)
  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'bcc')
end

function TestSendEmail:testInvalidBody()
  local result = tools.call('send_email', {
    to = 'user@example.com',
    subject = 'Hello',
    body = 123,
  }, { cwd = self.test_cwd })

  lu.assertNotNil(result)
  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'body')
end

-- ============================
-- Availability Test
-- ============================

function TestSendEmail:testMailNotInstalled()
  send_email._reset_availability_cache()
  if vim.fn.executable('mail') == 1 then
    print('Skipping testMailNotInstalled: mail is available')
    return
  end

  local result = tools.call('send_email', {
    to = 'user@example.com',
    subject = 'Hello',
  }, { cwd = self.test_cwd })

  lu.assertNotNil(result)
  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'not installed')

  send_email._reset_availability_cache()
end

-- ============================
-- Fake Mail Command Tests (Unix only)
-- ============================

function TestSendEmail:testFakeMailSuccess()
  if is_windows() then
    print('Skipping testFakeMailSuccess: fake mail not supported on Windows')
    return
  end

  local dir, args_file, stdin_file = create_fake_mail('0')
  local original_path = with_fake_mail_in_path(dir)

  local body = 'Hello,\n\nThis is a test email sent by chat.nvim.'
  local result = call_async_tool('send_email', {
    to = 'user@example.com',
    subject = 'Test Subject Line',
    body = body,
    cc = 'cc@example.com',
    bcc = 'bcc@example.com',
  }, { cwd = self.test_cwd })

  -- Verify the command line passed to mail:
  -- mail -s <subject> [-c <cc>] [-b <bcc>] <to>
  local args = vim.fn.readfile(args_file)
  lu.assertEquals(args, {
    '-s',
    'Test Subject Line',
    '-c',
    'cc@example.com',
    '-b',
    'bcc@example.com',
    'user@example.com',
  })

  -- Verify the body was piped through stdin
  local stdin_content = table.concat(vim.fn.readfile(stdin_file), '\n')
  lu.assertEquals(stdin_content, body)

  -- Verify success result
  lu.assertNotNil(result)
  lu.assertNil(
    result.error,
    'Expected success, got error: ' .. (result.error or 'unknown')
  )
  lu.assertStrContains(result.content, 'successfully')
  lu.assertStrContains(result.content, 'user@example.com')
  lu.assertStrContains(result.content, 'Test Subject Line')

  restore_path(original_path)
  vim.fn.delete(dir, 'rf')
end

function TestSendEmail:testFakeMailEmptyBody()
  if is_windows() then
    print('Skipping testFakeMailEmptyBody: fake mail not supported on Windows')
    return
  end

  local dir, args_file, stdin_file = create_fake_mail('0')
  local original_path = with_fake_mail_in_path(dir)

  local result = call_async_tool('send_email', {
    to = 'user@example.com',
    subject = 'No body',
  }, { cwd = self.test_cwd })

  lu.assertNotNil(result)
  lu.assertNil(
    result.error,
    'Expected success, got error: ' .. (result.error or 'unknown')
  )

  local args = vim.fn.readfile(args_file)
  lu.assertEquals(args, { '-s', 'No body', 'user@example.com' })

  local stdin_content = table.concat(vim.fn.readfile(stdin_file), '\n')
  lu.assertEquals(stdin_content, '')

  restore_path(original_path)
  vim.fn.delete(dir, 'rf')
end

function TestSendEmail:testFakeMailFailure()
  if is_windows() then
    print('Skipping testFakeMailFailure: fake mail not supported on Windows')
    return
  end

  local dir = create_fake_mail('1')
  local original_path = with_fake_mail_in_path(dir)

  local result = call_async_tool('send_email', {
    to = 'user@example.com',
    subject = 'Fail',
    body = 'x',
  }, { cwd = self.test_cwd })

  lu.assertNotNil(result)
  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'Failed to send email')

  restore_path(original_path)
  vim.fn.delete(dir, 'rf')
end

return TestSendEmail

