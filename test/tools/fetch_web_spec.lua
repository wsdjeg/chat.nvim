-- test/tools/fetch_web_spec.lua
-- Tests for the fetch_web tool. Fully offline via test/job.lua interception:
--   - parameter validation (url scheme, method, timeout, max_redirects, max_length)
--   - defensive coercion of numeric params sent as JSON strings
--     (regression: `attempt to compare number with string` in on_exit)
--   - mocked job success / failure / signal paths
--   - output-file mode
--   - info() formatting with numeric-string arguments

local lu = require('luaunit')
local job = require('job')
local fetch_web = require('chat.tools.fetch_web')

TestFetchWeb = {}

local curl_available = vim.fn.executable('curl') == 1

local function make_ctx()
  local ctx = {}
  ctx.cwd = vim.fn.getcwd()
  ctx.result = nil
  ctx.callback = function(res)
    ctx.result = res
  end
  return ctx
end

function TestFetchWeb:setUp()
  job.intercept()
end

function TestFetchWeb:tearDown()
  job.reset()
end

-- ============================
-- Scheme
-- ============================

function TestFetchWeb:testScheme()
  local scheme = fetch_web.scheme()
  lu.assertEquals(scheme.type, 'function')
  lu.assertEquals(scheme['function'].name, 'fetch_web')
  lu.assertEquals(scheme['function'].parameters.required, { 'url' })
end

-- ============================
-- URL validation (runs before the curl check, no curl needed)
-- ============================

function TestFetchWeb:testUrlRequired()
  local res = fetch_web.fetch_web({}, make_ctx())
  lu.assertStrContains(res.error, 'URL is required')
end

function TestFetchWeb:testUrlMustBeString()
  local res = fetch_web.fetch_web({ url = 123 }, make_ctx())
  lu.assertStrContains(res.error, 'URL is required')
end

function TestFetchWeb:testUrlSchemeRejected()
  local res = fetch_web.fetch_web({ url = 'ftp://example.com/file' }, make_ctx())
  lu.assertStrContains(res.error, 'Only HTTP/HTTPS')
end

function TestFetchWeb:testUrlFileSchemeRejected()
  local res = fetch_web.fetch_web({ url = 'file:///etc/passwd' }, make_ctx())
  lu.assertStrContains(res.error, 'Only HTTP/HTTPS')
end

-- ============================
-- Numeric params sent as JSON strings (regression)
-- ============================
-- Models sometimes send numbers as strings ("10000" instead of 10000).
-- Before the fix, max_length had no type validation and crashed on_exit
-- with `attempt to compare number with string`.

function TestFetchWeb:testMaxLengthStringDoesNotCrash()
  if not curl_available then
    print('Skipping testMaxLengthStringDoesNotCrash: curl not available')
    return
  end
  local ctx = make_ctx()
  local res = fetch_web.fetch_web({
    url = 'https://example.com',
    max_length = '10000',
  }, ctx)
  lu.assertNil(res.error)
  lu.assertIsNumber(res.jobid)
  job.emit_stdout(res.jobid, { 'hello world' })
  job.emit_exit(res.jobid, 0) -- must not raise
  lu.assertNil(ctx.result.error)
  lu.assertStrContains(ctx.result.content, 'hello world')
end

function TestFetchWeb:testMaxLengthStringTruncates()
  if not curl_available then
    print('Skipping testMaxLengthStringTruncates: curl not available')
    return
  end
  local ctx = make_ctx()
  local res = fetch_web.fetch_web({
    url = 'https://example.com',
    max_length = '10',
  }, ctx)
  lu.assertNil(res.error)
  job.emit_stdout(res.jobid, { string.rep('a', 100) })
  job.emit_exit(res.jobid, 0) -- must not raise
  lu.assertNil(ctx.result.error)
  lu.assertStrContains(ctx.result.content, '[Content truncated from 100 to 10 characters')
end

function TestFetchWeb:testMaxLengthZeroDisablesTruncation()
  if not curl_available then
    print('Skipping testMaxLengthZeroDisablesTruncation: curl not available')
    return
  end
  local ctx = make_ctx()
  local res = fetch_web.fetch_web({
    url = 'https://example.com',
    max_length = 0,
  }, ctx)
  lu.assertNil(res.error)
  job.emit_stdout(res.jobid, { string.rep('a', 100) })
  job.emit_exit(res.jobid, 0)
  lu.assertNil(ctx.result.error)
  lu.assertStrContains(ctx.result.content, string.rep('a', 100))
  lu.assertNotStrContains(ctx.result.content, 'Content truncated')
end

function TestFetchWeb:testMaxLengthNegativeDisablesTruncation()
  if not curl_available then
    print('Skipping testMaxLengthNegativeDisablesTruncation: curl not available')
    return
  end
  local ctx = make_ctx()
  local res = fetch_web.fetch_web({
    url = 'https://example.com',
    max_length = -1,
  }, ctx)
  lu.assertNil(res.error)
  job.emit_stdout(res.jobid, { string.rep('b', 100) })
  job.emit_exit(res.jobid, 0)
  lu.assertNil(ctx.result.error)
  lu.assertStrContains(ctx.result.content, string.rep('b', 100))
end

function TestFetchWeb:testMaxLengthNonNumericRejected()
  if not curl_available then
    print('Skipping testMaxLengthNonNumericRejected: curl not available')
    return
  end
  local res = fetch_web.fetch_web({
    url = 'https://example.com',
    max_length = 'abc',
  }, make_ctx())
  lu.assertStrContains(res.error, 'max_length must be an integer')
end

function TestFetchWeb:testMaxLengthBooleanRejected()
  if not curl_available then
    print('Skipping testMaxLengthBooleanRejected: curl not available')
    return
  end
  local res = fetch_web.fetch_web({
    url = 'https://example.com',
    max_length = true,
  }, make_ctx())
  lu.assertStrContains(res.error, 'max_length must be an integer')
end

function TestFetchWeb:testMaxLengthNumberStillWorks()
  if not curl_available then
    print('Skipping testMaxLengthNumberStillWorks: curl not available')
    return
  end
  local ctx = make_ctx()
  local res = fetch_web.fetch_web({
    url = 'https://example.com',
    max_length = 500,
  }, ctx)
  lu.assertNil(res.error)
  job.emit_stdout(res.jobid, { 'plain number' })
  job.emit_exit(res.jobid, 0)
  lu.assertNil(ctx.result.error)
  lu.assertStrContains(ctx.result.content, 'plain number')
end

function TestFetchWeb:testTimeoutStringAccepted()
  if not curl_available then
    print('Skipping testTimeoutStringAccepted: curl not available')
    return
  end
  local ctx = make_ctx()
  local res = fetch_web.fetch_web({
    url = 'https://example.com',
    timeout = '60',
  }, ctx)
  lu.assertNil(res.error)
  job.emit_stdout(res.jobid, { 'ok' })
  job.emit_exit(res.jobid, 0)
  lu.assertNil(ctx.result.error)
  lu.assertStrContains(ctx.result.content, 'Timeout: 60 seconds')
end

function TestFetchWeb:testTimeoutNonNumericRejected()
  if not curl_available then
    print('Skipping testTimeoutNonNumericRejected: curl not available')
    return
  end
  local res = fetch_web.fetch_web({
    url = 'https://example.com',
    timeout = 'abc',
  }, make_ctx())
  lu.assertStrContains(res.error, 'Timeout must be between 1 and 300 seconds')
end

function TestFetchWeb:testMaxRedirectsStringAccepted()
  if not curl_available then
    print('Skipping testMaxRedirectsStringAccepted: curl not available')
    return
  end
  local ctx = make_ctx()
  local res = fetch_web.fetch_web({
    url = 'https://example.com',
    max_redirects = '3',
  }, ctx)
  lu.assertNil(res.error)
  lu.assertIsNumber(res.jobid)
end

function TestFetchWeb:testMaxRedirectsNonNumericRejected()
  if not curl_available then
    print('Skipping testMaxRedirectsNonNumericRejected: curl not available')
    return
  end
  local res = fetch_web.fetch_web({
    url = 'https://example.com',
    max_redirects = 'many',
  }, make_ctx())
  lu.assertStrContains(res.error, 'Max redirects must be between 0 and 20')
end

-- ============================
-- Method / headers validation
-- ============================

function TestFetchWeb:testInvalidMethodRejected()
  if not curl_available then
    print('Skipping testInvalidMethodRejected: curl not available')
    return
  end
  local res = fetch_web.fetch_web({
    url = 'https://example.com',
    method = 'BREW',
  }, make_ctx())
  lu.assertStrContains(res.error, 'Invalid HTTP method: BREW')
end

function TestFetchWeb:testHeadersStringNormalizedToArray()
  if not curl_available then
    print('Skipping testHeadersStringNormalizedToArray: curl not available')
    return
  end
  local ctx = make_ctx()
  local res = fetch_web.fetch_web({
    url = 'https://example.com',
    headers = 'Authorization: Bearer token123',
  }, ctx)
  lu.assertNil(res.error)
  local cmdline = table.concat(job.jobs[res.jobid].cmd, ' ')
  lu.assertStrContains(cmdline, 'Authorization: Bearer token123')
end

-- ============================
-- Mocked job flow
-- ============================

function TestFetchWeb:testSuccessContent()
  if not curl_available then
    print('Skipping testSuccessContent: curl not available')
    return
  end
  local ctx = make_ctx()
  local res = fetch_web.fetch_web({ url = 'https://example.com' }, ctx)
  lu.assertNil(res.error)
  lu.assertIsNumber(res.jobid)
  lu.assertEquals(ctx.result, nil, 'callback not called before exit')
  job.emit_stdout(res.jobid, { '<html>', 'line one', '</html>' })
  job.emit_exit(res.jobid, 0)
  lu.assertNil(ctx.result.error)
  lu.assertStrContains(ctx.result.content, 'line one')
  lu.assertStrContains(ctx.result.content, 'Content-Type: text/html')
  lu.assertEquals(ctx.result.jobid, res.jobid)
end

function TestFetchWeb:testJsonContentTypeDetected()
  if not curl_available then
    print('Skipping testJsonContentTypeDetected: curl not available')
    return
  end
  local ctx = make_ctx()
  local res = fetch_web.fetch_web({ url = 'https://example.com/api' }, ctx)
  lu.assertNil(res.error)
  job.emit_stdout(res.jobid, { '{"key": "value"}' })
  job.emit_exit(res.jobid, 0)
  lu.assertNil(ctx.result.error)
  lu.assertStrContains(ctx.result.content, 'Content-Type: application/json')
end

function TestFetchWeb:testExitErrorIncludesCurlHint()
  if not curl_available then
    print('Skipping testExitErrorIncludesCurlHint: curl not available')
    return
  end
  local ctx = make_ctx()
  local res = fetch_web.fetch_web({ url = 'https://example.com' }, ctx)
  lu.assertNil(res.error)
  job.emit_stderr(res.jobid, { "couldn't connect to host" })
  job.emit_exit(res.jobid, 7)
  lu.assertStrContains(ctx.result.error, 'exit code: 7')
  lu.assertStrContains(ctx.result.error, 'Failed to connect to host')
end

function TestFetchWeb:testExitSignalCancelled()
  if not curl_available then
    print('Skipping testExitSignalCancelled: curl not available')
    return
  end
  local ctx = make_ctx()
  local res = fetch_web.fetch_web({ url = 'https://example.com' }, ctx)
  lu.assertNil(res.error)
  job.emit_exit(res.jobid, 0, 15)
  lu.assertStrContains(ctx.result.error, 'cancelled by user (signal: 15)')
end

function TestFetchWeb:testOutputFileModeSuccess()
  if not curl_available then
    print('Skipping testOutputFileModeSuccess: curl not available')
    return
  end
  local out = vim.fn.getcwd() .. '/test_fetch_web_output_tmp.html'
  -- Simulate curl having saved the file before exit
  vim.fn.writefile({ 'saved content' }, out)
  local ctx = make_ctx()
  local res = fetch_web.fetch_web({
    url = 'https://example.com',
    output = out,
  }, ctx)
  lu.assertNil(res.error)
  job.emit_exit(res.jobid, 0)
  lu.assertNil(ctx.result.error)
  lu.assertStrContains(ctx.result.content, 'Output file: ')
  vim.fn.delete(out)
end

function TestFetchWeb:testOutputFileMissingAfterSuccess()
  if not curl_available then
    print('Skipping testOutputFileMissingAfterSuccess: curl not available')
    return
  end
  -- Do not create the file: fs_stat fails after a zero exit
  local out = vim.fn.getcwd() .. '/test_fetch_web_output_missing_tmp.html'
  vim.fn.delete(out)
  local ctx = make_ctx()
  local res = fetch_web.fetch_web({
    url = 'https://example.com',
    output = out,
  }, ctx)
  lu.assertNil(res.error)
  job.emit_exit(res.jobid, 0)
  lu.assertStrContains(
    ctx.result.error,
    'output file was not created'
  )
end

-- ============================
-- info()
-- ============================

function TestFetchWeb:testInfoBasic()
  local info = fetch_web.info(vim.json.encode({ url = 'https://example.com' }), nil)
  lu.assertEquals(info, 'fetch_web "https://example.com"')
end

function TestFetchWeb:testInfoNumericStrings()
  local info = fetch_web.info(
    vim.json.encode({
      url = 'https://example.com',
      timeout = '30',
      max_length = '5000',
    }),
    nil
  )
  lu.assertStrContains(info, 'timeout=30')
  lu.assertStrContains(info, 'max_length=5000')
end

function TestFetchWeb:testInfoNumbers()
  local info = fetch_web.info(
    vim.json.encode({
      url = 'https://example.com',
      timeout = 45,
      max_length = 2000,
      method = 'POST',
      output = './res.json',
    }),
    nil
  )
  lu.assertStrContains(info, 'method=POST')
  lu.assertStrContains(info, 'timeout=45')
  lu.assertStrContains(info, 'max_length=2000')
  lu.assertStrContains(info, 'output=./res.json')
end

function TestFetchWeb:testInfoNonNumericStringDoesNotCrash()
  local info = fetch_web.info(
    vim.json.encode({ url = 'https://example.com', timeout = 'fast' }),
    nil
  )
  lu.assertStrContains(info, 'timeout=fast')
end

function TestFetchWeb:testInfoInvalidJson()
  local info = fetch_web.info('not json', nil)
  lu.assertEquals(info, 'fetch_web')
end

return TestFetchWeb

