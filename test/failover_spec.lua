-- Coverage for lua/chat/sessions/failover.lua
-- (transparent api-key rotation on quota / rate-limit / server errors)
local lu = require('luaunit')
local config = require('chat.config')
local tokens = require('chat.tokens')
local failover = require('chat.sessions.failover')

TestFailover = {}

function TestFailover:setUp()
  -- Isolate api_key config and rotation state (never touch real config)
  self.saved_api_key = config.config.api_key
  config.config.api_key = {
    multi = { 'key-1', 'key-2', 'key-3' },
    single = 'only-key',
    none = {},
  }

  tokens.reset()

  -- Never arm real timers in tests: capture them instead
  self.armed = {}
  failover._defer = function(fn, delay)
    table.insert(self.armed, { fn = fn, delay = delay })
    return { stop = function() end }
  end

  -- Neutral state for every test
  failover.cancel('s1')
  failover.cancel('s2')
end

function TestFailover:tearDown()
  config.config.api_key = self.saved_api_key
  failover._defer = function(fn, delay)
    return vim.defer_fn(fn, delay)
  end
  failover.cancel('s1')
  failover.cancel('s2')
  tokens.reset()
end

--------------------------------------------------------------- should()

function TestFailover:test_should_true_for_token_error_with_binding()
  tokens.bind(101, 'multi', 1)
  lu.assertTrue(failover.should(101, 's1', 429, 'rate limit reached', false))
end

function TestFailover:test_should_true_for_quota_error()
  tokens.bind(102, 'multi', 1)
  lu.assertTrue(
    failover.should(102, 's1', 429, '当前API Key已用完5小时总额度', false)
  )
end

function TestFailover:test_should_false_when_streamed()
  -- Output already visible: rotating would duplicate content
  tokens.bind(103, 'multi', 1)
  lu.assertFalse(failover.should(103, 's1', 429, 'rate limit reached', true))
end

function TestFailover:test_should_false_without_binding()
  lu.assertFalse(failover.should(104, 's1', 429, 'rate limit reached', false))
end

function TestFailover:test_should_false_non_token_error()
  -- Client errors (400/401), content filter, max_tokens: show the error
  tokens.bind(105, 'multi', 1)
  lu.assertFalse(failover.should(105, 's1', 400, 'invalid request', false))
end

function TestFailover:test_should_false_no_session()
  tokens.bind(106, 'multi', 1)
  lu.assertFalse(failover.should(106, nil, 429, 'rate limit reached', false))
end

function TestFailover:test_should_false_single_key_provider()
  -- With one key there is nowhere to rotate to
  tokens.bind(107, 'single', 1)
  lu.assertFalse(failover.should(107, 's1', 429, 'rate limit reached', false))
end

function TestFailover:test_should_false_empty_key_list()
  tokens.bind(108, 'none', 1)
  lu.assertFalse(failover.should(108, 's1', 429, 'rate limit reached', false))
end

------------------------------------------------------- mark / is_pending

function TestFailover:test_mark_is_pending_clear()
  lu.assertFalse(failover.is_pending(120))
  failover.mark(120, 's1')
  lu.assertTrue(failover.is_pending(120))
  failover.clear(120)
  lu.assertFalse(failover.is_pending(120))
end

---------------------------------------------------- mark / notice reason

function TestFailover:test_mark_with_error_info_stashes_reason()
  -- Called with code / msg while the binding is alive: the failed key is
  -- remembered for the UI notice
  tokens.bind(170, 'multi', 2)
  failover.mark(
    170,
    's1',
    'AccountQuotaExceeded',
    'You have exceeded the 5-hour usage quota'
  )
  local reason = failover.get_reason(170)
  lu.assertNotNil(reason)
  lu.assertEquals(reason.session, 's1')
  lu.assertEquals(reason.provider, 'multi')
  lu.assertEquals(reason.key_index, 2)
  lu.assertEquals(reason.class, 'quota')
end

function TestFailover:test_mark_without_binding_stashes_no_reason()
  failover.mark(171, 's1', 429, 'rate limit reached')
  lu.assertNil(failover.get_reason(171))
end

function TestFailover:test_mark_without_error_info_stashes_no_reason()
  -- Two-arg callers (tests, legacy call sites) keep working
  tokens.bind(172, 'multi', 1)
  failover.mark(172, 's1')
  lu.assertTrue(failover.is_pending(172))
  lu.assertNil(failover.get_reason(172))
end

function TestFailover:test_mark_non_token_error_stashes_no_reason()
  tokens.bind(173, 'multi', 1)
  failover.mark(173, 's1', 400, 'invalid request')
  lu.assertNil(failover.get_reason(173))
end

function TestFailover:test_consume_pops_reason()
  tokens.bind(174, 'multi', 1)
  failover.mark(174, 's1', 429, 'rate limit reached')
  lu.assertNotNil(failover.get_reason(174))
  failover.consume(174, 's1')
  lu.assertNil(failover.get_reason(174))
end

function TestFailover:test_consume_wrong_session_pops_reason()
  tokens.bind(175, 'multi', 1)
  failover.mark(175, 's1', 429, 'rate limit reached')
  lu.assertFalse(failover.consume(175, 's2'))
  lu.assertNil(failover.get_reason(175))
end

function TestFailover:test_clear_pops_reason()
  tokens.bind(176, 'multi', 1)
  failover.mark(176, 's1', 429, 'rate limit reached')
  failover.clear(176)
  lu.assertNil(failover.get_reason(176))
end

function TestFailover:test_cancel_pops_reason()
  tokens.bind(177, 'multi', 1)
  failover.mark(177, 's1', 429, 'rate limit reached')
  failover.cancel('s1')
  lu.assertNil(failover.get_reason(177))
end

function TestFailover:test_notice_text()
  lu.assertEquals(
    failover.notice_text({
      provider = 'volcengine_coding_plan',
      key_index = 1,
      class = 'quota',
    }),
    'API key #1 (volcengine_coding_plan) hit its quota, '
      .. 'retrying with the next api key...'
  )
  lu.assertEquals(
    failover.notice_text({ provider = 'multi', key_index = 2, class = 'rate_limit' }),
    'API key #2 (multi) hit a rate limit, retrying with the next api key...'
  )
  lu.assertEquals(
    failover.notice_text({ provider = 'multi', key_index = 3, class = 'server' }),
    'API key #3 (multi) hit a server error, retrying with the next api key...'
  )
end

--------------------------------------------------------------- consume()

function TestFailover:test_consume_schedules_rotation_and_counts_attempt()
  failover.mark(121, 's1')
  lu.assertTrue(failover.consume(121, 's1'))
  lu.assertEquals(failover.get_attempts('s1'), 1)
  lu.assertEquals(#self.armed, 1, 'one rotation timer armed')
  lu.assertEquals(self.armed[1].delay, 300)
  lu.assertFalse(failover.is_pending(121), 'mark consumed')
end

function TestFailover:test_consume_wrong_session_is_ignored()
  failover.mark(122, 's1')
  lu.assertFalse(failover.consume(122, 's2'))
  lu.assertTrue(failover.is_pending(122), 'mark kept for the right session')
  lu.assertEquals(failover.get_attempts('s2'), 0)
end

function TestFailover:test_consume_unknown_job_is_ignored()
  lu.assertFalse(failover.consume(123, 's1'))
  lu.assertEquals(#self.armed, 0)
end

---------------------------------------------------------------- budget

function TestFailover:test_budget_is_keys_minus_one()
  -- 3 keys -> at most 2 rotations per request chain
  tokens.bind(130, 'multi', 1)
  lu.assertTrue(failover.should(130, 's1', 429, 'rate limit reached', false))

  failover.mark(130, 's1')
  failover.consume(130, 's1')
  lu.assertEquals(failover.get_attempts('s1'), 1)

  tokens.bind(131, 'multi', 2)
  lu.assertTrue(failover.should(131, 's1', 429, 'rate limit reached', false))
  failover.mark(131, 's1')
  failover.consume(131, 's1')
  lu.assertEquals(failover.get_attempts('s1'), 2)

  tokens.bind(132, 'multi', 3)
  lu.assertFalse(
    failover.should(132, 's1', 429, 'rate limit reached', false),
    'budget exhausted: error is shown instead of rotating forever'
  )
end

function TestFailover:test_budget_is_per_session()
  tokens.bind(140, 'multi', 1)
  failover.mark(140, 's1')
  failover.consume(140, 's1')

  tokens.bind(141, 'multi', 2)
  lu.assertTrue(
    failover.should(141, 's2', 429, 'rate limit reached', false),
    'the other session has its own budget'
  )
end

function TestFailover:test_reset_restores_budget()
  tokens.bind(150, 'multi', 1)
  failover.mark(150, 's1')
  failover.consume(150, 's1')
  lu.assertEquals(failover.get_attempts('s1'), 1)

  failover.reset('s1')
  lu.assertEquals(failover.get_attempts('s1'), 0)

  tokens.bind(151, 'multi', 1)
  lu.assertTrue(failover.should(151, 's1', 429, 'rate limit reached', false))
end

---------------------------------------------------------------- cancel

function TestFailover:test_cancel_drops_pending_marks()
  failover.mark(160, 's1')
  failover.cancel('s1')
  lu.assertFalse(failover.is_pending(160))
end

function TestFailover:test_cancel_clears_budget()
  failover.mark(161, 's1')
  failover.consume(161, 's1')
  lu.assertEquals(failover.get_attempts('s1'), 1)

  failover.cancel('s1')
  lu.assertEquals(failover.get_attempts('s1'), 0)
  lu.assertFalse(failover.is_pending(161))
end

function TestFailover:test_cancel_only_touches_own_session()
  failover.mark(162, 's2')
  failover.cancel('s1')
  lu.assertTrue(failover.is_pending(162), 's2 marks survive an s1 cancel')
end

return TestFailover

