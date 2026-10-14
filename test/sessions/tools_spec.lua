-- chat.sessions.tools argument decoding tests
--
-- Tool call arguments arrive as a raw JSON string. Decoding must accept
-- a parameter value shaped as a string or as an array of strings, and
-- must survive the damaged form seen in the wild where upstream
-- components strip the quotes from values ({"path": README.md}).
local lu = require('luaunit')
local sessions_tools = require('chat.sessions.tools')

TestDecodeArguments = {}

-- Well-formed JSON: value is a string
function TestDecodeArguments:test_string_value()
  local args = sessions_tools.decode_arguments('{"path": "a.lua"}')
  lu.assertNotNil(args)
  lu.assertEquals(args.path, 'a.lua')
end

-- Well-formed JSON: value is an array of strings
function TestDecodeArguments:test_array_of_strings_value()
  local args = sessions_tools.decode_arguments('{"path": ["a.lua", "b.lua"]}')
  lu.assertNotNil(args)
  lu.assertEquals(#args.path, 2)
  lu.assertEquals(args.path[1], 'a.lua')
  lu.assertEquals(args.path[2], 'b.lua')
end

-- Damaged JSON: quotes stripped from a string value (the wild bug)
function TestDecodeArguments:test_bare_string_value_repaired()
  local args = sessions_tools.decode_arguments('{"path": README.md}')
  lu.assertNotNil(args)
  lu.assertEquals(args.path, 'README.md')
end

-- Damaged JSON: quotes stripped inside an array of strings
function TestDecodeArguments:test_bare_array_elements_repaired()
  local args = sessions_tools.decode_arguments('{"path": [a.lua, b.lua]}')
  lu.assertNotNil(args)
  lu.assertEquals(#args.path, 2)
  lu.assertEquals(args.path[1], 'a.lua')
  lu.assertEquals(args.path[2], 'b.lua')
end

-- Repair must not quote JSON literals (numbers, booleans, null)
function TestDecodeArguments:test_literals_not_quoted_when_repairing()
  local args = sessions_tools.decode_arguments(
    '{"path": README.md, "all": true}'
  )
  lu.assertNotNil(args)
  lu.assertEquals(args.path, 'README.md')
  lu.assertEquals(args.all, true)
end

-- Repair also works for bare values inside nested objects
function TestDecodeArguments:test_bare_value_in_nested_object()
  local args = sessions_tools.decode_arguments(
    '{"opts": {"path": README.md}}'
  )
  lu.assertNotNil(args)
  lu.assertEquals(args.opts.path, 'README.md')
end

-- Already quoted values must never be double-quoted
function TestDecodeArguments:test_quoted_values_untouched()
  local args = sessions_tools.decode_arguments(
    '{"path": ["a.lua", "b.lua"], "name": "x"}'
  )
  lu.assertNotNil(args)
  lu.assertEquals(#args.path, 2)
  lu.assertEquals(args.name, 'x')
end

-- Empty object decodes to an empty table (tools handle defaults)
function TestDecodeArguments:test_empty_object()
  local args = sessions_tools.decode_arguments('{}')
  lu.assertNotNil(args)
  lu.assertEquals(type(args), 'table')
  lu.assertEquals(vim.tbl_count(args), 0)
end

-- Undecodable inputs return nil instead of erroring
function TestDecodeArguments:test_empty_string_returns_nil()
  lu.assertNil(sessions_tools.decode_arguments(''))
end

function TestDecodeArguments:test_non_string_returns_nil()
  lu.assertNil(sessions_tools.decode_arguments(nil))
  lu.assertNil(sessions_tools.decode_arguments(42))
end

function TestDecodeArguments:test_truncated_returns_nil()
  lu.assertNil(sessions_tools.decode_arguments('{"path": "a.lua"'))
end

function TestDecodeArguments:test_garbage_returns_nil()
  lu.assertNil(sessions_tools.decode_arguments('not json at all'))
end

-- '123' decodes to a number, not an object: reject like undecodable
function TestDecodeArguments:test_scalar_returns_nil()
  lu.assertNil(sessions_tools.decode_arguments('123'))
end

