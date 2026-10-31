-- test/context_cache_spec.lua
-- Volatile content must never sit in front of cached content.
--
-- The context-window notice embeds per-request numbers (total messages,
-- window bounds), so its text changes on every request once truncation has
-- fired. It used to be inserted right after the system messages, which meant
-- the provider's prefix cache was invalidated from message #2 onward on each
-- request; the interim "right before the newest user message" placement
-- still poisoned the head whenever the window started at that user message
-- (a single-turn window). It now is the very last request message: the
-- invalidation stays confined to the suffix. Flows that inspect the last
-- request message use context.strip_trailing_notice() first.

local lu = require('luaunit')
local context = require('chat.context')
local config = require('chat.config')
local sessions = require('chat.sessions')

TestContextNoticePlacement = {}

function TestContextNoticePlacement:setUp()
  self.tmp = vim.fn.tempname() .. '_ctxcache/'
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

function TestContextNoticePlacement:tearDown()
  if self.tmp and vim.fn.isdirectory(self.tmp) == 1 then
    vim.fn.delete(self.tmp, 'rf')
  end
end

local function find_notice(list)
  for i, m in ipairs(list) do
    if
      m.role == 'system'
      and type(m.content) == 'string'
      and m.content:find('[Context Window Notice]', 1, true)
    then
      return i
    end
  end
  return nil
end

local function last_index_of_role(list, role)
  for i = #list, 1, -1 do
    if list[i].role == role then
      return i
    end
  end
  return nil
end

local function make_notice()
  return {
    role = 'system',
    content = context._generate_context_notice(100, 40, 10, 60),
  }
end

--------------------------------------------------------------------
-- is_context_notice / strip_trailing_notice
--------------------------------------------------------------------

function TestContextNoticePlacement:test_is_context_notice()
  lu.assertTrue(context.is_context_notice(make_notice()))
  lu.assertFalse(context.is_context_notice({
    role = 'system',
    content = 'AGENTS.md persona',
  }))
  lu.assertFalse(context.is_context_notice({
    role = 'user',
    content = '[Context Window Notice] spoofed in a user message',
  }))
  lu.assertFalse(context.is_context_notice(nil))
end

function TestContextNoticePlacement:test_strip_removes_trailing_notice()
  local msgs = {
    { role = 'user', content = 'a' },
    { role = 'assistant', content = 'b' },
    make_notice(),
  }
  local stripped = context.strip_trailing_notice(msgs)
  lu.assertEquals(#stripped, 2)
  lu.assertEquals(stripped[#stripped].role, 'assistant')
  -- the original list is not mutated
  lu.assertEquals(#msgs, 3)
end

function TestContextNoticePlacement:test_strip_returns_same_list_without_notice()
  local msgs = {
    { role = 'user', content = 'a' },
    { role = 'assistant', content = 'b' },
  }
  lu.assertEquals(context.strip_trailing_notice(msgs), msgs)
end

function TestContextNoticePlacement:test_strip_empty_and_nil()
  lu.assertNil(context.strip_trailing_notice(nil))
  lu.assertEquals(#context.strip_trailing_notice({}), 0)
end

function TestContextNoticePlacement:test_strip_leaves_mid_list_notice_alone()
  -- only the tail entry can be the current notice: an older one stuck in
  -- the middle must not be removed
  local msgs = {
    { role = 'user', content = 'a' },
    make_notice(),
    { role = 'assistant', content = 'b' },
  }
  local stripped = context.strip_trailing_notice(msgs)
  lu.assertEquals(#stripped, 3)
  lu.assertNotNil(find_notice(stripped))
end

--------------------------------------------------------------------
-- truncate_messages placement
--------------------------------------------------------------------

function TestContextNoticePlacement:test_truncate_keeps_notice_out_of_system_block()
  local msgs = {
    { role = 'system', content = 'AGENTS' },
    { role = 'system', content = 'PROFILE' },
  }
  for i = 1, 30 do
    table.insert(msgs, { role = i % 2 == 0 and 'assistant' or 'user', content = 'm' .. i })
  end

  local result, truncated = context.truncate_messages(msgs, {
    trigger_threshold = 10,
    keep_recent = 6,
  })
  lu.assertTrue(truncated)
  lu.assertEquals(result[1].content, 'AGENTS')
  lu.assertEquals(result[2].content, 'PROFILE')

  local notice = find_notice(result)
  lu.assertNotNil(notice, 'notice emitted')
  lu.assertEquals(notice, #result, 'notice is the very last entry')
  lu.assertNotEquals(result[notice - 1].role, 'system')
  lu.assertEquals(result[1].role, 'system')
  lu.assertEquals(result[2].role, 'system')
  lu.assertEquals(result[3].role, 'user')
end

function TestContextNoticePlacement:test_truncate_notice_is_last()
  local msgs = {}
  for i = 1, 40 do
    table.insert(msgs, { role = 'user', content = 'm' .. i })
  end

  local result = context.truncate_messages(msgs, {
    trigger_threshold = 10,
    keep_recent = 5,
  })
  local notice = find_notice(result)
  lu.assertNotNil(notice)
  lu.assertEquals(notice, #result, 'notice is the very last entry')
  lu.assertEquals(result[#result - 1].role, 'user')
end

--------------------------------------------------------------------
-- get_request_messages integration
--------------------------------------------------------------------

function TestContextNoticePlacement:test_request_messages_notice_is_at_tail()
  local sid = sessions.new()
  sessions.set_session_prompt(sid, 'You are terse.')
  for i = 1, 30 do
    sessions.append_message(sid, {
      role = i % 2 == 0 and 'assistant' or 'user',
      content = 'm' .. i,
      created = os.time(),
    })
  end

  local request = sessions.get_request_messages(sid)
  lu.assertEquals(request[1].role, 'system')
  lu.assertEquals(request[1].content, 'You are terse.')

  local notice = find_notice(request)
  lu.assertNotNil(notice, 'truncation fired and notice emitted')
  lu.assertTrue(notice > 1, 'notice is not the second message anymore')
  lu.assertEquals(notice, #request, 'notice is the very last entry')
  -- the newest turn sits before the notice
  lu.assertTrue(notice > last_index_of_role(request, 'user'))
end

function TestContextNoticePlacement:test_request_messages_notice_trails_tool_result()
  -- send_tool_results() strips the trailing notice and re-sends when the
  -- real last request message is a tool result: the notice must never
  -- displace it from the flow's point of view.
  local sid = sessions.new()
  sessions.set_session_prompt(sid, 'sys')
  for i = 1, 28 do
    sessions.append_message(sid, {
      role = i % 2 == 0 and 'assistant' or 'user',
      content = 'm' .. i,
      created = os.time(),
    })
  end
  sessions.append_message(sid, {
    role = 'assistant',
    tool_calls = {
      {
        id = 'call_1',
        type = 'function',
        ['function'] = { name = 'read_file', arguments = '{}' },
      },
    },
    created = os.time(),
  })
  sessions.append_message(sid, {
    role = 'tool',
    content = 'file body',
    tool_call_id = 'call_1',
    created = os.time(),
  })

  local request = sessions.get_request_messages(sid)
  lu.assertNotNil(find_notice(request), 'notice emitted')
  local stripped = context.strip_trailing_notice(request)
  lu.assertEquals(stripped[#stripped].role, 'tool', 'tool result stays the last real entry')
  lu.assertEquals(stripped[#stripped].content, 'file body')
end

function TestContextNoticePlacement:test_request_messages_notice_trails_assistant()
  -- auto-continue resends the truncated assistant message as the final
  -- entry after stripping the notice (see chat.sessions.continue)
  local sid = sessions.new()
  sessions.set_session_prompt(sid, 'sys')
  for i = 1, 30 do
    sessions.append_message(sid, {
      role = i % 2 == 0 and 'assistant' or 'user',
      content = 'm' .. i,
      created = os.time(),
    })
  end
  sessions.append_message(sid, {
    role = 'assistant',
    content = 'partial answer',
    created = os.time(),
  })

  local request = sessions.get_request_messages(sid)
  local notice = find_notice(request)
  lu.assertNotNil(notice, 'notice emitted')
  lu.assertEquals(notice, #request, 'notice is the very last entry')

  local stripped = context.strip_trailing_notice(request)
  lu.assertEquals(stripped[#stripped].role, 'assistant')
  lu.assertEquals(stripped[#stripped].content, 'partial answer')
end

function TestContextNoticePlacement:test_system_block_stable_when_history_grows()
  local sid = sessions.new()
  sessions.set_session_prompt(sid, 'stable prompt')
  for i = 1, 30 do
    sessions.append_message(sid, {
      role = i % 2 == 0 and 'assistant' or 'user',
      content = 'm' .. i,
      created = os.time(),
    })
  end

  local first = sessions.get_request_messages(sid)
  sessions.append_message(sid, {
    role = 'assistant',
    content = 'another reply',
    created = os.time(),
  })
  local second = sessions.get_request_messages(sid)

  -- everything before the first non-system message is the cached prefix:
  -- it must be byte-identical across requests, no volatile counters in it
  local function system_block(list)
    local block = {}
    for _, m in ipairs(list) do
      if m.role ~= 'system' then
        break
      end
      table.insert(block, m.content)
    end
    return table.concat(block, '\n---\n')
  end

  lu.assertEquals(system_block(first), system_block(second))
  lu.assertStrContains(system_block(first), 'stable prompt')
  lu.assertNil(system_block(first):find('Context Window Notice', 1, true))
end

function TestContextNoticePlacement:test_prefix_stays_stable_across_rounds()
  -- The cache payoff: with the notice at the tail, every message the
  -- previous request sent stays byte-identical in the next one; only the
  -- notice and freshly appended rounds differ. Mirrors a single-turn
  -- window (one user message followed by assistant/tool rounds): the
  -- snap-back always finds the same user message, so the window front
  -- cannot slide and the request grows purely by append.
  local sid = sessions.new()
  sessions.set_session_prompt(sid, 'stable prompt')
  sessions.append_message(sid, {
    role = 'user',
    content = 'the question',
    created = os.time(),
  })
  for i = 1, 14 do
    sessions.append_message(sid, {
      role = 'assistant',
      tool_calls = {
        {
          id = 'call_' .. i,
          type = 'function',
          ['function'] = { name = 'read_file', arguments = '{}' },
        },
      },
      created = os.time(),
    })
    sessions.append_message(sid, {
      role = 'tool',
      content = 'output ' .. i,
      tool_call_id = 'call_' .. i,
      created = os.time(),
    })
  end

  local first_raw = sessions.get_request_messages(sid)
  lu.assertEquals(find_notice(first_raw), #first_raw, 'notice trails the first round')

  sessions.append_message(sid, {
    role = 'assistant',
    tool_calls = {
      {
        id = 'call_15',
        type = 'function',
        ['function'] = { name = 'read_file', arguments = '{}' },
      },
    },
    created = os.time(),
  })
  sessions.append_message(sid, {
    role = 'tool',
    content = 'output 15',
    tool_call_id = 'call_15',
    created = os.time(),
  })
  local second_raw = sessions.get_request_messages(sid)
  lu.assertEquals(find_notice(second_raw), #second_raw, 'notice trails the second round')

  local first = context.strip_trailing_notice(first_raw)
  local second = context.strip_trailing_notice(second_raw)

  -- every entry of `first` must appear unchanged at the same position in
  -- `second` (pure append growth): this is what the provider prefix cache
  -- needs to hit
  lu.assertTrue(#second > #first, 'window grew')
  for i = 1, #first do
    lu.assertEquals(second[i].role, first[i].role, 'role stable at ' .. i)
    if type(first[i].content) == 'string' then
      lu.assertEquals(second[i].content, first[i].content, 'content stable at ' .. i)
    end
  end
end

return TestContextNoticePlacement

