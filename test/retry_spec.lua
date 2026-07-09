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
  lu.assertFalse(result)
  lu.assertFalse(retry.is_retrying('test-session-1'))
  lu.assertEquals(retry.get_retry_count('test-session-1'), 0)
end

function TestRetry:test_handle_exit_error_retryable()
  -- Code 7 (connection failure) should trigger retry
  local result = retry.handle_exit_error('test-session-1', 7)
  lu.assertTrue(result)
  lu.assertTrue(retry.is_retrying('test-session-1'))
  lu.assertEquals(retry.get_retry_count('test-session-1'), 1)
end

function TestRetry:test_handle_exit_error_timeout()
  -- Code 28 (timeout) should trigger retry
  local result = retry.handle_exit_error('test-session-1', 28)
  lu.assertTrue(result)
  lu.assertTrue(retry.is_retrying('test-session-1'))
  lu.assertEquals(retry.get_retry_count('test-session-1'), 1)
end

function TestRetry:test_handle_exit_error_multiple_retries()
  -- First retry
  lu.assertTrue(retry.handle_exit_error('test-session-1', 7))
  lu.assertEquals(retry.get_retry_count('test-session-1'), 1)

  -- Second retry
  lu.assertTrue(retry.handle_exit_error('test-session-1', 7))
  lu.assertEquals(retry.get_retry_count('test-session-1'), 2)

  -- Third retry
  lu.assertTrue(retry.handle_exit_error('test-session-1', 7))
  lu.assertEquals(retry.get_retry_count('test-session-1'), 3)

  -- Fourth attempt should fail (max_retries = 3)
  lu.assertFalse(retry.handle_exit_error('test-session-1', 7))
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
  lu.assertFalse(retry.handle_exit_error('test-session-1', 7))

  -- Reset and retry should work again
  retry.reset_retry_count('test-session-1')
  lu.assertTrue(retry.handle_exit_error('test-session-1', 7))
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
  lu.assertTrue(retry.handle_exit_error('test-session-2', 7))
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
  lu.assertTrue(retry.handle_exit_error('test-session-1', 7))
  lu.assertTrue(retry.handle_exit_error('test-session-1', 7))
  lu.assertTrue(retry.handle_exit_error('test-session-1', 7))
  lu.assertFalse(retry.handle_exit_error('test-session-1', 7))
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

  lu.assertTrue(retry.handle_exit_error('test-session-1', 7))
  lu.assertEquals(retry.get_retry_count('test-session-1'), 1)

  lu.assertTrue(retry.handle_exit_error('test-session-1', 7))
  lu.assertEquals(retry.get_retry_count('test-session-1'), 2)

  -- Third attempt should fail (max_retries = 2)
  lu.assertFalse(retry.handle_exit_error('test-session-1', 7))

  -- Restore default config
  config.config.retry = { max_retries = 3, retry_delay = 2000 }
end

return TestRetry

