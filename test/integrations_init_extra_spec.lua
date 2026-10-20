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
  lu.assertStrContains(sent, 'Session bound: 1)')
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

return TestIntegrationsInitExtra
