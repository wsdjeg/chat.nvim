-- test/tools/request_tools_order_spec.lua
-- Deterministic, append-only ordering of the request's tools array.
--
-- The tools array is sent right after the system prompt in every request
-- body, so its order is part of the provider's cached prefix. Iterating a
-- hash table there reshuffles positions whenever a tool is activated and
-- invalidates the whole conversation cache. These tests pin the contract:
--
--   1. tools.essential, in config order
--   2. tools called in the current turn, in call order
--   3. tools activated via find_tool, in activation order
--   4. find_tool, always last

local lu = require('luaunit')
local tools = require('chat.tools')
local config = require('chat.config')

local SID = 'request-tools-order-session'

TestRequestToolsOrder = {}

function TestRequestToolsOrder:setUp()
  self.tmp = vim.fn.tempname() .. '_toolorder/'
  vim.fn.mkdir(self.tmp, 'p')
  config.setup({
    storage_dir = self.tmp,
    memory = {
      enable = true,
      storage_dir = self.tmp .. 'memory/',
    },
    tools = {
      lazy = true,
      -- deliberately not alphabetical: the config order must be preserved
      essential = { 'get_time', 'read_file' },
    },
  })
  require('chat.sessions').set_cache_dir(self.tmp .. 'sessions/')
  tools.clear_activated_tools(SID)
end

function TestRequestToolsOrder:tearDown()
  tools.clear_activated_tools(SID)
  if self.tmp and vim.fn.isdirectory(self.tmp) == 1 then
    vim.fn.delete(self.tmp, 'rf')
  end
end

local function names_of(schemes)
  local names = {}
  for _, s in ipairs(schemes) do
    table.insert(names, s['function'].name)
  end
  return names
end

local function index_of(names, value)
  for i, v in ipairs(names) do
    if v == value then
      return i
    end
  end
  return nil
end

local function count_of(names, value)
  local n = 0
  for _, v in ipairs(names) do
    if v == value then
      n = n + 1
    end
  end
  return n
end

--------------------------------------------------------------------
-- essential block
--------------------------------------------------------------------

function TestRequestToolsOrder:test_essential_keeps_config_order()
  local names = names_of(tools.request_tools(SID))
  lu.assertEquals(names[1], 'get_time')
  lu.assertEquals(names[2], 'read_file')
end

function TestRequestToolsOrder:test_find_tool_is_always_last()
  local names = names_of(tools.request_tools(SID))
  lu.assertEquals(names[#names], 'find_tool')

  tools.activate_tool(SID, 'write_file')
  tools.activate_tool(SID, 'git_add')
  names = names_of(tools.request_tools(SID))
  lu.assertEquals(names[#names], 'find_tool')
  lu.assertEquals(index_of(names, 'write_file'), #names - 2)
  lu.assertEquals(index_of(names, 'git_add'), #names - 1)
end

--------------------------------------------------------------------
-- activation order
--------------------------------------------------------------------

function TestRequestToolsOrder:test_activation_order_preserved()
  tools.activate_tool(SID, 'git_add')
  tools.activate_tool(SID, 'write_file')
  tools.activate_tool(SID, 'git_commit')

  local names = names_of(tools.request_tools(SID))
  local git_add = index_of(names, 'git_add')
  local write_file = index_of(names, 'write_file')
  local git_commit = index_of(names, 'git_commit')

  lu.assertNotNil(git_add)
  lu.assertNotNil(write_file)
  lu.assertNotNil(git_commit)
  lu.assertTrue(
    git_add < write_file and write_file < git_commit,
    'activated tools must keep activation order: ' .. table.concat(names, ',')
  )
end

function TestRequestToolsOrder:test_activation_is_idempotent()
  tools.activate_tool(SID, 'write_file')
  tools.activate_tool(SID, 'write_file')
  tools.activate_tool(SID, 'write_file')

  lu.assertEquals(#tools.get_activated_tools(SID), 1)
  local names = names_of(tools.request_tools(SID))
  lu.assertEquals(count_of(names, 'write_file'), 1)
end

function TestRequestToolsOrder:test_essential_activation_not_duplicated()
  -- read_file is already in the essential block: activating it again must
  -- not add a second entry later in the array
  tools.activate_tool(SID, 'read_file')
  local names = names_of(tools.request_tools(SID))
  lu.assertEquals(count_of(names, 'read_file'), 1)
  lu.assertEquals(index_of(names, 'read_file'), 2)
end

--------------------------------------------------------------------
-- append-only growth
--------------------------------------------------------------------

function TestRequestToolsOrder:test_new_activation_only_inserts_one_entry()
  tools.activate_tool(SID, 'git_add')
  local before = names_of(tools.request_tools(SID))

  tools.activate_tool(SID, 'write_file')
  local after = names_of(tools.request_tools(SID))

  lu.assertEquals(#after, #before + 1, 'exactly one entry was added')

  -- every surviving entry keeps its relative order (find_tool moves one
  -- slot later, it is always last)
  local previous = {}
  for _, name in ipairs(before) do
    if name ~= 'find_tool' then
      table.insert(previous, name)
    end
  end
  local current = {}
  for _, name in ipairs(after) do
    if name ~= 'find_tool' then
      table.insert(current, name)
    end
  end
  for _, name in ipairs(previous) do
    lu.assertTrue(index_of(current, name) ~= nil, name .. ' kept')
  end
  lu.assertEquals(index_of(current, 'write_file'), #current)
end

function TestRequestToolsOrder:test_same_state_same_order()
  tools.activate_tool(SID, 'write_file')
  tools.activate_tool(SID, 'git_add')

  local first = names_of(tools.request_tools(SID))
  local second = names_of(tools.request_tools(SID))
  local third = names_of(tools.request_tools(SID))

  lu.assertEquals(first, second)
  lu.assertEquals(second, third)
end

--------------------------------------------------------------------
-- history-derived tools
--------------------------------------------------------------------

function TestRequestToolsOrder:test_history_tools_keep_call_order()
  local sessions = require('chat.sessions')
  local storage = require('chat.sessions.storage')
  local sid = sessions.new()
  storage.sessions[sid].messages = storage.sessions[sid].messages or {}

  table.insert(storage.sessions[sid].messages, { role = 'user', content = 'u1' })
  table.insert(storage.sessions[sid].messages, {
    role = 'assistant',
    tool_calls = {
      { id = 'call_1', type = 'function', ['function'] = { name = 'git_log', arguments = '{}' } },
    },
  })
  table.insert(storage.sessions[sid].messages, {
    role = 'tool', content = 'ok', tool_call_id = 'call_1',
  })
  table.insert(storage.sessions[sid].messages, {
    role = 'assistant',
    tool_calls = {
      { id = 'call_2', type = 'function', ['function'] = { name = 'write_file', arguments = '{}' } },
    },
  })

  local names = names_of(tools.request_tools(sid))
  local git_log = index_of(names, 'git_log')
  local write_file = index_of(names, 'write_file')
  lu.assertNotNil(git_log)
  lu.assertNotNil(write_file)
  lu.assertTrue(
    git_log < write_file,
    'tools called in the turn must be ordered by call order'
  )
end

function TestRequestToolsOrder:test_history_before_activated()
  local sessions = require('chat.sessions')
  local storage = require('chat.sessions.storage')
  local sid = sessions.new()
  storage.sessions[sid].messages = storage.sessions[sid].messages or {}

  table.insert(storage.sessions[sid].messages, { role = 'user', content = 'u1' })
  table.insert(storage.sessions[sid].messages, {
    role = 'assistant',
    tool_calls = {
      { id = 'call_1', type = 'function', ['function'] = { name = 'git_log', arguments = '{}' } },
    },
  })
  -- activated but not yet called: must land after the history block
  tools.activate_tool(sid, 'git_add')

  local names = names_of(tools.request_tools(sid))
  lu.assertTrue(index_of(names, 'git_log') < index_of(names, 'git_add'))
  lu.assertEquals(names[#names], 'find_tool')

  tools.clear_activated_tools(sid)
end

function TestRequestToolsOrder:test_history_duplicate_activation_single_entry()
  local sessions = require('chat.sessions')
  local storage = require('chat.sessions.storage')
  local sid = sessions.new()
  storage.sessions[sid].messages = storage.sessions[sid].messages or {}

  table.insert(storage.sessions[sid].messages, { role = 'user', content = 'u1' })
  table.insert(storage.sessions[sid].messages, {
    role = 'assistant',
    tool_calls = {
      { id = 'call_1', type = 'function', ['function'] = { name = 'write_file', arguments = '{}' } },
    },
  })
  -- the same tool was also activated via find_tool earlier
  tools.activate_tool(sid, 'write_file')

  local names = names_of(tools.request_tools(sid))
  lu.assertEquals(count_of(names, 'write_file'), 1)

  tools.clear_activated_tools(sid)
end

--------------------------------------------------------------------
-- non-lazy mode is untouched
--------------------------------------------------------------------

function TestRequestToolsOrder:test_lazy_false_returns_all_tools()
  config.setup({ tools = { lazy = false } })
  local names = names_of(tools.request_tools(SID))
  lu.assertTrue(#names > 10)
  -- non-lazy mode sends available_tools() verbatim, which excludes
  -- find_tool (it embeds the catalog and would recurse)
  lu.assertNil(index_of(names, 'find_tool'))
end

return TestRequestToolsOrder

