local lu = require('luaunit')
local tools = require('chat.tools')
local config = require('chat.config')

TestToolsGeneral = {}

function TestToolsGeneral:setUp()
  config.setup({
    allowed_path = vim.fs.normalize(vim.fn.getcwd()),
  })
end

function TestToolsGeneral:testAvailableTools()
  local available = tools.available_tools()
  lu.assertNotNil(available)
  lu.assertTrue(type(available) == 'table')

  local tool_names = {}
  for _, tool in ipairs(available) do
    table.insert(tool_names, tool['function'].name)
  end

  lu.assertTrue(vim.tbl_contains(tool_names, 'read_file'))
  lu.assertTrue(vim.tbl_contains(tool_names, 'find_files'))
  lu.assertTrue(vim.tbl_contains(tool_names, 'search_text'))
  lu.assertTrue(vim.tbl_contains(tool_names, 'extract_memory'))
  lu.assertTrue(vim.tbl_contains(tool_names, 'recall_memory'))
  lu.assertTrue(vim.tbl_contains(tool_names, 'move_file'))
  lu.assertTrue(vim.tbl_contains(tool_names, 'copy_file'))
  lu.assertTrue(vim.tbl_contains(tool_names, 'list_directory'))
  lu.assertTrue(vim.tbl_contains(tool_names, 'file_info'))
  lu.assertTrue(vim.tbl_contains(tool_names, 'create_directory'))
end

function TestToolsGeneral:testInvalidToolCall()
  local result = tools.call(
    'nonexistent_tool',
    {},
    { cwd = vim.fs.normalize(vim.fn.getcwd()) }
  )
  lu.assertNotNil(result)
  lu.assertNotNil(result.error)
end

function TestToolsGeneral:testToolCallWithInvalidArguments()
  local result = tools.call(
    'read_file',
    {},
    { cwd = vim.fs.normalize(vim.fn.getcwd()) }
  )
  lu.assertNotNil(result)
  lu.assertNotNil(result.error)
end

-- ===== validate_scheme tests =====

TestValidateScheme = {}

function TestValidateScheme:testValidScheme()
  local scheme = {
    type = 'function',
    ['function'] = {
      name = 'test_tool',
      description = 'A test tool',
      parameters = {
        type = 'object',
        properties = {
          foo = { type = 'string', description = 'foo param' },
          bar = { type = 'integer', description = 'bar param' },
        },
        required = { 'foo' },
      },
    },
  }
  local errors = tools.validate_scheme(scheme)
  lu.assertEquals(#errors, 0)
end

function TestValidateScheme:testValidSchemeNoRequired()
  local scheme = {
    type = 'function',
    ['function'] = {
      name = 'test_tool',
      description = 'A test tool',
      parameters = {
        type = 'object',
        properties = {
          foo = { type = 'string', description = 'foo param' },
        },
      },
    },
  }
  local errors = tools.validate_scheme(scheme)
  lu.assertEquals(#errors, 0)
end

function TestValidateScheme:testNonTableScheme()
  local errors = tools.validate_scheme('not a table')
  lu.assertEquals(#errors, 1)
  lu.assertStrContains(errors[1], 'must be a table')
end

function TestValidateScheme:testWrongType()
  local scheme = {
    type = 'object',
    ['function'] = {
      name = 'test_tool',
      description = 'desc',
      parameters = { type = 'object', properties = {} },
    },
  }
  local errors = tools.validate_scheme(scheme)
  lu.assertTrue(#errors >= 1)
  lu.assertStrContains(errors[1], 'type must be "function"')
end

function TestValidateScheme:testMissingFunctionTable()
  local scheme = { type = 'function' }
  local errors = tools.validate_scheme(scheme)
  lu.assertTrue(#errors >= 1)
  lu.assertStrContains(errors[1], '["function"] must be a table')
end

function TestValidateScheme:testEmptyName()
  local scheme = {
    type = 'function',
    ['function'] = {
      name = '',
      description = 'desc',
      parameters = { type = 'object', properties = {} },
    },
  }
  local errors = tools.validate_scheme(scheme)
  lu.assertTrue(#errors >= 1)
  lu.assertStrContains(errors[1], 'name must be a non-empty string')
end

function TestValidateScheme:testInvalidNameChars()
  local scheme = {
    type = 'function',
    ['function'] = {
      name = 'test-tool!',
      description = 'desc',
      parameters = { type = 'object', properties = {} },
    },
  }
  local errors = tools.validate_scheme(scheme)
  lu.assertTrue(#errors >= 1)
  lu.assertStrContains(errors[1], 'invalid characters')
end

function TestValidateScheme:testEmptyDescription()
  local scheme = {
    type = 'function',
    ['function'] = {
      name = 'test_tool',
      description = '',
      parameters = { type = 'object', properties = {} },
    },
  }
  local errors = tools.validate_scheme(scheme)
  lu.assertTrue(#errors >= 1)
  lu.assertStrContains(errors[1], 'description must be a non-empty string')
end

function TestValidateScheme:testMissingParameters()
  local scheme = {
    type = 'function',
    ['function'] = {
      name = 'test_tool',
      description = 'desc',
    },
  }
  local errors = tools.validate_scheme(scheme)
  lu.assertTrue(#errors >= 1)
  lu.assertStrContains(errors[1], 'parameters must be a table')
end

function TestValidateScheme:testRequiredReferencesUnknownProperty()
  local scheme = {
    type = 'function',
    ['function'] = {
      name = 'test_tool',
      description = 'desc',
      parameters = {
        type = 'object',
        properties = {
          foo = { type = 'string' },
        },
        required = { 'foo', 'bar' },
      },
    },
  }
  local errors = tools.validate_scheme(scheme)
  lu.assertTrue(#errors >= 1)
  local found = false
  for _, e in ipairs(errors) do
    if e:find('unknown property.*bar') then
      found = true
      break
    end
  end
  lu.assertTrue(found, 'should report unknown property "bar"')
end

function TestValidateScheme:testPropertyMissingType()
  local scheme = {
    type = 'function',
    ['function'] = {
      name = 'test_tool',
      description = 'desc',
      parameters = {
        type = 'object',
        properties = {
          foo = { description = 'no type' },
        },
      },
    },
  }
  local errors = tools.validate_scheme(scheme)
  lu.assertTrue(#errors >= 1)
  lu.assertStrContains(errors[1], 'missing "type" field')
end

function TestValidateScheme:testMultipleErrors()
  local scheme = {
    type = 'object',
    ['function'] = {
      name = '',
      description = '',
      parameters = 'not a table',
    },
  }
  local errors = tools.validate_scheme(scheme)
  lu.assertTrue(#errors >= 3, 'should have at least 3 errors')
end

function TestValidateScheme:testAllBuiltInToolsPassValidation()
  local available = tools.available_tools()
  lu.assertNotNil(available)
  for _, scheme in ipairs(available) do
    local errors = tools.validate_scheme(scheme)
    local name = (scheme['function'] and scheme['function'].name) or 'unknown'
    lu.assertEquals(#errors, 0,
      string.format('Tool "%s" has validation errors:\n  %s',
        name, table.concat(errors, '\n  ')))
  end
end


-- ===== scheme UTF-8 sanitization tests =====
-- MCP tool schemes come from external processes and may contain invalid
-- UTF-8 bytes; they must be sanitized before entering request bodies.

local util = require('chat.util')

TestToolsSchemeSanitize = {}

local function make_scheme(description, prop_description)
  return {
    type = 'function',
    ['function'] = {
      name = 'mcp_test_search',
      description = description,
      parameters = {
        type = 'object',
        properties = {
          query = {
            type = 'string',
            description = prop_description,
          },
        },
        required = { 'query' },
      },
    },
  }
end

function TestToolsSchemeSanitize:testValidSchemeUnchanged()
  local scheme = make_scheme('Search the web for a query', 'The query text')
  local sanitized, had_invalid = tools._sanitize_scheme_strings(scheme, 0)
  lu.assertFalse(had_invalid)
  -- identity preserved: no copy when nothing changed
  lu.assertIs(sanitized, scheme)
  lu.assertEquals(sanitized['function'].description, 'Search the web for a query')
end

function TestToolsSchemeSanitize:testValidMultibytePreserved()
  local scheme = make_scheme('搜索网页内容', '查询关键词')
  local sanitized, had_invalid = tools._sanitize_scheme_strings(scheme, 0)
  lu.assertFalse(had_invalid)
  lu.assertIs(sanitized, scheme)
  lu.assertEquals(sanitized['function'].description, '搜索网页内容')
  lu.assertEquals(
    sanitized['function'].parameters.properties.query.description,
    '查询关键词'
  )
end

function TestToolsSchemeSanitize:testInvalidBytesInDescription()
  -- \xFF and \xFE are invalid UTF-8 leading bytes
  local scheme = make_scheme('Hello \xFF\xFE World', 'ok')
  local sanitized, had_invalid = tools._sanitize_scheme_strings(scheme, 0)
  lu.assertTrue(had_invalid)
  lu.assertNotIs(sanitized, scheme)
  local desc = sanitized['function'].description
  -- round-trip: now valid UTF-8
  local _, still_invalid = util.sanitize_utf8(desc)
  lu.assertFalse(still_invalid)
  lu.assertStrContains(desc, 'Hello')
  lu.assertStrContains(desc, 'World')
  -- replacement character U+FFFD present
  lu.assertStrContains(desc, '\xEF\xBF\xBD')
end

function TestToolsSchemeSanitize:testInvalidBytesInNestedProperty()
  -- '中文' encoded in GBK is invalid UTF-8
  local scheme = make_scheme('ok', '\xD6\xD0\xCE\xC4 description')
  local sanitized, had_invalid = tools._sanitize_scheme_strings(scheme, 0)
  lu.assertTrue(had_invalid)
  local desc = sanitized['function'].parameters.properties.query.description
  local _, still_invalid = util.sanitize_utf8(desc)
  lu.assertFalse(still_invalid)
  lu.assertStrContains(desc, 'description')
end

function TestToolsSchemeSanitize:testInvalidBytesInTableKey()
  local scheme = make_scheme('ok', 'ok')
  scheme['function'].parameters.properties['\xFFkey'] = { type = 'string' }
  local sanitized, had_invalid = tools._sanitize_scheme_strings(scheme, 0)
  lu.assertTrue(had_invalid)
  local props = sanitized['function'].parameters.properties
  -- original invalid key must be gone
  lu.assertNil(props['\xFFkey'])
  -- sanitized key must exist
  lu.assertNotNil(props['\xEF\xBF\xBDkey'])
  -- untouched sibling still fine
  lu.assertNotNil(props.query)
end

function TestToolsSchemeSanitize:testNonStringValuesPreserved()
  local scheme = make_scheme('ok', 'ok')
  scheme['function'].parameters.properties.limit = {
    type = 'integer',
    default = 10,
  }
  local sanitized, had_invalid = tools._sanitize_scheme_strings(scheme, 0)
  lu.assertFalse(had_invalid)
  lu.assertEquals(sanitized['function'].parameters.properties.limit.default, 10)
  lu.assertEquals(sanitized['function'].name, 'mcp_test_search')
  lu.assertEquals(sanitized.type, 'function')
end

function TestToolsSchemeSanitize:testSanitizedSchemeStillValidates()
  local scheme = make_scheme('Bad \xFF description', 'ok')
  local sanitized = tools._sanitize_scheme_strings(scheme, 0)
  local errors = tools.validate_scheme(sanitized)
  lu.assertEquals(#errors, 0)
end

function TestToolsSchemeSanitize:testDeepTableTerminates()
  -- deep nesting + cycle: depth guard must prevent infinite recursion
  local deep = {}
  local cur = deep
  for _ = 1, 20 do
    cur.child = {}
    cur = cur.child
  end
  cur.child = deep
  local sanitized, _ = tools._sanitize_scheme_strings(deep, 0)
  lu.assertNotNil(sanitized)
end

function TestToolsSchemeSanitize:testNilAndScalarValues()
  local n, n_invalid = tools._sanitize_scheme_strings(nil, 0)
  lu.assertIsNil(n)
  lu.assertFalse(n_invalid)

  local num, num_invalid = tools._sanitize_scheme_strings(42, 0)
  lu.assertEquals(num, 42)
  lu.assertFalse(num_invalid)

  local b, b_invalid = tools._sanitize_scheme_strings(true, 0)
  lu.assertTrue(b)
  lu.assertFalse(b_invalid)
end

