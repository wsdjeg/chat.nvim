-- test/tools/bitable_spec.lua
-- Covers lua/chat/tools/bitable.lua: argument validation, URL/body building,
-- response mapping, field endpoints, and the two async paths (cached token ->
-- real jobid, cold token -> synthetic handle + cancel).
local lu = require('luaunit')
local tools = require('chat.tools')
local config = require('chat.config')
local curl = require('chat.curl')
local job = require('job')

local bitable = require('chat.tools.bitable')
local auth = require('chat.integrations.lark.auth')
local async = require('chat.sessions.async')

local TOKEN_JSON = vim.json.encode({
  tenant_access_token = 't-abc123',
  expire = 7200,
})

--- Collect jobs whose command line contains `fragment`.
local function find_jobs(fragment)
  local found = {}
  for id, j in pairs(job.jobs) do
    if table.concat(j.cmd, ' '):find(fragment, 1, true) then
      found[#found + 1] = { id = id, job = j }
    end
  end
  return found
end

local function first_job(fragment)
  local found = find_jobs(fragment)
  return found[1] and found[1].job, found[1] and found[1].id
end

TestBitable = {}

function TestBitable:setUp()
  job.reset()
  job.intercept()
  auth.reset()

  self.storage_dir = vim.fn.tempname() .. '_bitable_test/'
  vim.fn.mkdir(self.storage_dir, 'p')
  config.setup({
    storage_dir = self.storage_dir,
    integrations = {
      lark = {
        app_id = 'cli_test_app',
        app_secret = 'secret_test',
      },
    },
  })

  self._orig_available = curl.is_available
  curl.is_available = function()
    return true
  end
  self.cwd = vim.fs.normalize(vim.fn.getcwd())
end

function TestBitable:tearDown()
  curl.is_available = self._orig_available
  job.reset()
  auth.reset()
  vim.fn.delete(self.storage_dir, 'rf')
end

--- Call the tool with a captured callback, assuming it stays synchronous.
local function call(action)
  local result = tools.call('bitable', action, { cwd = vim.fn.getcwd() })
  lu.assertNotNil(result)
  return result
end

-- ─── validation ───────────────────────────────────────────

function TestBitable:testUnknownAction()
  local res = call({ action = 'nope', app_token = 'bascn1' })
  lu.assertNotNil(res.error)
  lu.assertStrContains(res.error, 'Unknown action')
end

function TestBitable:testMissingAppToken()
  local res = call({ action = 'list_tables' })
  lu.assertNotNil(res.error)
  lu.assertStrContains(res.error, 'app_token is required')
end

function TestBitable:testMissingTableId()
  local res = call({ action = 'search', app_token = 'bascn1' })
  lu.assertNotNil(res.error)
  lu.assertStrContains(res.error, 'table_id is required for the search action')
end

function TestBitable:testMissingRecordId()
  local res = call({ action = 'get', app_token = 'b', table_id = 'tbl1' })
  lu.assertNotNil(res.error)
  lu.assertStrContains(res.error, 'record_id is required')
end

function TestBitable:testCreateRequiresFields()
  local res = call({ action = 'create', app_token = 'b', table_id = 'tbl1' })
  lu.assertNotNil(res.error)
  lu.assertStrContains(res.error, 'fields is required for the create action')
end

function TestBitable:testBatchCreateRequiresRecords()
  local res = call({
    action = 'batch_create',
    app_token = 'b',
    table_id = 'tbl1',
    records = {},
  })
  lu.assertNotNil(res.error)
  lu.assertStrContains(res.error, 'records must be a non-empty array')
end

function TestBitable:testCreateFieldRequiresField()
  local res = call({ action = 'create_field', app_token = 'b', table_id = 'tbl1' })
  lu.assertNotNil(res.error)
  lu.assertStrContains(res.error, 'field is required for the create_field action')
end

function TestBitable:testCreateFieldRequiresFieldName()
  local res = call({
    action = 'create_field',
    app_token = 'b',
    table_id = 'tbl1',
    field = { type = 1 },
  })
  lu.assertNotNil(res.error)
  lu.assertStrContains(res.error, 'field.field_name is required')
end

function TestBitable:testCreateFieldRequiresFieldType()
  local res = call({
    action = 'create_field',
    app_token = 'b',
    table_id = 'tbl1',
    field = { field_name = 'Status' },
  })
  lu.assertNotNil(res.error)
  lu.assertStrContains(res.error, 'field.type is required')
end

function TestBitable:testUpdateFieldRequiresFieldId()
  local res = call({
    action = 'update_field',
    app_token = 'b',
    table_id = 'tbl1',
    field = { field_name = 'Status', type = 1 },
  })
  lu.assertNotNil(res.error)
  lu.assertStrContains(res.error, 'field_id is required for the update_field action')
end

function TestBitable:testDeleteFieldRequiresFieldId()
  local res = call({ action = 'delete_field', app_token = 'b', table_id = 'tbl1' })
  lu.assertNotNil(res.error)
  lu.assertStrContains(res.error, 'field_id is required for the delete_field action')
end

function TestBitable:testCurlUnavailable()
  -- validation runs first: a bad argument still reports the argument error
  curl.is_available = function()
    return false
  end
  local res = call({ action = 'list_tables', app_token = 'bascn1' })
  lu.assertNotNil(res.error)
  lu.assertStrContains(res.error, 'curl is not installed')
end

-- ─── cached-token path: URL, method, body ────────────────

function TestBitable:testListTablesUrl()
  auth._set_token('t-cached')
  call({ action = 'list_tables', app_token = 'bascnABC' })

  local j = first_job('bitable/v1/apps/bascnABC/tables')
  lu.assertNotNil(j, 'request job started')
  local cmd = table.concat(j.cmd, ' ')
  lu.assertStrContains(cmd, 'Bearer t-cached')
  -- GET carries no stdin body
  lu.assertNil(j.stdin[1])
  -- stdin was never opened, so it was never closed either
  lu.assertNil(j.stdin_closed)
end

function TestBitable:testGetUrlIncludesRecord()
  auth._set_token('t-cached')
  call({
    action = 'get',
    app_token = 'bascnABC',
    table_id = 'tbl1',
    record_id = 'rec1',
  })
  local j = first_job('tables/tbl1/records/rec1')
  lu.assertNotNil(j, 'record URL composed')
end

function TestBitable:testPaginationQuery()
  auth._set_token('t-cached')
  call({
    action = 'list_fields',
    app_token = 'bascnABC',
    table_id = 'tbl1',
    page_size = 100,
    page_token = 'pg2',
  })
  local j = first_job('/fields?page_token=pg2&page_size=100')
  lu.assertNotNil(j, 'query string composed: ' .. table.concat(j and j.cmd or {}, ' '))
end

function TestBitable:testCreateSendsFieldsOverStdin()
  auth._set_token('t-cached')
  call({
    action = 'create',
    app_token = 'bascnABC',
    table_id = 'tbl1',
    fields = { Name = 'hello', Count = 3 },
  })
  local j = first_job('tables/tbl1/records')
  lu.assertNotNil(j)
  lu.assertNotNil(j.stdin[1], 'body piped to stdin')
  lu.assertTrue(j.stdin_closed, 'stdin closed after body')
  local body = vim.json.decode(j.stdin[1])
  lu.assertEquals(body.fields.Name, 'hello')
  lu.assertEquals(body.fields.Count, 3)
end

function TestBitable:testSearchDefaultsToEmptyBody()
  auth._set_token('t-cached')
  call({ action = 'search', app_token = 'bascnABC', table_id = 'tbl1' })
  local j = first_job('/records/search')
  lu.assertNotNil(j)
  lu.assertNotNil(j.stdin[1])
  lu.assertEquals(vim.json.decode(j.stdin[1]), {})
end

function TestBitable:testSearchPassesRawBody()
  auth._set_token('t-cached')
  call({
    action = 'search',
    app_token = 'bascnABC',
    table_id = 'tbl1',
    body = { field_names = { 'Name' } },
  })
  local j = first_job('/records/search')
  local body = vim.json.decode(j.stdin[1])
  lu.assertEquals(body.field_names, { 'Name' })
end

-- ─── field endpoints ────────────────────────────────────

function TestBitable:testCreateFieldUrlAndBody()
  auth._set_token('t-cached')
  call({
    action = 'create_field',
    app_token = 'bascnABC',
    table_id = 'tbl1',
    field = {
      field_name = 'Status',
      type = 3,
      property = { options = { { name = 'Todo' } } },
    },
  })

  local j = first_job('tables/tbl1/fields')
  lu.assertNotNil(j, 'field URL composed')
  lu.assertStrContains(table.concat(j.cmd, ' '), 'POST')
  lu.assertNotNil(j.stdin[1], 'field definition piped to stdin')

  -- the definition goes at the top level, NOT wrapped in a `fields` key
  local body = vim.json.decode(j.stdin[1])
  lu.assertEquals(body.field_name, 'Status')
  lu.assertEquals(body.type, 3)
  lu.assertEquals(body.property.options[1].name, 'Todo')
  lu.assertNil(body.fields)
end

function TestBitable:testUpdateFieldUrlAndBody()
  auth._set_token('t-cached')
  call({
    action = 'update_field',
    app_token = 'bascnABC',
    table_id = 'tbl1',
    field_id = 'fld1',
    field = { field_name = 'Renamed', type = 1 },
  })

  local j = first_job('tables/tbl1/fields/fld1')
  lu.assertNotNil(j, 'field id in URL')
  lu.assertStrContains(table.concat(j.cmd, ' '), 'PUT')
  local body = vim.json.decode(j.stdin[1])
  lu.assertEquals(body.field_name, 'Renamed')
  lu.assertEquals(body.type, 1)
end

function TestBitable:testDeleteFieldUrlNoBody()
  auth._set_token('t-cached')
  call({
    action = 'delete_field',
    app_token = 'bascnABC',
    table_id = 'tbl1',
    field_id = 'fld1',
  })

  local j = first_job('tables/tbl1/fields/fld1')
  lu.assertNotNil(j, 'field id in URL')
  lu.assertStrContains(table.concat(j.cmd, ' '), 'DELETE')
  lu.assertNil(j.stdin[1], 'DELETE carries no body')
end

-- ─── response mapping ───────────────────────────────────

function TestBitable:testSuccessReturnsData()
  auth._set_token('t-cached')
  local received
  local res = tools.call('bitable', {
    action = 'list_tables',
    app_token = 'bascnABC',
  }, {
    cwd = self.cwd,
    callback = function(r)
      received = r
    end,
  })

  lu.assertNotNil(res.jobid)
  job.emit_stdout(res.jobid, {
    vim.json.encode({ code = 0, data = { items = { { name = 'T1' } } } }),
  })
  job.emit_exit(res.jobid, 0)

  lu.assertNotNil(received)
  lu.assertNil(received.error)
  local data = vim.json.decode(received.content)
  lu.assertEquals(data.items[1].name, 'T1')
  lu.assertEquals(received.jobid, res.jobid)
end

function TestBitable:testApiErrorCode()
  auth._set_token('t-cached')
  local received
  local res = tools.call('bitable', {
    action = 'list_tables',
    app_token = 'bascnABC',
  }, {
    cwd = self.cwd,
    callback = function(r)
      received = r
    end,
  })

  job.emit_stdout(res.jobid, {
    vim.json.encode({
      code = 91403,
      msg = 'Forbidden',
      error = { log_id = 'log-42' },
    }),
  })
  job.emit_exit(res.jobid, 0)

  lu.assertNotNil(received.error)
  lu.assertStrContains(received.error, '91403')
  lu.assertStrContains(received.error, 'log-42')
end

function TestBitable:testNonZeroExitIncludesCurlHint()
  auth._set_token('t-cached')
  local orig_err = curl.get_error_message
  curl.get_error_message = function()
    return 'network hint'
  end

  local received
  local res = tools.call('bitable', {
    action = 'list_tables',
    app_token = 'bascnABC',
  }, {
    cwd = self.cwd,
    callback = function(r)
      received = r
    end,
  })

  job.emit_exit(res.jobid, 6)

  curl.get_error_message = orig_err
  lu.assertNotNil(received.error)
  lu.assertStrContains(received.error, 'exit code: 6')
  lu.assertStrContains(received.error, 'network hint')
end

function TestBitable:testSignalCancelled()
  auth._set_token('t-cached')
  local received
  local res = tools.call('bitable', {
    action = 'list_tables',
    app_token = 'bascnABC',
  }, {
    cwd = self.cwd,
    callback = function(r)
      received = r
    end,
  })

  job.emit_exit(res.jobid, 0, 2)
  lu.assertNotNil(received.error)
  lu.assertStrContains(received.error, 'cancelled by user')
end

function TestBitable:testInvalidJson()
  auth._set_token('t-cached')
  local received
  local res = tools.call('bitable', {
    action = 'list_tables',
    app_token = 'bascnABC',
  }, {
    cwd = self.cwd,
    callback = function(r)
      received = r
    end,
  })

  job.emit_stdout(res.jobid, { 'garbage{{{' })
  job.emit_exit(res.jobid, 0)
  lu.assertNotNil(received.error)
  lu.assertStrContains(received.error, 'Invalid JSON')
end

-- ─── cold token path ────────────────────────────────────

function TestBitable:testColdTokenReturnsSyntheticHandle()
  local res = tools.call('bitable', {
    action = 'list_tables',
    app_token = 'bascnABC',
  }, { cwd = self.cwd })

  lu.assertNil(res.jobid)
  lu.assertNotNil(res.mcp_tool_call_id, 'synthetic async handle reported')
  lu.assertTrue(res.mcp_tool_call_id < 0)
  -- token request started, real request not yet
  lu.assertNotNil(first_job('tenant_access_token'))
  lu.assertNil(first_job('bitable/v1/apps/bascnABC/tables'))
end

function TestBitable:testColdTokenStartsRequestAfterToken()
  local received
  local res = tools.call('bitable', {
    action = 'list_tables',
    app_token = 'bascnABC',
  }, {
    cwd = self.cwd,
    callback = function(r)
      received = r
    end,
  })

  local token_job, token_id = first_job('tenant_access_token')
  lu.assertNotNil(token_job)
  job.emit_stdout(token_id, { TOKEN_JSON })

  local real_job, real_id = first_job('bitable/v1/apps/bascnABC/tables')
  lu.assertNotNil(real_job, 'real request started once the token arrived')
  lu.assertStrContains(table.concat(real_job.cmd, ' '), 'Bearer t-abc123')

  -- the callback still carries the handle the session registered
  job.emit_stdout(real_id, { vim.json.encode({ code = 0, data = {} }) })
  job.emit_exit(real_id, 0)
  lu.assertNotNil(received)
  lu.assertEquals(received.mcp_tool_call_id, res.mcp_tool_call_id)
end

function TestBitable:testColdTokenFailureSurfacesError()
  -- config.setup() merges with tbl_deep_extend, which ignores nil values:
  -- clear the secret on the live config instead.
  config.config.integrations.lark.app_secret = nil
  auth.reset()

  local received
  local res = tools.call('bitable', {
    action = 'list_tables',
    app_token = 'bascnABC',
  }, {
    cwd = self.cwd,
    callback = function(r)
      received = r
    end,
  })

  lu.assertNotNil(res.mcp_tool_call_id)
  lu.assertNotNil(received, 'callback fired immediately on missing credentials')
  lu.assertNotNil(received.error)
  lu.assertStrContains(received.error, 'app_secret')
end

function TestBitable:testCancelWhileWaitingForToken()
  local received
  local res = tools.call('bitable', {
    action = 'create',
    app_token = 'bascnABC',
    table_id = 'tbl1',
    fields = { Name = 'must not be written' },
  }, {
    cwd = self.cwd,
    callback = function(r)
      received = r
    end,
  })

  local handle = res.mcp_tool_call_id
  lu.assertNotNil(handle)

  -- user cancels while the token is still in flight
  lu.assertTrue(async.cancel_handle(handle), 'cancel handler invoked')

  -- the token arrives afterwards: no request may be fired
  local token_job, token_id = first_job('tenant_access_token')
  lu.assertNotNil(token_job)
  job.emit_stdout(token_id, { TOKEN_JSON })

  lu.assertNil(
    first_job('bitable/v1/apps/bascnABC/tables/tbl1/records'),
    'cancelled call must not write to the table'
  )
  lu.assertNil(received, 'no callback after cancellation')
end

function TestBitable:testCancelWhileWaitingForTokenField()
  local received
  local res = tools.call('bitable', {
    action = 'create_field',
    app_token = 'bascnABC',
    table_id = 'tbl1',
    field = { field_name = 'must not be created', type = 1 },
  }, {
    cwd = self.cwd,
    callback = function(r)
      received = r
    end,
  })

  lu.assertTrue(async.cancel_handle(res.mcp_tool_call_id), 'cancel handler invoked')

  local token_job, token_id = first_job('tenant_access_token')
  lu.assertNotNil(token_job)
  job.emit_stdout(token_id, { TOKEN_JSON })

  lu.assertNil(
    first_job('bitable/v1/apps/bascnABC/tables/tbl1/fields'),
    'cancelled call must not create a field'
  )
  lu.assertNil(received, 'no callback after cancellation')
end

-- ─── scheme / info ──────────────────────────────────────

function TestBitable:testScheme()
  local scheme = bitable.scheme()
  lu.assertEquals('function', scheme.type)
  lu.assertEquals('bitable', scheme['function'].name)
  local props = scheme['function'].parameters.properties
  lu.assertEquals('string', props.action.type)
  lu.assertTrue(#props.action.enum >= 12)
  lu.assertEquals({ 'app_token' }, scheme['function'].parameters.required)

  -- field endpoints are exposed to the model
  lu.assertNotNil(props.field_id)
  lu.assertNotNil(props.field)
  local seen = {}
  for _, name in ipairs(props.action.enum) do
    seen[name] = true
  end
  lu.assertTrue(seen.create_field, 'create_field in action enum')
  lu.assertTrue(seen.update_field, 'update_field in action enum')
  lu.assertTrue(seen.delete_field, 'delete_field in action enum')
end

function TestBitable:testInfo()
  local info = bitable.info(vim.json.encode({
    action = 'update',
    app_token = 'bascn1',
    table_id = 'tbl1',
    record_id = 'rec1',
  }))
  lu.assertStrContains(info, 'bitable update')
  lu.assertStrContains(info, 'app=bascn1')
  lu.assertStrContains(info, 'table=tbl1')
  lu.assertStrContains(info, 'record=rec1')
end

function TestBitable:testInfoField()
  local info = bitable.info(vim.json.encode({
    action = 'delete_field',
    app_token = 'bascn1',
    table_id = 'tbl1',
    field_id = 'fld1',
  }))
  lu.assertStrContains(info, 'bitable delete_field')
  lu.assertStrContains(info, 'field=fld1')
end

function TestBitable:testInfoFallback()
  lu.assertEquals('bitable', bitable.info('not json'))
  lu.assertEquals('bitable list_tables', bitable.info(nil))
end

return TestBitable

