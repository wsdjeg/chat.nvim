-- Tests for tools.normalize_arguments and its wiring into M.call / M.info.
--
-- Models routinely send numbers/booleans as strings ("count": "10",
-- "force": "false") and bare strings for array params. Lua truthiness
-- makes "false" truthy (flag reversal) and comparisons/format calls on
-- numeric strings raise. Normalization at the tools.call entry point
-- coerces values against the tool's own scheme.
--
-- Only dangerous classes are coerced: non-numeric strings for number
-- params and non-string values for string params pass through so the
-- tool's own validation reports them (send_email rejects body = 123).

local lu = require('luaunit')
local tools = require('chat.tools')
local config = require('chat.config')

TestNormalizeArguments = {}

function TestNormalizeArguments:setUp()
  config.setup({
    allowed_path = vim.fs.normalize(vim.fn.getcwd()),
  })
end

-- ===== scheme-driven coercion =====

function TestNormalizeArguments:testBooleanStringsConverted()
  -- git_push.force: the historical "force": "false" → --force reversal
  local args = tools.normalize_arguments('git_push', {
    branch = 'master',
    force = 'false',
  })
  lu.assertEquals(args.branch, 'master')
  lu.assertEquals(args.force, false)

  args = tools.normalize_arguments('git_push', { force = 'true' })
  lu.assertEquals(args.force, true)
end

function TestNormalizeArguments:testBooleanNumbersConverted()
  -- 0 is truthy in Lua but means false to the model
  local args = tools.normalize_arguments('git_push', { force = 0 })
  lu.assertEquals(args.force, false)
  args = tools.normalize_arguments('git_push', { force = 1 })
  lu.assertEquals(args.force, true)
end

function TestNormalizeArguments:testBooleanUnconvertiblePassthrough()
  -- garbage stays garbage: the tool's own validation reports it
  local args = tools.normalize_arguments('git_push', { force = 'yes' })
  lu.assertEquals(args.force, 'yes')
end

function TestNormalizeArguments:testNumericStringsConverted()
  local args = tools.normalize_arguments('git_log', {
    count = '10',
    oneline = 'true',
  })
  lu.assertEquals(args.count, 10)
  lu.assertEquals(args.oneline, true)
end

function TestNormalizeArguments:testNonNumericStringPassthrough()
  local args = tools.normalize_arguments('git_log', { count = 'abc' })
  lu.assertEquals(args.count, 'abc')
end

function TestNormalizeArguments:testStringDeclaredNumberPassthrough()
  -- write_file.mode is declared string: a numeric 644 is NOT coerced,
  -- the tool's own validation rejects it with a clear error
  local args = tools.normalize_arguments('write_file', { mode = 644 })
  lu.assertEquals(args.mode, 644)
end

function TestNormalizeArguments:testAnyOfUntouched()
  -- git_add.paths is anyOf(string | array): never coerced
  local args = tools.normalize_arguments('git_add', { paths = 'a.lua' })
  lu.assertEquals(args.paths, 'a.lua')

  args = tools.normalize_arguments('git_add', { paths = { 'a.lua', 'b.lua' } })
  lu.assertEquals(args, { paths = { 'a.lua', 'b.lua' } })
end

function TestNormalizeArguments:testBareStringWrappedForArray()
  -- search_text.file_types is declared array of string
  local args = tools.normalize_arguments('search_text', { file_types = '*.lua' })
  lu.assertEquals(args.file_types, { '*.lua' })
end

function TestNormalizeArguments:testArrayItemsCoerced()
  -- plan.step_ids is declared array of integer; numeric strings break
  -- reorder_steps' ID comparisons
  local args = tools.normalize_arguments('plan', { step_ids = { '1', '2' } })
  lu.assertEquals(args.step_ids, { 1, 2 })
end

function TestNormalizeArguments:testArrayItemsNullDropped()
  local args = tools.normalize_arguments('plan', {
    step_ids = { 1, vim.NIL, 2 },
  })
  lu.assertEquals(args.step_ids, { 1, 2 })
end

function TestNormalizeArguments:testUnknownPropertyPassthrough()
  local args = tools.normalize_arguments('git_log', { hallucinated = 'x' })
  lu.assertEquals(args.hallucinated, 'x')
end

function TestNormalizeArguments:testJsonNullDropped()
  -- vim.NIL is truthy in Lua; a JSON null must not count as "present"
  local args = tools.normalize_arguments('git_push', {
    branch = 'master',
    tags = vim.NIL,
  })
  lu.assertEquals(args.branch, 'master')
  lu.assertNil(args.tags)
end

function TestNormalizeArguments:testInputTableUntouched()
  -- returns a NEW table, the original is not mutated
  local input = { count = '10' }
  local args = tools.normalize_arguments('git_log', input)
  lu.assertEquals(args.count, 10)
  lu.assertEquals(input.count, '10')
  lu.assertNotIs(args, input)
end

function TestNormalizeArguments:testNonTableArgumentsPassthrough()
  lu.assertNil(tools.normalize_arguments('git_log', nil))
  lu.assertEquals(tools.normalize_arguments('git_log', 'x'), 'x')
end

function TestNormalizeArguments:testUnknownToolPassthrough()
  local args = tools.normalize_arguments('no_such_tool', { count = '10' })
  lu.assertEquals(args.count, '10')
end

-- ===== end-to-end through M.call =====

function TestNormalizeArguments:testCallNormalizesBeforeDispatch()
  -- read_file rejects non-number line_start with its own validation
  -- ('line_start must be a number'); after normalization the numeric
  -- string '1' is accepted and the read succeeds.
  local result = tools.call('read_file', {
    filepath = 'README.md',
    line_start = '1',
    line_to = '2',
  }, { cwd = vim.fs.normalize(vim.fn.getcwd()) })
  lu.assertNil(result.error)
  lu.assertTrue(type(result.content) == 'string')
end

function TestNormalizeArguments:testCallWithoutNormalizationStillValidates()
  -- non-numeric strings are NOT coerced: the tool's own error surfaces
  local result = tools.call('read_file', {
    filepath = 'README.md',
    line_start = 'abc',
  }, { cwd = vim.fs.normalize(vim.fn.getcwd()) })
  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'line_start must be a number')
end

-- ===== end-to-end through M.info =====

local function make_tool_call(name, arguments)
  return {
    id = 'call_test',
    type = 'function',
    ['function'] = {
      name = name,
      arguments = vim.json.encode(arguments),
    },
  }
end

function TestNormalizeArguments:testInfoNormalizesArguments()
  -- git_log.info: count=%d would raise on a non-numeric string; oneline
  -- sent as "false" previously displayed without the oneline=false flag
  local info = tools.info(make_tool_call('git_log', {
    count = '10',
    oneline = 'false',
  }), nil)
  lu.assertStrContains(info, 'count=10')
  lu.assertStrContains(info, 'oneline=false')
end

function TestNormalizeArguments:testInfoNeverRaises()
  -- count="abc" still cannot be formatted by info(); M.info must fall
  -- back to the tool name instead of breaking the rendering pipeline
  local info = tools.info(make_tool_call('git_log', { count = 'abc' }), nil)
  lu.assertEquals(info, 'git_log')
end

function TestNormalizeArguments:testInfoEmptyArguments()
  local info = tools.info(make_tool_call('git_log', {}), nil)
  lu.assertEquals(info, 'git_log')
end

