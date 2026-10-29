-- test/cache_probe_spec.lua
-- Prefix-cache observability: fingerprint consecutive requests of a session
-- and report the first position where the cached prefix breaks (plus the
-- provider-reported hit ratio).

local lu = require('luaunit')
local probe = require('chat.sessions.cache_probe')
local config = require('chat.config')

TestCacheProbe = {}

function TestCacheProbe:setUp()
  self.tmp = vim.fn.tempname() .. '_cacheprobe/'
  vim.fn.mkdir(self.tmp, 'p')
  config.setup({
    storage_dir = self.tmp,
    memory = {
      enable = true,
      storage_dir = self.tmp .. 'memory/',
    },
    tools = {
      lazy = true,
      essential = { 'get_time' },
    },
    cache = { probe = true },
  })
  require('chat.sessions').set_cache_dir(self.tmp .. 'sessions/')
  probe.reset_all()
end

function TestCacheProbe:tearDown()
  probe.reset_all()
  require('chat.tools').clear_activated_tools('cache-probe-spec')
  if self.tmp and vim.fn.isdirectory(self.tmp) == 1 then
    vim.fn.delete(self.tmp, 'rf')
  end
end

--- Build a request message list: optional system prompt + alternating turns.
local function build(system, contents)
  local list = {}
  if system then
    table.insert(list, { role = 'system', content = system })
  end
  for i, c in ipairs(contents) do
    table.insert(list, {
      role = (i % 2 == 1) and 'user' or 'assistant',
      content = c,
    })
  end
  return list
end

local function fake_tools(names)
  local list = {}
  for _, name in ipairs(names) do
    table.insert(list, { type = 'function', ['function'] = { name = name } })
  end
  return list
end

--- One request = begin_request(messages) + record_tools(tools)
local function send(sid, messages, tools)
  probe.begin_request(sid, messages)
  probe.record_tools(sid, tools)
end

--------------------------------------------------------------------
-- hashing
--------------------------------------------------------------------

function TestCacheProbe:test_hash_string_is_stable_and_sensitive()
  lu.assertEquals(probe.hash_string('abc'), probe.hash_string('abc'))
  lu.assertNotEquals(probe.hash_string('abc'), probe.hash_string('abd'))
  lu.assertNotEquals(probe.hash_string('abc'), probe.hash_string('abcabc'))
  lu.assertEquals(probe.hash_string(nil), '0')
  lu.assertEquals(probe.hash_string(42), '0')
end

function TestCacheProbe:test_hash_message_ignores_reasoning_content()
  local base = { role = 'assistant', content = 'answer' }
  local with_reasoning = {
    role = 'assistant',
    content = 'answer',
    reasoning_content = 'thinking ...',
  }
  lu.assertEquals(
    probe.hash_message(base),
    probe.hash_message(with_reasoning),
    'reasoning_content is not resent by most providers: no phantom break'
  )
end

function TestCacheProbe:test_hash_message_covers_tool_calls()
  local a = {
    role = 'assistant',
    tool_calls = {
      { id = 'c1', ['function'] = { name = 'read_file', arguments = '{}' } },
    },
  }
  local b = vim.deepcopy(a)
  b.tool_calls[1]['function'].arguments = '{"path":"x"}'
  lu.assertNotEquals(probe.hash_message(a), probe.hash_message(b))
end

--------------------------------------------------------------------
-- divergence detection
--------------------------------------------------------------------

function TestCacheProbe:test_first_request_is_baseline()
  send('s1', build('sys', { 'hi' }), fake_tools({ 'a', 'find_tool' }))
  local stats = probe.stats('s1')
  lu.assertEquals(stats.requests, 1)
  lu.assertEquals(stats.appends, 0)
  lu.assertEquals(stats.breaks, 0)
  lu.assertNil(stats.last_reason)
end

function TestCacheProbe:test_appending_messages_keeps_prefix()
  local sid = 's-append'
  send(sid, build('sys', { 'hi' }), fake_tools({ 'a' }))
  send(sid, build('sys', { 'hi', 'hello' }), fake_tools({ 'a' }))
  send(sid, build('sys', { 'hi', 'hello', 'again' }), fake_tools({ 'a' }))

  local stats = probe.stats(sid)
  lu.assertEquals(stats.requests, 3)
  lu.assertEquals(stats.appends, 2)
  lu.assertEquals(stats.breaks, 0)
  lu.assertEquals(stats.breaks_per_request, 0)
end

function TestCacheProbe:test_tools_change_breaks_prefix()
  local sid = 's-tools'
  send(sid, build('sys', { 'hi' }), fake_tools({ 'a', 'find_tool' }))
  send(sid, build('sys', { 'hi' }), fake_tools({ 'a', 'b', 'find_tool' }))

  local stats = probe.stats(sid)
  lu.assertEquals(stats.breaks, 1)
  lu.assertEquals(stats.last_reason, 'tools')
end

function TestCacheProbe:test_tool_order_change_breaks_prefix()
  local sid = 's-tools-order'
  send(sid, build('sys', { 'hi' }), fake_tools({ 'a', 'b' }))
  send(sid, build('sys', { 'hi' }), fake_tools({ 'b', 'a' }))

  lu.assertEquals(probe.stats(sid).last_reason, 'tools')
end

function TestCacheProbe:test_system_change_breaks_prefix()
  local sid = 's-system'
  send(sid, build('sys v1', { 'hi' }), fake_tools({ 'a' }))
  send(sid, build('sys v2', { 'hi' }), fake_tools({ 'a' }))

  lu.assertEquals(probe.stats(sid).last_reason, 'system')
end

function TestCacheProbe:test_message_rewrite_reports_break_index()
  local sid = 's-messages'
  local tools = fake_tools({ 'a' })
  send(sid, build('sys', { 'm1', 'm2', 'm3' }), tools)
  -- m2 (index 3 with the system prompt) was rewritten in place
  send(sid, build('sys', { 'm1', 'changed', 'm3' }), tools)

  local stats = probe.stats(sid)
  lu.assertEquals(stats.last_reason, 'messages')
  lu.assertEquals(stats.last_break_index, 3)
  lu.assertEquals(stats.breaks, 1)
end

function TestCacheProbe:test_shorter_request_is_truncated()
  local sid = 's-truncated'
  local tools = fake_tools({ 'a' })
  send(sid, build('sys', { 'm1', 'm2', 'm3' }), tools)
  send(sid, build('sys', { 'm1' }), tools)

  lu.assertEquals(probe.stats(sid).last_reason, 'truncated')
end

function TestCacheProbe:test_missing_record_tools_still_counted()
  local sid = 's-no-tools'
  probe.begin_request(sid, build('sys', { 'hi' }))
  -- provider never asked for tools: the next request finalizes the pending one
  send(sid, build('sys', { 'hi', 'more' }), fake_tools({ 'a' }))

  local stats = probe.stats(sid)
  lu.assertEquals(stats.requests, 2)
  -- tools went from "unknown" to a real array: that counts as a divergence
  lu.assertEquals(stats.breaks, 1)
  lu.assertEquals(stats.last_reason, 'tools')
end

function TestCacheProbe:test_record_tools_without_request_is_ignored()
  probe.record_tools('s-orphan', fake_tools({ 'a' }))
  lu.assertEquals(probe.stats('s-orphan').requests, 0)
end

function TestCacheProbe:test_nil_session_is_ignored()
  probe.begin_request(nil, build('sys', { 'hi' }))
  probe.record_tools(nil, fake_tools({ 'a' }))
  probe.record_usage(nil, { prompt_tokens = 10 })
  lu.assertEquals(probe.stats('s1').requests, 0)
end

function TestCacheProbe:test_disabled_by_config()
  config.setup({ cache = { probe = false } })
  send('s-off', build('sys', { 'hi' }), fake_tools({ 'a' }))
  lu.assertEquals(probe.stats('s-off').requests, 0)
  lu.assertFalse(probe.enabled())

  config.setup({ cache = { probe = true } })
  send('s-on', build('sys', { 'hi' }), fake_tools({ 'a' }))
  lu.assertEquals(probe.stats('s-on').requests, 1)
end

--------------------------------------------------------------------
-- usage / hit ratio
--------------------------------------------------------------------

function TestCacheProbe:test_usage_openai_shape()
  probe.record_usage('s-usage', {
    prompt_tokens = 1000,
    completion_tokens = 10,
    prompt_tokens_details = { cached_tokens = 800 },
  })
  local stats = probe.stats('s-usage')
  lu.assertEquals(stats.prompt_tokens, 1000)
  lu.assertEquals(stats.cached_tokens, 800)
  lu.assertAlmostEquals(stats.hit_ratio, 0.8, 0.0001)
end

function TestCacheProbe:test_usage_anthropic_and_deepseek_shapes()
  probe.record_usage('s-anth', {
    prompt_tokens = 100,
    cache_read_input_tokens = 50,
  })
  probe.record_usage('s-ds', {
    prompt_tokens = 200,
    prompt_cache_hit_tokens = 150,
  })
  lu.assertEquals(probe.stats('s-anth').cached_tokens, 50)
  lu.assertEquals(probe.stats('s-ds').cached_tokens, 150)
end

function TestCacheProbe:test_usage_without_cache_reporting()
  probe.record_usage('s-nocache', { prompt_tokens = 500 })
  local stats = probe.stats('s-nocache')
  lu.assertEquals(stats.cached_tokens, 0)
  lu.assertEquals(stats.hit_ratio, 0)
end

function TestCacheProbe:test_usage_non_table_is_ignored()
  probe.record_usage('s-bad', nil)
  probe.record_usage('s-bad', vim.NIL)
  probe.record_usage('s-bad', 'nope')
  lu.assertEquals(probe.stats('s-bad').prompt_tokens, 0)
end

--------------------------------------------------------------------
-- reset / empty stats
--------------------------------------------------------------------

function TestCacheProbe:test_stats_for_unknown_session()
  local stats = probe.stats('nope')
  lu.assertEquals(stats.requests, 0)
  lu.assertEquals(stats.breaks_per_request, 0)
  lu.assertEquals(stats.hit_ratio, 0)
end

function TestCacheProbe:test_reset_clears_bookkeeping()
  send('s-reset', build('sys', { 'hi' }), fake_tools({ 'a' }))
  lu.assertEquals(probe.stats('s-reset').requests, 1)
  probe.reset('s-reset')
  lu.assertEquals(probe.stats('s-reset').requests, 0)
  -- the next request is a baseline again
  send('s-reset', build('sys', { 'hi', 'more' }), fake_tools({ 'a', 'b' }))
  lu.assertEquals(probe.stats('s-reset').breaks, 0)
end

--------------------------------------------------------------------
-- end-to-end with real sessions and request_tools ordering
--------------------------------------------------------------------

function TestCacheProbe:test_real_request_flow_appends_then_breaks_on_activation()
  local sessions = require('chat.sessions')
  local tools = require('chat.tools')
  local sid = sessions.new()
  sessions.set_session_prompt(sid, 'you are terse')
  sessions.append_message(sid, {
    role = 'user',
    content = 'hello',
    created = os.time(),
  })

  local function request()
    probe.begin_request(sid, sessions.get_request_messages(sid))
    return tools.request_tools(sid)
  end

  request()
  sessions.append_message(sid, {
    role = 'assistant',
    content = 'hi there',
    created = os.time(),
  })
  request()

  local stats = sessions.cache_stats(sid)
  lu.assertEquals(stats.requests, 2)
  lu.assertEquals(stats.appends, 1, 'adding a message keeps the prefix')
  lu.assertEquals(stats.breaks, 0)

  -- activating a tool changes the tools array -> the prefix above it dies
  tools.activate_tool(sid, 'write_file')
  request()
  stats = sessions.cache_stats(sid)
  lu.assertEquals(stats.requests, 3)
  lu.assertEquals(stats.breaks, 1)
  lu.assertEquals(stats.last_reason, 'tools')

  sessions.reset_cache_stats(sid)
  lu.assertEquals(sessions.cache_stats(sid).requests, 0)
  tools.clear_activated_tools(sid)
end

return TestCacheProbe

