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
  -- activation is retrievable and clearable
  lu.assertTrue(tools.get_activated_tools(SID).write_file)
  tools.clear_activated_tools(SID)
  lu.assertNil(tools.get_activated_tools(SID).write_file)
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

--------------------------------------------------------------------
-- find_tool handler
--------------------------------------------------------------------

function TestFindTool:test_handler_exact_name()
  local res = find_tool.find_tool({ query = 'get_time' }, { session = SID })
  lu.assertNil(res.error)
  local data = vim.json.decode(res.content)
  lu.assertTrue(data.found)
  lu.assertEquals(data.tool.name, 'get_time')
  lu.assertNotNil(data.tool.parameters)
  -- tool got activated for the session
  lu.assertTrue(tools.get_activated_tools(SID).get_time)
end

function TestFindTool:test_handler_case_insensitive()
  local res = find_tool.find_tool({ query = 'GET_TIME' }, { session = SID })
  local data = vim.json.decode(res.content)
  lu.assertTrue(data.found)
  lu.assertEquals(data.tool.name, 'get_time')
end

function TestFindTool:test_handler_spaces_normalized()
  -- "git log" should normalize to git_log
  local res = find_tool.find_tool({ query = 'git log' }, { session = SID })
  local data = vim.json.decode(res.content)
  lu.assertTrue(data.found)
  lu.assertEquals(data.tool.name, 'git_log')
end

function TestFindTool:test_handler_trailing_space_trimmed()
  local res = find_tool.find_tool({ query = 'get_time ' }, { session = SID })
  local data = vim.json.decode(res.content)
  lu.assertTrue(data.found, 'trailing whitespace must be trimmed for exact match')
  lu.assertEquals(data.tool.name, 'get_time')
end

function TestFindTool:test_handler_list_returns_catalog()
  local res = find_tool.find_tool({ query = 'list' }, { session = SID })
  local data = vim.json.decode(res.content)
  lu.assertFalse(data.found)
  lu.assertEquals(data.action, 'catalog')
  lu.assertTrue(#data.tools > 10)
  lu.assertStrContains(data.hint, 'find_tool')
end

function TestFindTool:test_handler_empty_query_returns_catalog()
  local res = find_tool.find_tool({ query = '' }, { session = SID })
  local data = vim.json.decode(res.content)
  lu.assertFalse(data.found)
  lu.assertEquals(data.action, 'catalog')
end

function TestFindTool:test_handler_keyword_multiple_candidates()
  local res = find_tool.find_tool({ query = 'git' }, { session = SID })
  local data = vim.json.decode(res.content)
  lu.assertFalse(data.found)
  lu.assertTrue(#data.candidates > 1, 'git should match multiple tools')
  lu.assertStrContains(data.hint, 'exact tool name')
end

function TestFindTool:test_handler_unique_partial_match_returns_schema()
  local res = find_tool.find_tool({ query = 'lsp' }, { session = SID })
  local data = vim.json.decode(res.content)
  lu.assertTrue(data.found, 'unique partial match should return the schema directly')
  lu.assertEquals(data.tool.name, 'lsp_diagnostics')
end

function TestFindTool:test_handler_unknown_query_returns_catalog_with_note()
  local res = find_tool.find_tool({ query = 'zzz_nonexistent_xyz' }, { session = SID })
  local data = vim.json.decode(res.content)
  lu.assertFalse(data.found)
  lu.assertStrContains(data.note, 'No tool matched')
  lu.assertTrue(#data.tools > 10)
end

function TestFindTool:test_handler_nil_action()
  local res = find_tool.find_tool(nil, { session = SID })
  local data = vim.json.decode(res.content)
  lu.assertFalse(data.found)
  lu.assertEquals(data.action, 'catalog')
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
  local data = vim.json.decode(res.content)
  lu.assertTrue(data.found)
  lu.assertEquals(data.tool.name, 'get_time')
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

return TestFindTool

