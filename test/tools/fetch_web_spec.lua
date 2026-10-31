-- test/tools/fetch_web_spec.lua
-- Tests for the fetch_web tool. Fully offline via test/job.lua interception:
--   - parameter validation (url scheme, method, timeout, max_redirects, max_length)
--   - defensive coercion of numeric params sent as JSON strings
--     (regression: `attempt to compare number with string` in on_exit)
--   - mocked job success / failure / signal paths
--   - output-file mode
--   - markdown=true conversion via the html2markdown CLI (needs two jobs:
--     curl pipes the HTML into html2markdown stdin, whose exit emits the
--     final result). Conversion-flow tests only run where the CLI is
--     installed; the missing-CLI error path runs everywhere else.
--   - info() formatting with numeric-string arguments

local lu = require('luaunit')
local job = require('job')
local fetch_web = require('chat.tools.fetch_web')

TestFetchWeb = {}

local curl_available = vim.fn.executable('curl') == 1
local html2markdown_available = vim.fn.executable('html2markdown') == 1

local function make_ctx()
  local ctx = {}
  ctx.cwd = vim.fn.getcwd()
  ctx.result = nil
  ctx.callback = function(res)
    ctx.result = res
  end
  return ctx
end

-- Fetch with markdown=true, drive the curl job to success, then return the
-- second (html2markdown) jobid so the spec can simulate its output.
-- Returns res, md_jobid (md_jobid is nil when conversion was skipped).
local function start_markdown_flow(ctx, opts)
  local res = fetch_web.fetch_web(
    vim.tbl_extend('force', {
      url = 'https://example.com',
      markdown = true,
    }, opts or {}),
    ctx
  )
  lu.assertNil(res.error)
  job.emit_stdout(res.jobid, { '<html><body><h1>Title</h1></body></html>' })
  job.emit_exit(res.jobid, 0)
  local md_jobid = res.jobid + 1
  if job.jobs[md_jobid] and job.jobs[md_jobid].cmd[1] == 'html2markdown' then
    return res, md_jobid
  end
  return res, nil
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
  lu.assertNotNil(scheme['function'].parameters.properties.markdown)
  lu.assertEquals(scheme['function'].parameters.properties.markdown.type, 'boolean')
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
-- Markdown conversion (markdown=true)
-- ============================

function TestFetchWeb:testMarkdownMissingCliError()
  if not curl_available then
    print('Skipping testMarkdownMissingCliError: curl not available')
    return
  end
  if html2markdown_available then
    print('Skipping testMarkdownMissingCliError: html2markdown is installed')
    return
  end
  local res = fetch_web.fetch_web({
    url = 'https://example.com',
    markdown = true,
  }, make_ctx())
  lu.assertStrContains(res.error, 'html2markdown CLI')
end

-- Output mode saves the raw response, so markdown=true must skip the
-- html2markdown availability check entirely.
function TestFetchWeb:testMarkdownWithOutputSkipsCliCheck()
  if not curl_available then
    print('Skipping testMarkdownWithOutputSkipsCliCheck: curl not available')
    return
  end
  local out = vim.fn.getcwd() .. '/test_fetch_web_markdown_tmp.html'
  vim.fn.writefile({ '<html>saved</html>' }, out)
  local ctx = make_ctx()
  local res = fetch_web.fetch_web({
    url = 'https://example.com',
    markdown = true,
    output = out,
  }, ctx)
  lu.assertNil(res.error)
  job.emit_exit(res.jobid, 0)
  lu.assertNil(ctx.result.error)
  lu.assertStrContains(ctx.result.content, 'Output file: ')
  -- No second job: the raw response is saved, conversion never starts
  lu.assertNil(job.jobs[res.jobid + 1])
  vim.fn.delete(out)
end

function TestFetchWeb:testMarkdownConvertsHtml()
  if not curl_available or not html2markdown_available then
    print('Skipping testMarkdownConvertsHtml: html2markdown not available')
    return
  end
  local ctx = make_ctx()
  local res, md_jobid = start_markdown_flow(ctx)
  lu.assertNotNil(md_jobid, 'html2markdown job should be started for HTML')
  -- The fetched HTML was piped to html2markdown via stdin
  lu.assertStrContains(table.concat(job.jobs[md_jobid].stdin, '\n'), '<h1>Title</h1>')
  job.emit_stdout(md_jobid, { '# Title' })
  job.emit_exit(md_jobid, 0)
  lu.assertNil(ctx.result.error)
  lu.assertStrContains(ctx.result.content, '# Title')
  lu.assertStrContains(ctx.result.content, 'Content-Type: text/markdown')
  lu.assertNotStrContains(ctx.result.content, '<html>')
  lu.assertEquals(ctx.result.jobid, res.jobid)
end

-- Defensive coercion: some models send "true" instead of true
function TestFetchWeb:testMarkdownStringTrueAccepted()
  if not curl_available or not html2markdown_available then
    print('Skipping testMarkdownStringTrueAccepted: html2markdown not available')
    return
  end
  local ctx = make_ctx()
  local _, md_jobid = start_markdown_flow(ctx, { markdown = 'true' })
  lu.assertNotNil(md_jobid, 'markdown="true" should trigger conversion')
  job.emit_stdout(md_jobid, { '# Title' })
  job.emit_exit(md_jobid, 0)
  lu.assertNil(ctx.result.error)
  lu.assertStrContains(ctx.result.content, 'Content-Type: text/markdown')
end

function TestFetchWeb:testMarkdownSkipsNonHtmlResponse()
  if not curl_available or not html2markdown_available then
    print('Skipping testMarkdownSkipsNonHtmlResponse: html2markdown not available')
    return
  end
  local ctx = make_ctx()
  local res = fetch_web.fetch_web({
    url = 'https://example.com/api',
    markdown = true,
  }, ctx)
  lu.assertNil(res.error)
  job.emit_stdout(res.jobid, { '{"key": "value"}' })
  job.emit_exit(res.jobid, 0)
  -- No conversion job: JSON is returned as-is with an explanatory note
  lu.assertNil(job.jobs[res.jobid + 1])
  lu.assertNil(ctx.result.error)
  lu.assertStrContains(ctx.result.content, 'Content-Type: application/json')
  lu.assertStrContains(ctx.result.content, '[Note: markdown conversion skipped')
  lu.assertStrContains(ctx.result.content, '{"key": "value"}')
end

function TestFetchWeb:testMarkdownConversionFails()
  if not curl_available or not html2markdown_available then
    print('Skipping testMarkdownConversionFails: html2markdown not available')
    return
  end
  local ctx = make_ctx()
  local _, md_jobid = start_markdown_flow(ctx)
  job.emit_stderr(md_jobid, { 'boom' })
  job.emit_exit(md_jobid, 1)
  lu.assertStrContains(ctx.result.error, 'html2markdown failed to convert')
  lu.assertStrContains(ctx.result.error, 'boom')
end

function TestFetchWeb:testMarkdownSignalCancelled()
  if not curl_available or not html2markdown_available then
    print('Skipping testMarkdownSignalCancelled: html2markdown not available')
    return
  end
  local ctx = make_ctx()
  local _, md_jobid = start_markdown_flow(ctx)
  job.emit_exit(md_jobid, 0, 15)
  lu.assertStrContains(ctx.result.error, 'html2markdown cancelled by user (signal: 15)')
end

function TestFetchWeb:testMarkdownTruncatesConvertedOutput()
  if not curl_available or not html2markdown_available then
    print('Skipping testMarkdownTruncatesConvertedOutput: html2markdown not available')
    return
  end
  local ctx = make_ctx()
  local _, md_jobid = start_markdown_flow(ctx, { max_length = 10 })
  job.emit_stdout(md_jobid, { string.rep('x', 100) })
  job.emit_exit(md_jobid, 0)
  lu.assertNil(ctx.result.error)
  lu.assertStrContains(ctx.result.content, '[Content truncated from 100 to 10 characters')
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

function TestFetchWeb:testInfoMarkdown()
  local info = fetch_web.info(
    vim.json.encode({
      url = 'https://example.com',
      markdown = true,
    }),
    nil
  )
  lu.assertStrContains(info, 'markdown=true')
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

-- ============================
-- Loopback proxy bypass
-- ============================
-- http_proxy env vars route loopback URLs through proxy tools (clash,
-- v2ray, ...) which can answer with empty or truncated bodies. Loopback
-- fetches must always go direct (--noproxy '*').

function TestFetchWeb:testLoopbackIpv4BypassesProxy()
  if not curl_available then
    print('Skipping testLoopbackIpv4BypassesProxy: curl not available')
    return
  end
  local ctx = make_ctx()
  local res = fetch_web.fetch_web({ url = 'http://127.0.0.1:7777/sessions' }, ctx)
  lu.assertNil(res.error)
  local cmdline = table.concat(job.jobs[res.jobid].cmd, ' ')
  lu.assertStrContains(cmdline, '--noproxy *')
end

function TestFetchWeb:testLoopbackLocalhostBypassesProxy()
  if not curl_available then
    print('Skipping testLoopbackLocalhostBypassesProxy: curl not available')
    return
  end
  local ctx = make_ctx()
  local res = fetch_web.fetch_web({ url = 'http://localhost:7777/logs' }, ctx)
  lu.assertNil(res.error)
  local cmdline = table.concat(job.jobs[res.jobid].cmd, ' ')
  lu.assertStrContains(cmdline, '--noproxy *')
end

function TestFetchWeb:testLoopbackIpv6BypassesProxy()
  if not curl_available then
    print('Skipping testLoopbackIpv6BypassesProxy: curl not available')
    return
  end
  local ctx = make_ctx()
  local res = fetch_web.fetch_web({ url = 'http://[::1]:7777/logs' }, ctx)
  lu.assertNil(res.error)
  local cmdline = table.concat(job.jobs[res.jobid].cmd, ' ')
  lu.assertStrContains(cmdline, '--noproxy *')
end

function TestFetchWeb:testExternalUrlKeepsProxyEnv()
  if not curl_available then
    print('Skipping testExternalUrlKeepsProxyEnv: curl not available')
    return
  end
  local ctx = make_ctx()
  local res = fetch_web.fetch_web({ url = 'https://example.com' }, ctx)
  lu.assertNil(res.error)
  local cmdline = table.concat(job.jobs[res.jobid].cmd, ' ')
  lu.assertNotStrContains(cmdline, '--noproxy')
end

return TestFetchWeb

