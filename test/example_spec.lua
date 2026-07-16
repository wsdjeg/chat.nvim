-- test/example_spec.lua
-- Example test file demonstrating the luaunit test pattern

local lu = require('luaunit')

TestExample = {}

function TestExample:test_simple_assertion()
  lu.assertEquals(1 + 1, 2)
end

function TestExample:test_string_operations()
  local s = 'hello'
  lu.assertEquals(string.upper(s), 'HELLO')
  lu.assertEquals(string.len(s), 5)
end

function TestExample:test_table_operations()
  local t = {}
  table.insert(t, 'a')
  table.insert(t, 'b')
  lu.assertEquals(#t, 2)
  lu.assertEquals(t[1], 'a')
end

function TestExample:test_plugin_loaded()
  -- Verify that chat.nvim is loaded in test environment
  lu.assertNotNil(require('chat'))
end

return TestExample

