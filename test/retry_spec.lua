-- test/retry_spec.lua
local lu = require('luaunit')
local retry = require('chat.sessions.retry')
local config = require('chat.config')

TestRetry = {}

function TestRetry:setUp()
  -- Ensure config has retry settings
  config.config.retry = {
    max_retries = 3,
    retry_delay = 2000,
  }
  -- Clean state before each test
  retry.reset_retry_count('test-session-1')
  retry.reset_retry_count('test-session-2')
end

function TestRetry:tearDown()
  -- Clean up any pending timers
  retry.cancel_retry('test-session-1')
  retry.cancel_retry('test-session-2')
end

-- ─── is_retryable_error ────────────────────────────────────────

function TestRetry:test_is_retryable_error_connection()
  lu.assertTrue(retry.is_retryable_error(6))  -- Couldn't resolve host
  lu.assertTrue(retry.is_retryable_error(7))  -- Failed to connect
  lu.assertTrue(retry.is_retryable_error(28)) -- Operation timeout
  lu.assertTrue(retry.is_retryable_error(35)) -- SSL/TLS handshake failure
  lu.assertTrue(retry.is_retryable_error(52)) -- Empty reply from server
  lu.assertTrue(retry.is_retryable_error(56)) -- Failure with receiving network data
end

function TestRetry:test_is_not_retryable_error()
  lu.assertFalse(retry.is_retryable_error(0))  -- Success
  lu.assertFalse(retry.is_retryable_error(22)) -- HTTP error >= 400
  lu.assertFalse(retry.is_retryable_error(1))  -- Generic error
  lu.assertFalse(retry.is_retryable_error(nil))
end

-- ─── is_retrying ───────────────────────────────────────────────

function TestRetry:test_is_retrying_initial_false()
  lu.assertFalse(retry.is_retrying('test-session-1'))
end

-- ─── get_retry_count ───────────────────────────────────────────

function TestRetry:test_get_retry_count_initial_zero()
  lu.assertEquals(retry.get_retry_count('test-session-1'), 0)
end

-- ─── handle_exit_error ─────────────────────────────────────────

function TestRetry:test_handle_exit_error_non_retryable()
  -- Code 22 (HTTP error) should not trigger retry
  local result = retry.handle_exit_error('test-session-1', 22)
  lu.assertNil(result)
  lu.assertFalse(retry.is_retrying('test-session-1'))
  lu.assertEquals(retry.get_retry_count('test-session-1'), 0)
end

function TestRetry:test_handle_exit_error_retryable()
  -- Code 7 (connection failure) should trigger retry
  local result = retry.handle_exit_error('test-session-1', 7)
  lu.assertNotNil(result)
  lu.assertTrue(string.find(result, 'Auto%-retry 1/3') ~= nil)
  lu.assertTrue(string.find(result, '2 remaining') ~= nil)
  lu.assertTrue(retry.is_retrying('test-session-1'))
  lu.assertEquals(retry.get_retry_count('test-session-1'), 1)
end

function TestRetry:test_handle_exit_error_timeout()
  -- Code 28 (timeout) should trigger retry
  local result = retry.handle_exit_error('test-session-1', 28)
  lu.assertNotNil(result)
  lu.assertTrue(string.find(result, 'Auto%-retry 1/3') ~= nil)
  lu.assertTrue(retry.is_retrying('test-session-1'))
  lu.assertEquals(retry.get_retry_count('test-session-1'), 1)
end

function TestRetry:test_handle_exit_error_multiple_retries()
  -- First retry
  local r1 = retry.handle_exit_error('test-session-1', 7)
  lu.assertNotNil(r1)
  lu.assertTrue(string.find(r1, '1/3') ~= nil)
  lu.assertTrue(string.find(r1, '2 remaining') ~= nil)
  lu.assertEquals(retry.get_retry_count('test-session-1'), 1)

  -- Second retry
  local r2 = retry.handle_exit_error('test-session-1', 7)
  lu.assertNotNil(r2)
  lu.assertTrue(string.find(r2, '2/3') ~= nil)
  lu.assertTrue(string.find(r2, '1 remaining') ~= nil)
  lu.assertEquals(retry.get_retry_count('test-session-1'), 2)

  -- Third retry
  local r3 = retry.handle_exit_error('test-session-1', 7)
  lu.assertNotNil(r3)
  lu.assertTrue(string.find(r3, '3/3') ~= nil)
  lu.assertTrue(string.find(r3, '0 remaining') ~= nil)
  lu.assertEquals(retry.get_retry_count('test-session-1'), 3)

  -- Fourth attempt should return exhausted message (max_retries = 3)
  local r4 = retry.handle_exit_error('test-session-1', 7)
  lu.assertNotNil(r4)
  lu.assertTrue(string.find(r4, 'exhausted') ~= nil)
  lu.assertTrue(string.find(r4, 'Press r to retry') ~= nil)
end

function TestRetry:test_handle_exit_error_hint_format()
  -- Verify hint message format for first retry
  local result = retry.handle_exit_error('test-session-1', 7)
  lu.assertNotNil(result)
  -- Should contain "Auto-retry X/Y (Z remaining)."
  lu.assertTrue(string.find(result, 'Auto%-retry %d+/%d+') ~= nil)
  lu.assertTrue(string.find(result, '%d+ remaining') ~= nil)
end

-- ─── reset_retry_count ─────────────────────────────────────────

function TestRetry:test_reset_retry_count()
  -- Schedule a retry
  retry.handle_exit_error('test-session-1', 7)
  lu.assertTrue(retry.is_retrying('test-session-1'))
  lu.assertEquals(retry.get_retry_count('test-session-1'), 1)

  -- Reset
  retry.reset_retry_count('test-session-1')
  lu.assertFalse(retry.is_retrying('test-session-1'))
  lu.assertEquals(retry.get_retry_count('test-session-1'), 0)
end

function TestRetry:test_reset_allows_retry_again()
  -- Exhaust retries
  retry.handle_exit_error('test-session-1', 7)
  retry.handle_exit_error('test-session-1', 7)
  retry.handle_exit_error('test-session-1', 7)
  local exhausted = retry.handle_exit_error('test-session-1', 7)
  lu.assertNotNil(exhausted)
  lu.assertTrue(string.find(exhausted, 'exhausted') ~= nil)

  -- Reset and retry should work again
  retry.reset_retry_count('test-session-1')
  local result = retry.handle_exit_error('test-session-1', 7)
  lu.assertNotNil(result)
  lu.assertTrue(string.find(result, '1/3') ~= nil)
  lu.assertEquals(retry.get_retry_count('test-session-1'), 1)
end

-- ─── per-session independence ──────────────────────────────────

function TestRetry:test_per_session_independence()
  -- Session 1 gets 2 retries
  retry.handle_exit_error('test-session-1', 7)
  retry.handle_exit_error('test-session-1', 7)
  lu.assertEquals(retry.get_retry_count('test-session-1'), 2)

  -- Session 2 should be independent
  lu.assertEquals(retry.get_retry_count('test-session-2'), 0)
  local result = retry.handle_exit_error('test-session-2', 7)
  lu.assertNotNil(result)
  lu.assertTrue(string.find(result, '1/3') ~= nil)
  lu.assertEquals(retry.get_retry_count('test-session-2'), 1)
  lu.assertEquals(retry.get_retry_count('test-session-1'), 2)
end

function TestRetry:test_reset_on_success_allows_full_retries_next_time()
  -- Simulate: request fails 2 times, then succeeds
  retry.handle_exit_error('test-session-1', 7)
  retry.handle_exit_error('test-session-1', 7)
  lu.assertEquals(retry.get_retry_count('test-session-1'), 2)

  -- Simulate success: on_progress_done calls reset_retry_count
  retry.reset_retry_count('test-session-1')
  lu.assertEquals(retry.get_retry_count('test-session-1'), 0)

  -- Next request should get full retry budget (3 retries)
  local r1 = retry.handle_exit_error('test-session-1', 7)
  lu.assertNotNil(r1)
  lu.assertTrue(string.find(r1, '1/3') ~= nil)

  local r2 = retry.handle_exit_error('test-session-1', 7)
  lu.assertNotNil(r2)
  lu.assertTrue(string.find(r2, '2/3') ~= nil)

  local r3 = retry.handle_exit_error('test-session-1', 7)
  lu.assertNotNil(r3)
  lu.assertTrue(string.find(r3, '3/3') ~= nil)

  local r4 = retry.handle_exit_error('test-session-1', 7)
  lu.assertNotNil(r4)
  lu.assertTrue(string.find(r4, 'exhausted') ~= nil)
end

-- ─── cancel_retry ──────────────────────────────────────────────

function TestRetry:test_cancel_retry()
  retry.handle_exit_error('test-session-1', 7)
  lu.assertTrue(retry.is_retrying('test-session-1'))

  retry.cancel_retry('test-session-1')
  lu.assertFalse(retry.is_retrying('test-session-1'))
  lu.assertEquals(retry.get_retry_count('test-session-1'), 0)
end

-- ─── config integration ────────────────────────────────────────

function TestRetry:test_config_max_retries()
  -- Test with custom max_retries
  config.config.retry = { max_retries = 2, retry_delay = 2000 }

  local r1 = retry.handle_exit_error('test-session-1', 7)
  lu.assertNotNil(r1)
  lu.assertTrue(string.find(r1, '1/2') ~= nil)
  lu.assertEquals(retry.get_retry_count('test-session-1'), 1)

  local r2 = retry.handle_exit_error('test-session-1', 7)
  lu.assertNotNil(r2)
  lu.assertTrue(string.find(r2, '2/2') ~= nil)
  lu.assertEquals(retry.get_retry_count('test-session-1'), 2)

  -- Third attempt should return exhausted message (max_retries = 2)
  local r3 = retry.handle_exit_error('test-session-1', 7)
  lu.assertNotNil(r3)
  lu.assertTrue(string.find(r3, 'exhausted') ~= nil)
  lu.assertTrue(string.find(r3, 'Press r to retry') ~= nil)

  -- Restore default config
  config.config.retry = { max_retries = 3, retry_delay = 2000 }
end

return TestRetry

