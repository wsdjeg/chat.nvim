-- test/context_cache_spec.lua
-- Volatile content must never sit in front of cached content.
--
-- The context-window notice embeds per-request numbers (total messages,
-- window bounds), so its text changes on every request once truncation has
-- fired. It used to be inserted right after the system messages, which meant
-- the provider's prefix cache was invalidated from message #2 onward on each
-- request. It now goes as late as possible: right before the newest user
-- message, and never after a trailing assistant message (auto-continue
-- resends the truncated assistant last).

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

--------------------------------------------------------------------
-- _notice_insert_index
--------------------------------------------------------------------

function TestContextNoticePlacement:test_insert_index_empty()
  lu.assertEquals(context._notice_insert_index({}), 1)
end

function TestContextNoticePlacement:test_insert_index_before_newest_user()
  local msgs = {
    { role = 'user', content = 'a' },
    { role = 'assistant', content = 'b' },
    { role = 'user', content = 'c' },
    { role = 'assistant', content = 'd' },
  }
  -- newest user is index 3 -> notice goes right before it
  lu.assertEquals(context._notice_insert_index(msgs), 3)
end

function TestContextNoticePlacement:test_insert_index_appends_after_trailing_user()
  local msgs = {
    { role = 'assistant', content = 'a' },
    { role = 'user', content = 'b' },
  }
  lu.assertEquals(context._notice_insert_index(msgs), 2)
end

function TestContextNoticePlacement:test_insert_index_before_user_that_started_a_tool_turn()
  local msgs = {
    { role = 'user', content = 'a' },
    { role = 'assistant', tool_calls = {} },
    { role = 'tool', content = 'r' },
  }
  -- the newest user message is the turn boundary: the notice goes there and
  -- the tool result stays last
  lu.assertEquals(context._notice_insert_index(msgs), 1)
end

function TestContextNoticePlacement:test_insert_index_appends_when_no_user_message()
  local msgs = {
    { role = 'assistant', tool_calls = {} },
    { role = 'tool', content = 'r' },
  }
  -- no user message in the kept window: append, the tool result stays last
  lu.assertEquals(context._notice_insert_index(msgs), 3)
end

function TestContextNoticePlacement:test_insert_index_never_after_trailing_assistant()
  local msgs = {
    { role = 'assistant', content = 'a' },
    { role = 'assistant', content = 'b' },
  }
  -- auto-continue resends this array: the notice must go before the
  -- trailing assistant, never after it
  lu.assertEquals(context._notice_insert_index(msgs), 2)
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
  lu.assertTrue(
    notice > 2,
    'notice must not be part of the leading system block'
  )
  -- a cached history message precedes the notice, so the system block really
  -- is untouched
  lu.assertNotEquals(result[notice - 1].role, 'system')
  lu.assertEquals(result[notice + 1].role, 'user')
end

function TestContextNoticePlacement:test_truncate_notice_precedes_newest_user()
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
  lu.assertEquals(result[notice + 1].role, 'user')
  lu.assertEquals(notice, #result - 1)
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
  -- the newest turn sits after the notice
  lu.assertNotNil(last_index_of_role(request, 'user'))
  lu.assertTrue(notice < last_index_of_role(request, 'user'))
end

function TestContextNoticePlacement:test_request_messages_keeps_trailing_tool()
  -- send_tool_results() only re-sends when the last request message is a
  -- tool result: the notice must never displace it
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
  lu.assertEquals(request[#request].role, 'tool', 'tool result stays last')
  lu.assertNotNil(find_notice(request), 'notice emitted')
end

function TestContextNoticePlacement:test_request_messages_keeps_trailing_assistant()
  -- auto-continue resends the truncated assistant message as the last entry
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
  lu.assertEquals(request[#request].role, 'assistant')
  lu.assertEquals(request[#request].content, 'partial answer')

  local notice = find_notice(request)
  lu.assertNotNil(notice)
  lu.assertTrue(notice < #request)
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

return TestContextNoticePlacement

