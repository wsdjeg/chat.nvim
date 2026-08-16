local lu = require('luaunit')
local curl = require('chat.curl')

TestCurl = {}

function TestCurl:test_errors_table()
  lu.assertEquals(curl.ERRORS[6], "Couldn't resolve host. Check your network connection.")
  lu.assertEquals(curl.ERRORS[28], 'Operation timeout. The server took too long to respond.')
  lu.assertStrContains(curl.ERRORS[22], '400')
end

function TestCurl:test_get_error_message()
  lu.assertEquals(curl.get_error_message(6), curl.ERRORS[6])
  lu.assertNil(curl.get_error_message(999))
end

function TestCurl:test_is_retryable_error()
  lu.assertTrue(curl.is_retryable_error(6))
  lu.assertTrue(curl.is_retryable_error(7))
  lu.assertTrue(curl.is_retryable_error(28))
  lu.assertTrue(curl.is_retryable_error(35))
  lu.assertTrue(curl.is_retryable_error(52))
  lu.assertTrue(curl.is_retryable_error(56))
  lu.assertFalse(curl.is_retryable_error(22))
  lu.assertFalse(curl.is_retryable_error(0))
end

function TestCurl:test_is_available()
  -- On CI/dev machines curl exists; value is cached after first call
  local ok, result = pcall(curl.is_available)
  lu.assertTrue(ok)
  lu.assertEquals(type(result), 'boolean')
end

function TestCurl:test_build_request_minimal()
  local cmd = curl.build_request({ url = 'https://example.com' })
  lu.assertEquals(cmd[1], 'curl')
  lu.assertEquals(cmd[2], '-s')
  lu.assertEquals(cmd[#cmd], 'https://example.com')
  -- no method/headers/body flags
  local has_X = vim.tbl_contains(cmd, '-X')
  lu.assertFalse(has_X)
end

function TestCurl:test_build_request_not_silent()
  local cmd = curl.build_request({ url = 'https://example.com', silent = false })
  lu.assertFalse(vim.tbl_contains(cmd, '-s'))
end

function TestCurl:test_build_request_all_flags()
  local cmd = curl.build_request({
    url = 'https://example.com/api',
    method = 'POST',
    headers = { 'Authorization: Bearer k', 'Accept: application/json' },
    no_buffer = true,
    tcp_nodelay = true,
    connect_timeout = 5,
    include_headers = true,
    compressed = true,
    follow_redirects = true,
    max_redirects = 3,
    max_time = 60,
    insecure = true,
    no_proxy = true,
    user_agent = 'test-agent',
    output = '/tmp/out.json',
    write_out = '%{http_code}',
  })

  -- vim.fn.index is 0-based, Lua tables are 1-based: value sits at index+2
  local function flag_value(cmd, flag)
    return cmd[vim.fn.index(cmd, flag) + 2]
  end

  lu.assertTrue(vim.tbl_contains(cmd, '-N'))
  lu.assertTrue(vim.tbl_contains(cmd, '--tcp-nodelay'))
  lu.assertEquals(flag_value(cmd, '--connect-timeout'), '5')
  lu.assertTrue(vim.tbl_contains(cmd, '-i'))
  lu.assertTrue(vim.tbl_contains(cmd, '--compressed'))
  lu.assertTrue(vim.tbl_contains(cmd, '-L'))
  lu.assertTrue(vim.tbl_contains(cmd, '--max-redirs'))
  lu.assertTrue(vim.tbl_contains(cmd, '--max-time'))
  lu.assertEquals(flag_value(cmd, '--max-time'), '60')
  lu.assertTrue(vim.tbl_contains(cmd, '-k'))
  lu.assertTrue(vim.tbl_contains(cmd, '--noproxy'))
  lu.assertEquals(flag_value(cmd, '-A'), 'test-agent')
  lu.assertEquals(flag_value(cmd, '-X'), 'POST')
  -- headers each have -H prefix
  lu.assertEquals(vim.tbl_count(vim.tbl_filter(function(x)
    return x == '-H'
  end, cmd)), 2)
  lu.assertTrue(vim.tbl_contains(cmd, 'Authorization: Bearer k'))
  lu.assertEquals(flag_value(cmd, '-o'), '/tmp/out.json')
  lu.assertEquals(flag_value(cmd, '-w'), '%{http_code}')
  lu.assertEquals(cmd[#cmd], 'https://example.com/api')
end

function TestCurl:test_build_request_body_inline()
  local cmd = curl.build_request({
    url = 'https://example.com',
    body = '{"a":1}',
  })
  lu.assertTrue(vim.tbl_contains(cmd, '-d'))
  lu.assertTrue(vim.tbl_contains(cmd, '{"a":1}'))
end

function TestCurl:test_build_request_body_stdin()
  local cmd = curl.build_request({
    url = 'https://example.com',
    stdin_body = true,
  })
  lu.assertTrue(vim.tbl_contains(cmd, '-d'))
  lu.assertTrue(vim.tbl_contains(cmd, '@-'))
end

function TestCurl:test_build_request_body_binary()
  local cmd = curl.build_request({
    url = 'https://example.com',
    body = 'raw-bytes',
    body_binary = true,
  })
  lu.assertTrue(vim.tbl_contains(cmd, '--data-binary'))
  lu.assertFalse(vim.tbl_contains(cmd, '-d'))
  lu.assertTrue(vim.tbl_contains(cmd, 'raw-bytes'))
end

function TestCurl:test_build_request_stdin_binary()
  local cmd = curl.build_request({
    url = 'https://example.com',
    stdin_body = true,
    body_binary = true,
  })
  lu.assertTrue(vim.tbl_contains(cmd, '--data-binary'))
  lu.assertTrue(vim.tbl_contains(cmd, '@-'))
end

function TestCurl:test_build_request_max_redirects_implies_follow()
  local cmd = curl.build_request({
    url = 'https://example.com',
    max_redirects = 2,
  })
  lu.assertTrue(vim.tbl_contains(cmd, '-L'))
  lu.assertTrue(vim.tbl_contains(cmd, '--max-redirs'))
end

return TestCurl

