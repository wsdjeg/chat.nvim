local lu = require('luaunit')
local integrations = require('chat.integrations')
local sessions = require('chat.sessions')
local windows = require('chat.windows')

local discord = require('chat.integrations.discord')

local saved = {}
local saved_sessions = {}
local function save()
  for _, m in ipairs({ 'set_session', 'send_message', 'current_session', 'send_typing', 'disconnect', 'connect' }) do
    saved[m] = discord[m]
  end
  saved.windows_current_session = windows.current_session
  for _, m in ipairs({ 'get', 'get_session_title', 'get_session_pin', 'is_in_progress', 'clear', 'get_session_provider', 'get_session_model', 'getcwd', 'exists' }) do
    saved_sessions[m] = sessions[m]
  end
end

local function stub()
  discord.set_session = function() end
  discord.send_message = function() end
  discord.current_session = function() return nil end
  discord.send_typing = nil
  discord.disconnect = function() end
  discord.connect = function() end
end

local function restore()
  for m, v in pairs(saved) do
    discord[m] = v
  end
  windows.current_session = saved.windows_current_session
  for m, v in pairs(saved_sessions) do
    sessions[m] = v
  end
end

local function capture_handler()
  local captured
  discord.connect = function(handler) captured = handler end
  integrations.on_message(function() end)
  return captured
end

local function stub_sessions(data)
  data = data or {}
  sessions.get = function() return data end
  sessions.get_session_title = function(id)
    local s = data[id]
    return s and s.title or ''
  end
  sessions.get_session_pin = function(id)
    local s = data[id]
    return s and s.pin or false
  end
  sessions.is_in_progress = function() return false end
  sessions.clear = function() end
  sessions.get_session_provider = function() return 'openai' end
  sessions.get_session_model = function() return 'gpt' end
  sessions.getcwd = function() return vim.fn.getcwd() end
  sessions.exists = function(id) return data[id] ~= nil end
end

TestIntegrationsInitExtra = {}

function TestIntegrationsInitExtra:setUp()
  save()
  stub()
  stub_sessions({})
end

function TestIntegrationsInitExtra:tearDown()
  restore()
end

function TestIntegrationsInitExtra:testListCommandEmpty()
  local handler = capture_handler()
  local sent
  discord.send_message = function(c) sent = c end
  handler({ content = '/list' })
  lu.assertStrContains(sent, 'Available sessions:')
  lu.assertStrContains(sent, 'No sessions available')
end

function TestIntegrationsInitExtra:testListCommandWithSessions()
  local data = {
    ['sess-b'] = { title = '', messages = { { role = 'user', content = 'first b', created = 200 } }, provider = 'p', model = 'm' },
    ['sess-a'] = { title = 'Titled A', messages = { { role = 'user', content = 'first a', created = 100 } }, provider = 'p', model = 'm' },
  }
  stub_sessions(data)
  local handler = capture_handler()
  local sent
  discord.send_message = function(c) sent = c end
  discord.current_session = function() return 'sess-a' end
  handler({ content = '/list' })
  lu.assertStrContains(sent, 'Available sessions:')
  lu.assertStrContains(sent, 'Titled A')
  lu.assertStrContains(sent, 'Total: 2')
end

function TestIntegrationsInitExtra:testListCommandWithFilter()
  local data = {
    ['sess-1'] = { title = 'Alpha', messages = { { role = 'user', content = 'hello', created = 1 } }, provider = 'p', model = 'm' },
    ['sess-2'] = { title = 'Beta', messages = { { role = 'user', content = 'world', created = 2 } }, provider = 'p', model = 'm' },
  }
  stub_sessions(data)
  local handler = capture_handler()
  local sent
  discord.send_message = function(c) sent = c end
  handler({ content = '/list Alpha' })
  lu.assertStrContains(sent, 'Sessions matching "Alpha":')
  lu.assertStrContains(sent, 'Alpha')
end

function TestIntegrationsInitExtra:testSessionCommandNoArgNoWindowSession()
  windows.current_session = function() return nil end
  local handler = capture_handler()
  local sent
  discord.send_message = function(c) sent = c end
  handler({ content = '/session' })
  lu.assertStrContains(sent, 'No window session')
end

function TestIntegrationsInitExtra:testSessionCommandNoArgWithWindowSession()
  windows.current_session = function() return 'sess-1' end
  stub_sessions({
    ['sess-1'] = { title = 'My Session', messages = {}, provider = 'p', model = 'm' },
  })
  local handler = capture_handler()
  local sent
  discord.send_message = function(c) sent = c end
  handler({ content = '/session' })
  lu.assertStrContains(sent, 'Session bound:')
end

function TestIntegrationsInitExtra:testSessionCommandByIndex()
  stub_sessions({
    ['sess-1'] = { title = 'One', messages = {}, provider = 'p', model = 'm' },
    ['sess-2'] = { title = 'Two', messages = {}, provider = 'p', model = 'm' },
  })
  local handler = capture_handler()
  -- first /list populates _session_list
  handler({ content = '/list' })
  local bound
  discord.set_session = function(sid) bound = sid end
  local sent
  discord.send_message = function(c) sent = c end
  handler({ content = '/session 1' })
  lu.assertEquals('sess-2', bound)
  lu.assertStrContains(sent, 'Session bound: #1')
end

function TestIntegrationsInitExtra:testSessionCommandByIndexInvalid()
  stub_sessions({})
  local handler = capture_handler()
  handler({ content = '/list' })
  local sent
  discord.send_message = function(c) sent = c end
  handler({ content = '/session 99' })
  lu.assertStrContains(sent, 'Invalid session number')
end

function TestIntegrationsInitExtra:testSessionCommandById()
  stub_sessions({
    ['sess-abc'] = { title = 'ByID', messages = {}, provider = 'p', model = 'm' },
  })
  local handler = capture_handler()
  local bound
  discord.set_session = function(sid) bound = sid end
  handler({ content = '/session sess-abc' })
  lu.assertEquals('sess-abc', bound)
end

function TestIntegrationsInitExtra:testSessionCommandByIdNotFound()
  stub_sessions({})
  local handler = capture_handler()
  local sent
  discord.send_message = function(c) sent = c end
  handler({ content = '/session nope' })
  lu.assertStrContains(sent, 'Session not found')
end

function TestIntegrationsInitExtra:testStatusNoSession()
  local handler = capture_handler()
  local sent
  discord.send_message = function(c) sent = c end
  handler({ content = '/status' })
  lu.assertStrContains(sent, 'No active session')
end

function TestIntegrationsInitExtra:testStatusWithSession()
  discord.current_session = function() return 'sess-1' end
  local handler = capture_handler()
  local sent
  discord.send_message = function(c) sent = c end
  handler({ content = '/status' })
  lu.assertStrContains(sent, 'Provider: openai')
end

function TestIntegrationsInitExtra:testClearCommandNoSession()
  discord.current_session = function() return nil end
  local handler = capture_handler()
  handler({ content = '/clear' })
end

function TestIntegrationsInitExtra:testClearCommandWithSession()
  discord.current_session = function() return 'sess-1' end
  stub_sessions({ ['sess-1'] = {} })
  local cleared = false
  sessions.clear = function() cleared = true end
  local handler = capture_handler()
  local sent
  discord.send_message = function(c) sent = c end
  handler({ content = '/clear' })
  lu.assertTrue(cleared)
  lu.assertStrContains(sent, 'cleared')
end

function TestIntegrationsInitExtra:testClearCommandInProgress()
  discord.current_session = function() return 'sess-1' end
  sessions.is_in_progress = function() return true end
  local cleared = false
  sessions.clear = function() cleared = true end
  local handler = capture_handler()
  handler({ content = '/clear' })
  lu.assertFalse(cleared)
end

function TestIntegrationsInitExtra:testNormalMessageDispatches()
  discord.current_session = function() return 'sess-1' end
  local handler = capture_handler()
  local received
  integrations.on_message(function(msg) received = msg end)
  -- re-capture with real callback
  local captured
  discord.connect = function(h) captured = h end
  integrations.on_message(function(msg) received = msg end)
  captured({ content = 'hello bot' })
  lu.assertNotNil(received)
  lu.assertEquals('sess-1', received.session)
  lu.assertEquals('hello bot', received.content)
end

function TestIntegrationsInitExtra:testFormatSummaryUntitledAndPin()
  -- exercise format_session_summary via /session binding output
  windows.current_session = function() return 'sess-x' end
  stub_sessions({
    ['sess-x'] = { title = '', messages = {}, provider = 'deepseek', model = 'v4', pin = true },
  })
  sessions.get_session_pin = function() return true end
  local handler = capture_handler()
  local sent
  discord.send_message = function(c) sent = c end
  handler({ content = '/session' })
  lu.assertStrContains(sent, '(untitled)')
  lu.assertStrContains(sent, '📌')
end

--- Build `count` sessions, newest = highest number (created === index).
local function numbered_sessions(count)
  local data = {}
  for i = 1, count do
    data[string.format('sess-%02d', i)] = {
      messages = { { role = 'user', content = 'm' .. i, created = i } },
      provider = 'p',
      model = 'm',
    }
  end
  return data
end

function TestIntegrationsInitExtra:testListPaginationKeepsGlobalNumbering()
  stub_sessions(numbered_sessions(12))
  local handler = capture_handler()
  local sent = {}
  discord.send_message = function(c) table.insert(sent, c) end

  handler({ content = '/list' })
  -- Sorted newest first: sess-12 is line 1, page 1 stops at index 10.
  -- Items render as a markdown ordered list, keeping the global number as
  -- the literal list marker.
  lu.assertStrContains(sent[1], '1. m12')
  lu.assertStrContains(sent[1], '10. m3')
  lu.assertNotStrContains(sent[1], '11. m2')
  lu.assertStrContains(sent[1], 'Page 1/2')
  lu.assertStrContains(sent[1], 'next: /list -p 2')

  handler({ content = '/list -p 2' })
  -- Numbering continues from 11, it does not restart at 1.
  lu.assertStrContains(sent[2], '11. m2')
  lu.assertStrContains(sent[2], '12. m1')
  lu.assertStrContains(sent[2], 'Page 2/2')
  lu.assertStrContains(sent[2], 'prev: /list -p 1')
end

function TestIntegrationsInitExtra:testListRejectsPageOutOfRange()
  stub_sessions(numbered_sessions(12))
  local handler = capture_handler()
  local sent
  discord.send_message = function(c) sent = c end

  handler({ content = '/list -p 3' })
  lu.assertStrContains(sent, 'No page 3')
  lu.assertStrContains(sent, '12 session(s)')
end

function TestIntegrationsInitExtra:testSessionNumberBindsGlobalIndexOfFirstPage()
  stub_sessions(numbered_sessions(12))
  local handler = capture_handler()
  discord.send_message = function() end

  -- Page 1 is on screen, index 11 is on page 2: the number is still valid.
  handler({ content = '/list' })
  local bound
  discord.set_session = function(sid) bound = sid end
  local sent
  discord.send_message = function(c) sent = c end
  handler({ content = '/session 11' })
  lu.assertEquals('sess-02', bound)
  lu.assertStrContains(sent, 'Session bound: #11')
end

function TestIntegrationsInitExtra:testListFilterCombinesWithPageFlag()
  stub_sessions(numbered_sessions(12))
  local handler = capture_handler()
  local sent = {}
  discord.send_message = function(c) table.insert(sent, c) end

  -- 'm1' matches m1, m10, m11, m12 -> 4 matches, one page, header keeps the
  -- pattern and the page flag together.
  handler({ content = '/list m1 -p 1' })
  lu.assertStrContains(sent[1], 'Sessions matching "m1":')
  lu.assertStrContains(sent[1], 'Page 1/1')
end

function TestIntegrationsInitExtra:testListFilterTreatsPatternAsPlainText()
  -- A title may contain pattern characters; matching it as a Lua pattern
  -- raises "malformed pattern" or matches something else.
  stub_sessions({
    ['sess-cost'] = { title = 'cost 100% done', messages = {}, provider = 'p', model = 'm' },
    ['sess-plain'] = { title = 'unrelated', messages = {}, provider = 'p', model = 'm' },
  })
  local handler = capture_handler()
  local sent
  discord.send_message = function(c) sent = c end

  handler({ content = '/list 100%' })
  lu.assertStrContains(sent, 'Sessions matching "100%":')
  lu.assertStrContains(sent, 'cost 100% done')
  lu.assertNotStrContains(sent, 'unrelated')
end

function TestIntegrationsInitExtra:testSessionListIsPerChat()
  stub_sessions({
    ['sess-alpha'] = {
      title = 'Alpha',
      messages = { { role = 'user', content = 'a', created = 1 } },
      provider = 'p',
      model = 'm',
    },
    ['sess-beta'] = {
      title = 'Beta',
      messages = { { role = 'user', content = 'b', created = 2 } },
      provider = 'p',
      model = 'm',
    },
  })
  local handler = capture_handler()
  discord.send_message = function() end

  -- Two chats list at different times; the later list must not steal the
  -- numbering the first chat is still holding on screen.
  handler({ content = '/list', chat_id = 'chat-a' })
  handler({ content = '/list Beta', chat_id = 'chat-b' })

  -- Discord addresses one channel per conversation, so `/session` binds the
  -- *chat* the command came from (`bridge.bind_chat`) instead of the
  -- platform-level session. Observe that call: it is the contract the
  -- per-chat numbering relies on.
  local saved_bridge = discord.bridge
  local bound
  discord.bridge = {
    session = function() return nil end,
    set_session = function() end,
    session_for_chat = function() return nil end,
    bind_chat = function(_chat_id, session)
      bound = session
      return true
    end,
    chats = function() return {} end,
  }

  local ok, err = pcall(function()
    -- chat-a: newest first -> 1) Beta, 2) Alpha.
    handler({ content = '/session 2', chat_id = 'chat-a' })
    lu.assertEquals('sess-alpha', bound)

    -- chat-b filtered to Beta, so its own numbering starts at 1.
    handler({ content = '/session 1', chat_id = 'chat-b' })
    lu.assertEquals('sess-beta', bound)

    -- An unknown chat never borrowed another chat's numbering.
    handler({ content = '/session 1', chat_id = 'chat-c' })
    lu.assertEquals('sess-beta', bound, 'no slot -> bind is not attempted')
  end)

  discord.bridge = saved_bridge
  if not ok then
    error(err)
  end
end

return TestIntegrationsInitExtra
