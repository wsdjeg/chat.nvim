-- test/continue_spec.lua
-- Coverage for lua/chat/sessions/continue.lua: auto-continuation budget and
-- the request path (truncated assistant message stays last, no synthetic
-- user message).
local lu = require('luaunit')

local continue = require('chat.sessions.continue')
local config = require('chat.config')

local real_protocol = package.loaded['chat.protocol']
local real_messages = package.loaded['chat.sessions.messages']
local real_retry = package.loaded['chat.sessions.retry']

local captured = {}

local function mock_modules()
  captured = { request = {}, retry_reset = 0 }

  package.loaded['chat.protocol'] = {
    request = function(opt)
      table.insert(captured.request, opt)
      return 42
    end,
  }
  package.loaded['chat.sessions.messages'] = {
    get_request_messages = function()
      return {
        { role = 'user', content = 'hello' },
        { role = 'assistant', content = 'partial answer' },
      }
    end,
  }
  package.loaded['chat.sessions.retry'] = {
    reset_retry_count = function()
      captured.retry_reset = captured.retry_reset + 1
    end,
  }
end

local function restore_modules()
  package.loaded['chat.protocol'] = real_protocol
  package.loaded['chat.sessions.messages'] = real_messages
  package.loaded['chat.sessions.retry'] = real_retry
end

TestContinue = {}

function TestContinue:setUp()
  config.config.continuation = {
    enable = true,
    max_continuations = 3,
  }
  continue.reset('sess-1')
  continue.reset('sess-2')
  mock_modules()
end

function TestContinue:tearDown()
  restore_modules()
  continue.reset('sess-1')
  continue.reset('sess-2')
  config.config.continuation = {
    enable = true,
    max_continuations = 3,
  }
end

-- ─── state API ────────────────────────────────────────────────

function TestContinue:test_get_count_initial_zero()
  lu.assertEquals(continue.get_count('sess-1'), 0)
  lu.assertEquals(continue.get_count('unknown'), 0)
end

function TestContinue:test_pending_message_lifecycle()
  lu.assertNil(continue.get_pending('sess-1'))

  local msg = { role = 'assistant', content = 'x' }
  continue.set_pending('sess-1', msg)
  lu.assertEquals(continue.get_pending('sess-1'), msg)

  continue.reset('sess-1')
  lu.assertNil(continue.get_pending('sess-1'))
end

-- ─── request path ─────────────────────────────────────────────

function TestContinue:test_continue_sends_request_as_is()
  local jobid = continue.continue('sess-1')

  lu.assertEquals(jobid, 42)
  lu.assertEquals(#captured.request, 1)
  lu.assertEquals(captured.request[1].session, 'sess-1')

  -- Messages are passed through unchanged: the truncated assistant message is
  -- the last entry and no synthetic user message is appended.
  lu.assertEquals(#captured.request[1].messages, 2)
  lu.assertEquals(captured.request[1].messages[1].role, 'user')
  lu.assertEquals(captured.request[1].messages[2].role, 'assistant')

  -- A continuation is a fresh request, so connection retries restart.
  lu.assertEquals(captured.retry_reset, 1)
  lu.assertEquals(continue.get_count('sess-1'), 1)
end

function TestContinue:test_continue_increments_budget()
  continue.continue('sess-1')
  continue.continue('sess-1')
  lu.assertEquals(continue.get_count('sess-1'), 2)
  lu.assertEquals(#captured.request, 2)
end

function TestContinue:test_continue_limit_reached()
  config.config.continuation.max_continuations = 2

  lu.assertEquals(continue.continue('sess-1'), 42)
  lu.assertEquals(continue.continue('sess-1'), 42)

  local jobid, hint = continue.continue('sess-1')
  lu.assertNil(jobid)
  lu.assertNotNil(hint)
  lu.assertStrContains(hint, 'limit reached')
  lu.assertStrContains(hint, '2')

  -- No third request was issued.
  lu.assertEquals(#captured.request, 2)
  -- Budget resets after exhaustion so the next turn starts fresh.
  lu.assertEquals(continue.get_count('sess-1'), 0)
end

function TestContinue:test_continue_disabled()
  config.config.continuation.enable = false

  local jobid, hint = continue.continue('sess-1')
  lu.assertNil(jobid)
  lu.assertNil(hint)
  lu.assertEquals(#captured.request, 0)
  lu.assertEquals(continue.get_count('sess-1'), 0)
end

function TestContinue:test_custom_max_continuations()
  config.config.continuation.max_continuations = 1

  lu.assertEquals(continue.continue('sess-1'), 42)
  local jobid, hint = continue.continue('sess-1')
  lu.assertNil(jobid)
  lu.assertStrContains(hint, 'limit reached')
  lu.assertStrContains(hint, '1')
end

function TestContinue:test_per_session_independence()
  continue.continue('sess-1')
  continue.continue('sess-1')
  lu.assertEquals(continue.get_count('sess-1'), 2)
  lu.assertEquals(continue.get_count('sess-2'), 0)
end

return TestContinue
