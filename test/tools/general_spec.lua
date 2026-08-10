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

