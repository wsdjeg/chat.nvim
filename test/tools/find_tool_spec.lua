-- test/tools/find_tool_spec.lua
-- Tests for find_tool tool discovery and lazy tool loading

local lu = require('luaunit')
local tools = require('chat.tools')
local find_tool = require('chat.tools.find_tool')
local config = require('chat.config')

local SID = 'find-tool-spec-session'

TestFindTool = {}

function TestFindTool:setUp()
  self.tmp = vim.fn.tempname() .. '_findtool/'
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
  })
  -- 隔离会话缓存，避免同秒 new() 冲突（#7）
  require('chat.sessions').set_cache_dir(self.tmp .. 'sessions/')
  tools.clear_activated_tools(SID)
end

function TestFindTool:tearDown()
  tools.clear_activated_tools(SID)
  if self.tmp and vim.fn.isdirectory(self.tmp) == 1 then
    vim.fn.delete(self.tmp, 'rf')
  end
end

--- Collect tool names from a request_tools result
local function names_of(schemes)
  local names = {}
  for _, s in ipairs(schemes) do
    table.insert(names, s['function'].name)
  end
  return names
end

local function contains(list, value)
  for _, v in ipairs(list) do
    if v == value then
      return true
    end
  end
  return false
end

--- get_activated_tools returns an ordered name list (not a set), so
--- membership has to be checked explicitly.
local function activated_has(session_id, name)
  return contains(tools.get_activated_tools(session_id), name)
end

--------------------------------------------------------------------
-- scheme()
--------------------------------------------------------------------

function TestFindTool:test_scheme_embeds_catalog()
  local scheme = find_tool.scheme()
  lu.assertEquals(scheme['function'].name, 'find_tool')
  local desc = scheme['function'].description
  lu.assertStrContains(desc, 'Catalog of all available tools')
  -- catalog lines are "- name: introduction"
  lu.assertStrContains(desc, '- get_time:')
  -- find_tool itself must not appear in the catalog (no recursion)
  lu.assertNil(desc:find('\n%- find_tool:', 1, false))
end

function TestFindTool:test_scheme_degrades_when_tools_module_stale()
  -- Simulate the reported crash: an outdated chat.tools module cached
  -- in package.loaded while find_tool is new.
  local real = package.loaded['chat.tools']
  package.loaded['chat.tools'] = {}
  local ok, scheme = pcall(find_tool.scheme)
  package.loaded['chat.tools'] = real
  lu.assertTrue(ok, 'scheme must not raise with a stale chat.tools module')
  lu.assertStrContains(
    scheme['function'].description,
    'catalog temporarily unavailable'
  )
end

--------------------------------------------------------------------
-- available_tools / catalog
--------------------------------------------------------------------

function TestFindTool:test_available_tools_excludes_find_tool()
  local names = names_of(tools.available_tools())
  lu.assertTrue(#names > 10, 'should collect many builtin tools')
  lu.assertFalse(contains(names, 'find_tool'))
  lu.assertTrue(contains(names, 'get_time'))
end

function TestFindTool:test_catalog_lines_format()
  local lines = tools.catalog_lines()
  lu.assertTrue(#lines > 10)
  for _, line in ipairs(lines) do
    lu.assertStrMatches(line, '^%- [^:]+: .+')
  end
  local joined = table.concat(lines, '\n')
  lu.assertStrContains(joined, '- get_time:')
  lu.assertNil(joined:find('%- find_tool:', 1, false))
end

function TestFindTool:test_tool_introduction_falls_back_to_description()
  local scheme = nil
  for _, s in ipairs(tools.available_tools()) do
    if s['function'].name == 'get_time' then
      scheme = s
    end
  end
  lu.assertNotNil(scheme, 'get_time scheme should be available')
  local intro = tools.tool_introduction(require('chat.tools.get_time'), scheme)
  lu.assertNotNil(intro:match('%S'), 'introduction should be non-empty')
end

--------------------------------------------------------------------
-- request_tools (lazy loading)
--------------------------------------------------------------------

function TestFindTool:test_request_tools_lazy_default()
  local names = names_of(tools.request_tools(SID))
  lu.assertTrue(contains(names, 'find_tool'))
  lu.assertTrue(contains(names, 'get_time'))
  -- non-essential tools must not be eagerly included
  lu.assertFalse(contains(names, 'git_add'))
  lu.assertFalse(contains(names, 'write_file'))
end

function TestFindTool:test_request_tools_nil_session()
  local names = names_of(tools.request_tools(nil))
  lu.assertTrue(contains(names, 'find_tool'))
  lu.assertTrue(contains(names, 'get_time'))
end

function TestFindTool:test_request_tools_after_activation()
  tools.activate_tool(SID, 'write_file')
  local names = names_of(tools.request_tools(SID))
  lu.assertTrue(contains(names, 'write_file'))
  lu.assertTrue(contains(names, 'find_tool'))
  -- activation is retrievable (ordered list) and clearable
  lu.assertTrue(activated_has(SID, 'write_file'))
  tools.clear_activated_tools(SID)
  lu.assertFalse(activated_has(SID, 'write_file'))
  names = names_of(tools.request_tools(SID))
  lu.assertFalse(contains(names, 'write_file'))
end

function TestFindTool:test_request_tools_history_self_healing()
  local sessions = require('chat.sessions')
  local storage = require('chat.sessions.storage')
  local sid = sessions.new()
  storage.sessions[sid].messages = storage.sessions[sid].messages or {}
  table.insert(storage.sessions[sid].messages, {
    role = 'assistant',
    tool_calls = {
      { id = 'call_1', type = 'function', ['function'] = { name = 'write_file', arguments = '{}' } },
    },
  })
  local names = names_of(tools.request_tools(sid))
  lu.assertTrue(
    contains(names, 'write_file'),
    'tools called earlier in history must be re-included'
  )
end

function TestFindTool:test_request_tools_history_resets_after_turn_end()
  local sessions = require('chat.sessions')
  local storage = require('chat.sessions.storage')
  local sid = sessions.new()
  storage.sessions[sid].messages = storage.sessions[sid].messages or {}
  -- finished turn: user, tool call, tool result, text-only reply
  table.insert(storage.sessions[sid].messages, {
    role = 'user', content = 'write a file',
  })
  table.insert(storage.sessions[sid].messages, {
    role = 'assistant',
    tool_calls = {
      { id = 'call_1', type = 'function', ['function'] = { name = 'write_file', arguments = '{}' } },
    },
  })
  table.insert(storage.sessions[sid].messages, {
    role = 'tool', content = 'ok', tool_call_id = 'call_1',
  })
  table.insert(storage.sessions[sid].messages, {
    role = 'assistant', content = 'done',
  })
  -- next turn starts
  table.insert(storage.sessions[sid].messages, {
    role = 'user', content = 'something else',
  })
  local names = names_of(tools.request_tools(sid))
  lu.assertFalse(
    contains(names, 'write_file'),
    'tools from a finished turn must not be carried into the next turn'
  )
  lu.assertTrue(contains(names, 'find_tool'))
end

function TestFindTool:test_request_tools_history_keeps_current_turn_tools()
  local sessions = require('chat.sessions')
  local storage = require('chat.sessions.storage')
  local sid = sessions.new()
  storage.sessions[sid].messages = storage.sessions[sid].messages or {}
  -- finished turn using write_file
  table.insert(storage.sessions[sid].messages, { role = 'user', content = 'u1' })
  table.insert(storage.sessions[sid].messages, {
    role = 'assistant',
    tool_calls = {
      { id = 'call_1', type = 'function', ['function'] = { name = 'write_file', arguments = '{}' } },
    },
  })
  table.insert(storage.sessions[sid].messages, {
    role = 'tool', content = 'ok', tool_call_id = 'call_1',
  })
  table.insert(storage.sessions[sid].messages, {
    role = 'assistant', content = 'done',
  })
  -- open turn using git_log (no text-only reply yet)
  table.insert(storage.sessions[sid].messages, { role = 'user', content = 'u2' })
  table.insert(storage.sessions[sid].messages, {
    role = 'assistant',
    tool_calls = {
      { id = 'call_2', type = 'function', ['function'] = { name = 'git_log', arguments = '{}' } },
    },
  })
  local names = names_of(tools.request_tools(sid))
  lu.assertFalse(
    contains(names, 'write_file'),
    'tools from the finished turn must be dropped'
  )
  lu.assertTrue(
    contains(names, 'git_log'),
    'tools from the current (open) turn must stay available'
  )
end

--------------------------------------------------------------------
-- turn-end tool cleanup (progress.on_progress_done)
--------------------------------------------------------------------

function TestFindTool:test_turn_end_clears_activated_tools()
  local sessions = require('chat.sessions')
  local progress = require('chat.sessions.progress')
  local sid = sessions.new()
  local jobid = 987654321
  progress.set_session_jobid(sid, jobid)
  tools.activate_tool(sid, 'write_file')
  -- text-only response: the turn is complete, no further request follows
  progress.on_progress_done(jobid)
  lu.assertFalse(
    activated_has(sid, 'write_file'),
    'activated tools must be cleared when the turn ends without tool calls'
  )
  local names = names_of(tools.request_tools(sid))
  lu.assertFalse(contains(names, 'write_file'))
end

function TestFindTool:test_tool_call_turn_keeps_activated_tools()
  local sessions = require('chat.sessions')
  local progress = require('chat.sessions.progress')
  local sid = sessions.new()
  local jobid = 987654322
  progress.set_session_jobid(sid, jobid)
  tools.activate_tool(sid, 'write_file')
  -- response carries tool calls: the turn continues
  progress.on_progress_done(jobid, {
    tool_calls = {
      { id = 'call_1', type = 'function', ['function'] = { name = 'write_file', arguments = '{}' } },
    },
  })
  lu.assertTrue(
    activated_has(sid, 'write_file'),
    'activated tools must survive while the turn continues with tool calls'
  )
end

--------------------------------------------------------------------
-- find_tool handler: terse responses
-- The full schema is not echoed back: once a tool is activated it appears
-- in the next request's tools list, so repeating it in the tool result
-- would only duplicate tokens.
--------------------------------------------------------------------

function TestFindTool:test_handler_exact_name()
  local res = find_tool.find_tool({ query = 'get_time' }, { session = SID })
  lu.assertNil(res.error)
  lu.assertStrContains(res.content, 'Enabled tool "get_time"')
  -- tool got activated for the session
  lu.assertTrue(activated_has(SID, 'get_time'))
end

function TestFindTool:test_handler_response_does_not_echo_schema()
  local res = find_tool.find_tool({ query = 'get_time' }, { session = SID })
  lu.assertStrContains(res.content, 'Enabled tool', true)
  lu.assertNil(res.content:find('parameters', 1, true))
  lu.assertNil(res.content:find('description', 1, true))
  lu.assertTrue(#res.content < 200, 'enabled response must stay terse, got: ' .. res.content)
end

function TestFindTool:test_handler_case_insensitive()
  local res = find_tool.find_tool({ query = 'GET_TIME' }, { session = SID })
  lu.assertStrContains(res.content, 'Enabled tool "get_time"')
end

function TestFindTool:test_handler_spaces_normalized()
  -- "git log" should normalize to git_log
  local res = find_tool.find_tool({ query = 'git log' }, { session = SID })
  lu.assertStrContains(res.content, 'Enabled tool "git_log"')
end

function TestFindTool:test_handler_trailing_space_trimmed()
  local res = find_tool.find_tool({ query = 'get_time ' }, { session = SID })
  lu.assertStrContains(res.content, 'Enabled tool "get_time"',
    'trailing whitespace must be trimmed for exact match')
end

function TestFindTool:test_handler_list_points_to_embedded_catalog()
  local res = find_tool.find_tool({ query = 'list' }, { session = SID })
  lu.assertNil(res.error)
  lu.assertStrContains(res.content, 'catalog of available tools is already in the find_tool description')
  -- the catalog itself is in the description, not repeated here
  lu.assertNil(res.content:find('- get_time:', 1, true))
end

function TestFindTool:test_handler_empty_query_returns_catalog_hint()
  local res = find_tool.find_tool({ query = '' }, { session = SID })
  lu.assertStrContains(res.content, 'find_tool description above')
end

function TestFindTool:test_handler_keyword_lists_candidate_names()
  local res = find_tool.find_tool({ query = 'git' }, { session = SID })
  lu.assertNil(res.error)
  lu.assertStrContains(res.content, 'matched')
  lu.assertStrContains(res.content, 'git_add')
  -- names only: no introductions, no schemas
  lu.assertNil(res.content:find('introduction', 1, true))
  lu.assertTrue(#res.content < 400, 'candidate response must stay terse')
end

function TestFindTool:test_handler_unique_partial_match_enables_tool()
  local res = find_tool.find_tool({ query = 'lsp' }, { session = SID })
  lu.assertStrContains(res.content, 'Enabled tool "lsp_diagnostics"',
    'unique partial match should enable the tool directly')
  lu.assertTrue(activated_has(SID, 'lsp_diagnostics'))
end

function TestFindTool:test_handler_unknown_query_points_to_catalog()
  local res = find_tool.find_tool({ query = 'zzz_nonexistent_xyz' }, { session = SID })
  lu.assertNil(res.error)
  lu.assertStrContains(res.content, 'No tool matched "zzz_nonexistent_xyz"')
  lu.assertStrContains(res.content, 'find_tool description above')
end

function TestFindTool:test_handler_nil_action_returns_catalog_hint()
  local res = find_tool.find_tool(nil, { session = SID })
  lu.assertStrContains(res.content, 'find_tool description above')
end

--- Without a session there is nowhere to activate the tool, so the full
--- schema must be returned - otherwise it would never become callable.
function TestFindTool:test_handler_without_session_returns_schema()
  local res = find_tool.find_tool({ query = 'get_time' }, {})
  lu.assertNil(res.error)
  local data = vim.json.decode(res.content)
  lu.assertTrue(data.found)
  lu.assertEquals(data.tool.name, 'get_time')
  lu.assertNotNil(data.tool.parameters)
  lu.assertStrContains(data.note, 'No session')
end

function TestFindTool:test_handler_stale_tools_module()
  local real = package.loaded['chat.tools']
  package.loaded['chat.tools'] = {}
  local ok, res = pcall(find_tool.find_tool, { query = 'get_time' }, { session = SID })
  package.loaded['chat.tools'] = real
  lu.assertTrue(ok, 'handler must not raise with a stale chat.tools module')
  lu.assertStrContains(res.error, 'Restart Neovim')
end

--------------------------------------------------------------------
-- tools.call routing for find_tool
--------------------------------------------------------------------

function TestFindTool:test_call_routes_find_tool()
  local res = tools.call('find_tool', { query = 'get_time' }, { session = SID })
  lu.assertNil(res.error)
  lu.assertStrContains(res.content, 'Enabled tool "get_time"')
end

--------------------------------------------------------------------
-- info()
--------------------------------------------------------------------

function TestFindTool:test_info_with_query()
  local info = find_tool.info('{"query":"git_log"}', {})
  lu.assertEquals(info, 'find_tool(query="git_log")')
end

function TestFindTool:test_info_with_table()
  local info = find_tool.info({ query = 'get_time' }, {})
  lu.assertEquals(info, 'find_tool(query="get_time")')
end

function TestFindTool:test_info_invalid_json()
  local info = find_tool.info('not json', {})
  lu.assertEquals(info, 'find_tool')
end

function TestFindTool:test_info_nil()
  local info = find_tool.info(nil, {})
  lu.assertEquals(info, 'find_tool(query="")')
end

--------------------------------------------------------------------
-- UTF-8 safe truncation (first_line / catalog path)
--------------------------------------------------------------------

--- 60 Chinese chars after one ASCII byte: byte 117 falls in the middle
--- of a multi-byte character, so byte-based sub(1, 117) would produce
--- invalid UTF-8 that ends up in the find_tool catalog / request body.
function TestFindTool:test_tool_introduction_truncates_multibyte_at_boundary()
  local util = require('chat.util')
  local desc = 'a' .. string.rep('好', 60) -- 181 bytes
  local intro = tools.tool_introduction(nil, {
    type = 'function',
    ['function'] = { name = 'mb_tool', description = desc },
  })
  lu.assertStrContains(intro, '...')
  -- must stay valid UTF-8 after truncation
  local _, had_invalid = util.sanitize_utf8(intro)
  lu.assertFalse(had_invalid,
    'introduction must not be cut mid-character: ' .. vim.inspect(intro))
  -- truncated near the 120-byte budget, not the raw 117-byte prefix + '...'
  lu.assertTrue(#intro <= 123)
end

function TestFindTool:test_tool_introduction_multibyte_not_truncated_when_short()
  local desc = string.rep('好', 30) -- 90 bytes, under budget
  local intro = tools.tool_introduction(nil, {
    type = 'function',
    ['function'] = { name = 'mb_tool', description = desc },
  })
  lu.assertEquals(intro, desc)
end

--- The embedded catalog aggregates introductions from many sources and
--- is inserted into request bodies without further sanitization, so it
--- must itself be valid UTF-8.
function TestFindTool:test_scheme_catalog_is_valid_utf8()
  local util = require('chat.util')
  local scheme = find_tool.scheme()
  local _, had_invalid = util.sanitize_utf8(scheme['function'].description)
  lu.assertFalse(had_invalid, 'find_tool catalog description must be valid UTF-8')
end

return TestFindTool

