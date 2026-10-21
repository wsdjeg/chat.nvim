-- Coverage for lua/chat/tokens.lua (multi-token rotation + cooldown)
local lu = require('luaunit')
local config = require('chat.config')
local tokens = require('chat.tokens')

TestTokens = {}

function TestTokens:setUp()
  -- Isolate api_key config and rotation state (never touch real config)
  self.saved_api_key = config.config.api_key
  self.saved_cooldown = config.config.token_cooldown
  config.config.api_key = {
    multi = { 'key-1', 'key-2', 'key-3' },
    single = 'only-key',
    with_junk = { 'key-a', '', 'key-b' },
    empty = {},
  }
  config.config.token_cooldown = 30

  -- Fake monotonic clock (milliseconds)
  self.now = 100000
  self.saved_clock = tokens._clock
  tokens._clock = function()
    return self.now
  end

  tokens.reset()
end

function TestTokens:tearDown()
  config.config.api_key = self.saved_api_key
  config.config.token_cooldown = self.saved_cooldown
  tokens._clock = self.saved_clock
  tokens.reset()
end

------------------------------------------------------------------ normalize

function TestTokens:test_normalize_single_string()
  lu.assertEquals(tokens.normalize('single'), { 'only-key' })
end

function TestTokens:test_normalize_array_filters_empty_entries()
  lu.assertEquals(tokens.normalize('with_junk'), { 'key-a', 'key-b' })
end

function TestTokens:test_normalize_no_key()
  lu.assertNil(tokens.normalize('missing'))
end

function TestTokens:test_normalize_empty_array_has_no_usable_key()
  local keys = tokens.normalize('empty')
  lu.assertTrue(keys == nil or #keys == 0)
end

----------------------------------------------------------------- get_token

function TestTokens:test_get_token_wraps_around()
  lu.assertEquals(tokens.get_token('multi', 1), 'key-1')
  lu.assertEquals(tokens.get_token('multi', 2), 'key-2')
  lu.assertEquals(tokens.get_token('multi', 3), 'key-3')
  lu.assertEquals(tokens.get_token('multi', 4), 'key-1', 'index wraps to first')
  lu.assertEquals(tokens.get_token('multi', 7), 'key-1')
end

function TestTokens:test_get_token_single_key_any_index()
  lu.assertEquals(tokens.get_token('single', 1), 'only-key')
  lu.assertEquals(tokens.get_token('single', 5), 'only-key')
end

function TestTokens:test_get_token_missing()
  lu.assertNil(tokens.get_token('missing', 1))
  lu.assertNil(tokens.get_token('multi', 0))
end

--------------------------------------------------------------------- next

function TestTokens:test_next_rotates_round_robin()
  lu.assertEquals(tokens.next('multi'), 'key-1')
  lu.assertEquals(tokens.next('multi'), 'key-2')
  lu.assertEquals(tokens.next('multi'), 'key-3')
  lu.assertEquals(tokens.next('multi'), 'key-1', 'wraps back to the first key')
end

function TestTokens:test_next_returns_key_index()
  local _, idx = tokens.next('multi')
  lu.assertEquals(idx, 1)
  _, idx = tokens.next('multi')
  lu.assertEquals(idx, 2)
end

function TestTokens:test_next_single_key_always_same()
  -- Backward compatibility: old string configs keep using the same key
  lu.assertEquals(tokens.next('single'), 'only-key')
  lu.assertEquals(tokens.next('single'), 'only-key')
  lu.assertEquals(tokens.next('single'), 'only-key')
end

function TestTokens:test_next_no_key()
  lu.assertNil(tokens.next('missing'))
  lu.assertNil(tokens.next('empty'))
end

--------------------------------------------------------------------- fail

function TestTokens:test_fail_skips_key_until_cooldown_expires()
  tokens.next('multi') -- cursor on key-1
  tokens.fail('multi', 1)
  lu.assertEquals(tokens.next('multi'), 'key-2', 'limited key is skipped')
  lu.assertEquals(tokens.next('multi'), 'key-3')

  -- key-1 is cooling until now + 30s
  self.now = self.now + 29999
  lu.assertEquals(tokens.next('multi'), 'key-2', 'still cooling at 29.999s')

  self.now = self.now + 1
  lu.assertEquals(tokens.next('multi'), 'key-3')
  lu.assertEquals(tokens.next('multi'), 'key-1', 'key recovers after cooldown')
end

function TestTokens:test_fail_advances_cursor_to_next_key()
  tokens.next('multi') -- cursor on key-1
  tokens.fail('multi', 1)
  -- Cursor must be on key-2 now, not stuck on the failed key
  local key, idx = tokens.next('multi')
  lu.assertEquals(key, 'key-2')
  lu.assertEquals(idx, 2)
end

function TestTokens:test_fail_last_key_wraps_cursor()
  tokens.next('multi')
  tokens.next('multi')
  tokens.next('multi') -- cursor back on key-1
  tokens.fail('multi', 3)
  local key = tokens.next('multi')
  lu.assertEquals(key, 'key-1', 'cursor wraps after failing the last key')
end

function TestTokens:test_fail_all_cooling_down_falls_back_to_soonest()
  tokens.next('multi')
  self.now = 100000
  tokens.fail('multi', 1) -- recovers at 130000
  self.now = 101000
  tokens.fail('multi', 2) -- recovers at 131000
  self.now = 102000
  tokens.fail('multi', 3) -- recovers at 132000

  -- All keys are cooling: fall back to the soonest-expiring key instead of
  -- returning nil, so the request is still attempted
  self.now = 105000
  local key, idx = tokens.next('multi')
  lu.assertEquals(key, 'key-1', 'falls back to the soonest-expiring key')
  lu.assertEquals(idx, 1)
end

function TestTokens:test_single_key_fail_still_returns_key()
  -- One configured key that just failed: keep using it (old behavior)
  tokens.next('single')
  tokens.fail('single', 1)
  lu.assertEquals(tokens.next('single'), 'only-key')
end

function TestTokens:test_fail_unknown_provider_or_index()
  -- Must not crash
  tokens.fail('missing', 1)
  tokens.fail('multi', 0)
  tokens.fail('multi', 99)
end

-------------------------------------------------------------------- reset

function TestTokens:test_reset_provider()
  tokens.next('multi')
  tokens.fail('multi', 1)
  tokens.reset('multi')
  lu.assertEquals(tokens.next('multi'), 'key-1', 'state cleared for provider')
end

function TestTokens:test_reset_all()
  tokens.next('multi')
  tokens.fail('multi', 1)
  tokens.next('single')
  tokens.reset()
  lu.assertEquals(tokens.next('multi'), 'key-1')
  lu.assertEquals(tokens.next('single'), 'only-key')
end

------------------------------------------------------------ is_token_error

function TestTokens:test_is_token_error_numeric_codes()
  lu.assertTrue(tokens.is_token_error(429, 'rate limit'))
  lu.assertTrue(tokens.is_token_error('429', 'quota exceeded'))
  lu.assertTrue(tokens.is_token_error(500, 'oops'))
  lu.assertTrue(tokens.is_token_error(503, 'oops'))
  lu.assertTrue(tokens.is_token_error('502', 'bad gateway'))
end

function TestTokens:test_is_token_error_texts()
  lu.assertTrue(tokens.is_token_error('rate_limit_exceeded', 'Rate limit reached'))
  lu.assertTrue(tokens.is_token_error('RateLimitError', 'too fast'))
  lu.assertTrue(tokens.is_token_error('Throttling.RateQuota', 'Requests too frequent'))
  lu.assertTrue(tokens.is_token_error(nil, 'You exceeded your current quota'))
  lu.assertTrue(tokens.is_token_error(nil, 'Resource has been exhausted (e.g. check quota)'))
  lu.assertTrue(tokens.is_token_error('UNAVAILABLE', 'Service Unavailable'))
  lu.assertTrue(tokens.is_token_error('overloaded_error', 'Overloaded'))
  lu.assertTrue(tokens.is_token_error('server_error', 'Internal server error'))
  lu.assertTrue(tokens.is_token_error(nil, 'Too Many Requests'))
end

function TestTokens:test_is_token_error_negative_cases()
  -- Client errors and normal completions must NOT rotate the key
  lu.assertFalse(tokens.is_token_error(400, 'invalid request'))
  lu.assertFalse(tokens.is_token_error(401, 'invalid api key'))
  lu.assertFalse(tokens.is_token_error(403, 'permission denied'))
  lu.assertFalse(tokens.is_token_error('invalid_request_error', 'max tokens too large'))
  lu.assertFalse(tokens.is_token_error('length', 'max_tokens truncation'))
  lu.assertFalse(tokens.is_token_error('content_filter', 'content filtered'))
  lu.assertFalse(tokens.is_token_error(nil, nil))
  lu.assertFalse(tokens.is_token_error('404', 'model not found'))
end

function TestTokens:test_is_token_error_vim_nil_safe()
  lu.assertFalse(tokens.is_token_error(vim.NIL, vim.NIL))
  lu.assertTrue(tokens.is_token_error(vim.NIL, 'rate limit reached'))
end

------------------------------------------------------- bind / report_error

function TestTokens:test_report_error_cools_bound_key()
  tokens.bind(42, 'multi', 1)
  tokens.report_error(42, 429, 'rate limit reached')
  -- key-1 cooling: next() must skip to key-2
  local key = tokens.next('multi')
  lu.assertEquals(key, 'key-2')
end

function TestTokens:test_report_error_ignores_non_token_errors()
  tokens.bind(43, 'multi', 1)
  tokens.report_error(43, 400, 'invalid request body')
  lu.assertEquals(tokens.next('multi'), 'key-1', 'no cooldown for client errors')
end

function TestTokens:test_report_error_once_per_job()
  tokens.bind(44, 'multi', 1)
  self.now = 100000
  tokens.report_error(44, 429, 'rate limit reached')
  -- A duplicated error event for the same job (stream chunk + buffered
  -- body) must not extend the cooldown
  self.now = 110000
  tokens.report_error(44, 500, 'internal server error')

  -- First failure cooled key-1 until 130000 only
  self.now = 135000
  lu.assertEquals(tokens.next('multi'), 'key-2')
  lu.assertEquals(tokens.next('multi'), 'key-3')
  lu.assertEquals(tokens.next('multi'), 'key-1', 'cooldown not extended by the duplicate')
end

function TestTokens:test_report_error_unknown_job()
  -- Jobs without a binding (e.g. direct protocol tests) are ignored
  tokens.report_error(999, 429, 'rate limit reached')
  lu.assertEquals(tokens.next('multi'), 'key-1')
end

function TestTokens:test_unbind()
  tokens.bind(45, 'multi', 1)
  tokens.unbind(45)
  tokens.report_error(45, 429, 'rate limit reached')
  lu.assertEquals(tokens.next('multi'), 'key-1', 'unbound job cannot cool keys')
end

function TestTokens:test_bind_invalid_jobid_ignored()
  tokens.bind(0, 'multi', 1)
  tokens.bind(-1, 'multi', 1)
  tokens.report_error(0, 429, 'rate limit reached')
  lu.assertEquals(tokens.next('multi'), 'key-1')
end

-------------------------------------------------------------- config wiring

function TestTokens:test_token_cooldown_config_respected()
  config.config.token_cooldown = 1 -- 1 second
  tokens.next('multi')
  tokens.fail('multi', 1)
  self.now = self.now + 1500
  lu.assertEquals(tokens.next('multi'), 'key-2')
  lu.assertEquals(tokens.next('multi'), 'key-3')
  lu.assertEquals(tokens.next('multi'), 'key-1', '1s cooldown already expired')
end

function TestTokens:test_token_cooldown_invalid_falls_back_to_default()
  config.config.token_cooldown = 'bogus'
  tokens.next('multi')
  tokens.fail('multi', 1)
  -- Default 30s cooldown
  self.now = self.now + 29999
  lu.assertEquals(tokens.next('multi'), 'key-2', 'still cooling at 29.999s')
  self.now = self.now + 1
  lu.assertEquals(tokens.next('multi'), 'key-3')
  lu.assertEquals(tokens.next('multi'), 'key-1')
end

return TestTokens

