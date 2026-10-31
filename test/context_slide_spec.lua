-- test/context_slide_spec.lua
-- slide_step: the truncation cutoff advances in batches, so the front of
-- the kept window stays byte-identical between steps.
--
-- Without batching, cutoff = #messages - keep_recent moves on every
-- request. Each time it crosses a user message the window starts at a new
-- message, which invalidates the provider prefix cache from the very first
-- history message on (the probe logs this as reason=messages). With
-- slide_step > 1 the cutoff only advances once every slide_step messages,
-- so consecutive requests share a stable window front and only the tail
-- grows (reason=append).

local lu = require('luaunit')
local context = require('chat.context')
local config = require('chat.config')
local sessions = require('chat.sessions')

TestContextSlideStep = {}

function TestContextSlideStep:setUp()
  self.tmp = vim.fn.tempname() .. '_ctxslide/'
  vim.fn.mkdir(self.tmp, 'p')
  config.setup({
    storage_dir = self.tmp,
    memory = {
      enable = true,
      storage_dir = self.tmp .. 'memory/',
    },
    context = {
      enable = true,
      trigger_threshold = 20,
      keep_recent = 6,
    },
  })
  sessions.set_cache_dir(self.tmp .. 'sessions/')
end

function TestContextSlideStep:tearDown()
  if self.tmp and vim.fn.isdirectory(self.tmp) == 1 then
    vim.fn.delete(self.tmp, 'rf')
  end
end

--------------------------------------------------------------------
-- helpers
--------------------------------------------------------------------

-- All-user history: start_idx lands exactly on the cutoff, so the window
-- front is directly observable.
local function user_only(n)
  local msgs = {}
  for i = 1, n do
    msgs[#msgs + 1] = { role = 'user', content = 'm' .. i }
  end
  return msgs
end

-- Content of the first history message (system messages, including the
-- volatile context notice, are skipped).
local function first_history_content(result)
  for _, m in ipairs(result) do
    if m.role ~= 'system' then
      return m.content
    end
  end
  return nil
end

local function history_contents(result)
  local out = {}
  for _, m in ipairs(result) do
    if m.role ~= 'system' then
      out[#out + 1] = m.content
    end
  end
  return out
end

--------------------------------------------------------------------
-- unit tests: cutoff batching
--------------------------------------------------------------------

function TestContextSlideStep:test_batched_cutoff_freezes_window_front()
  local cfg = { trigger_threshold = 10, keep_recent = 4, slide_step = 6 }
  local msgs = user_only(30)

  -- raw cutoff = 26 -> floor(26/6)*6 = 24
  local first = context.truncate_messages(msgs, cfg)
  lu.assertEquals(first_history_content(first), 'm24')

  -- grow by less than a step: the front must not move and the previous
  -- window must remain a prefix of the new one (cache-friendly append)
  for i = 31, 33 do
    msgs[#msgs + 1] = { role = 'user', content = 'm' .. i }
  end
  local second = context.truncate_messages(msgs, cfg)
  lu.assertEquals(first_history_content(second), 'm24')

  local a, b = history_contents(first), history_contents(second)
  for i = 1, #a do
    lu.assertEquals(b[i], a[i], 'old window stays a prefix at index ' .. i)
  end
  -- window cap: keep_recent + slide_step
  lu.assertEquals(#b, 10)
end

function TestContextSlideStep:test_batched_cutoff_advances_after_step()
  local cfg = { trigger_threshold = 10, keep_recent = 4, slide_step = 6 }
  local msgs = user_only(34)

  -- raw cutoff = 30 -> crossed a step boundary, window restarts at m30
  local result, truncated = context.truncate_messages(msgs, cfg)
  lu.assertTrue(truncated)
  lu.assertEquals(first_history_content(result), 'm30')
  -- window shrinks back to the minimum: keep_recent + 1
  lu.assertEquals(#history_contents(result), 5)
end

function TestContextSlideStep:test_legacy_slide_without_step()
  local cfg = { trigger_threshold = 10, keep_recent = 4 }
  local msgs = user_only(30)

  -- legacy: cutoff = 26 exactly, then 27 after one more message
  local result = context.truncate_messages(msgs, cfg)
  lu.assertEquals(first_history_content(result), 'm26')

  msgs[#msgs + 1] = { role = 'user', content = 'm31' }
  result = context.truncate_messages(msgs, cfg)
  lu.assertEquals(first_history_content(result), 'm27')
end

function TestContextSlideStep:test_step_one_and_negative_keep_legacy()
  local msgs = user_only(30)
  local cfg = { trigger_threshold = 10, keep_recent = 4 }

  for _, step in ipairs({ 1, -5, 0 }) do
    cfg.slide_step = step
    local result = context.truncate_messages(msgs, cfg)
    lu.assertEquals(
      first_history_content(result),
      'm26',
      'slide_step=' .. tostring(step) .. ' must behave like legacy'
    )
  end
end

function TestContextSlideStep:test_first_truncation_delayed_below_step()
  local cfg = { trigger_threshold = 10, keep_recent = 4, slide_step = 40 }
  local msgs = user_only(30)

  -- raw cutoff 26 < 40: not a full step accumulated, keep the window
  local result, truncated = context.truncate_messages(msgs, cfg)
  lu.assertFalse(truncated)
  lu.assertEquals(#result, 30)

  -- raw cutoff reaches 40: window starts at m40
  for i = 31, 44 do
    msgs[#msgs + 1] = { role = 'user', content = 'm' .. i }
  end
  result, truncated = context.truncate_messages(msgs, cfg)
  lu.assertTrue(truncated)
  lu.assertEquals(first_history_content(result), 'm40')
end

function TestContextSlideStep:test_batched_front_lands_on_user_message()
  -- odd indices user, even assistant
  local msgs = {}
  for i = 1, 30 do
    msgs[#msgs + 1] = {
      role = i % 2 == 1 and 'user' or 'assistant',
      content = 'm' .. i,
    }
  end

  -- raw = 24 -> batched 20 (assistant) -> nearest user <= 20 is m19
  local batched = context.truncate_messages(msgs, {
    trigger_threshold = 10,
    keep_recent = 6,
    slide_step = 10,
  })
  lu.assertEquals(first_history_content(batched), 'm19')

  -- legacy cutoff 24 -> nearest user <= 24 is m23
  local legacy = context.truncate_messages(msgs, {
    trigger_threshold = 10,
    keep_recent = 6,
  })
  lu.assertEquals(first_history_content(legacy), 'm23')
end

--------------------------------------------------------------------
-- integration: config plumbed through get_request_messages
--------------------------------------------------------------------

function TestContextSlideStep:test_config_plumbs_into_request_messages()
  -- merge slide_step into the context set up in setUp (trigger=20, keep=6)
  config.setup({
    storage_dir = self.tmp,
    memory = {
      enable = true,
      storage_dir = self.tmp .. 'memory/',
    },
    context = { slide_step = 10 },
  })

  local sid = sessions.new()
  sessions.set_session_prompt(sid, 'sys')
  for i = 1, 30 do
    sessions.append_message(sid, {
      role = i % 2 == 1 and 'user' or 'assistant',
      content = 'm' .. i,
      created = os.time(),
    })
  end

  -- raw = 24 -> batched 20 -> window starts at m19
  local req = sessions.get_request_messages(sid)
  lu.assertEquals(first_history_content(req), 'm19')

  -- growing by less than a step keeps the front stable
  sessions.append_message(sid, {
    role = 'assistant',
    content = 'extra reply',
    created = os.time(),
  })
  sessions.append_message(sid, {
    role = 'user',
    content = 'next question',
    created = os.time(),
  })
  req = sessions.get_request_messages(sid)
  lu.assertEquals(first_history_content(req), 'm19')
end

return TestContextSlideStep

