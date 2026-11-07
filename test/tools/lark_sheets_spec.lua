-- test/tools/lark_sheets_spec.lua
-- Covers lua/chat/tools/lark_sheets.lua: argument validation, URL/body
-- building, markdown rendering, and the two async paths (cached token ->
-- real jobid, cold token / wiki link -> synthetic handle + cancel).
local lu = require('luaunit')
local tools = require('chat.tools')
local config = require('chat.config')
local curl = require('chat.curl')
local job = require('job')

local lark_sheets = require('chat.tools.lark_sheets')
local auth = require('chat.integrations.lark.auth')
local lark_http = require('chat.integrations.lark.http')
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

TestLarkSheets = {}

function TestLarkSheets:setUp()
  job.reset()
  job.intercept()
  auth.reset()
  lark_http._reset()

  self.storage_dir = vim.fn.tempname() .. '_lark_sheets_test/'
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

function TestLarkSheets:tearDown()
  curl.is_available = self._orig_available
  job.reset()
  auth.reset()
  lark_http._reset()
  vim.fn.delete(self.storage_dir, 'rf')
end

--- Call the tool with a captured callback, assuming it stays synchronous.
local function call(action)
  local result = tools.call('lark_sheets', action, { cwd = vim.fn.getcwd() })
  lu.assertNotNil(result)
  return result
end

-- ─── validation ───────────────────────────────────────────

function TestLarkSheets:testUnknownAction()
  local res = call({ action = 'nope', spreadsheet_token = 'shtcn1' })
  lu.assertNotNil(res.error)
  lu.assertStrContains(res.error, 'Unknown action')
end

function TestLarkSheets:testMissingToken()
  local res = call({ action = 'list_sheets' })
  lu.assertNotNil(res.error)
  lu.assertStrContains(res.error, 'spreadsheet_token (or url) is required')
end

function TestLarkSheets:testMissingRange()
  local res = call({ action = 'read', spreadsheet_token = 'shtcn1' })
  lu.assertNotNil(res.error)
  lu.assertStrContains(res.error, 'range is required for the read action')
end

function TestLarkSheets:testWriteRequiresValues()
  local res = call({
    action = 'write',
    spreadsheet_token = 'shtcn1',
    range = 'Sheet1!A1:B2',
  })
  lu.assertNotNil(res.error)
  lu.assertStrContains(res.error, 'values must be a non-empty 2-D array')
end

function TestLarkSheets:testWriteRejectsNonArrayRow()
  -- Bypass tools.call(): its normalize_arguments step repairs a bare string
  -- into a one-cell row (a deliberate convenience), so the tool's own
  -- validation only ever sees the raw shape when called directly.
  local res = lark_sheets.lark_sheets({
    action = 'write',
    spreadsheet_token = 'shtcn1',
    range = 'Sheet1!A1:B2',
    values = { 'not-a-row' },
  }, { cwd = vim.fn.getcwd() })
  lu.assertNotNil(res.error)
  lu.assertStrContains(res.error, 'values[1] must be an array of cells')
end

function TestLarkSheets:testBatchUpdateRequiresValueRanges()
  local res = call({ action = 'batch_update', spreadsheet_token = 'shtcn1' })
  lu.assertNotNil(res.error)
  lu.assertStrContains(res.error, 'value_ranges must be a non-empty array')
end

function TestLarkSheets:testBatchUpdateEntryRequiresRange()
  local res = call({
    action = 'batch_update',
    spreadsheet_token = 'shtcn1',
    value_ranges = { { values = { { 1 } } } },
  })
  lu.assertNotNil(res.error)
  lu.assertStrContains(res.error, 'value_ranges[1].range is required')
end

function TestLarkSheets:testCreateRequiresTitle()
  local res = call({ action = 'create' })
  lu.assertNotNil(res.error)
  lu.assertStrContains(res.error, 'title is required for the create action')
end

function TestLarkSheets:testUrlPointingAtWrongResource()
  local res = call({
    action = 'read',
    url = 'https://xxx.feishu.cn/docx/doxcnABC',
    range = 'Sheet1!A1:B2',
  })
  lu.assertNotNil(res.error)
  lu.assertStrContains(res.error, 'not a spreadsheet')
end

function TestLarkSheets:testUnrecognisedUrl()
  local res = call({
    action = 'list_sheets',
    url = 'https://example.com/whatever',
  })
  lu.assertNotNil(res.error)
  lu.assertStrContains(res.error, 'Could not recognise')
end

function TestLarkSheets:testCurlUnavailable()
  curl.is_available = function()
    return false
  end
  local res = call({ action = 'list_sheets', spreadsheet_token = 'shtcn1' })
  lu.assertNotNil(res.error)
  lu.assertStrContains(res.error, 'curl is not installed')
end

-- ─── cached-token path: URL, method, body ────────────────

function TestLarkSheets:testListSheetsUrl()
  auth._set_token('t-cached')
  call({ action = 'list_sheets', spreadsheet_token = 'shtcnABC' })

  local j = first_job('sheets/v3/spreadsheets/shtcnABC/sheets/query')
  lu.assertNotNil(j, 'request job started')
  lu.assertStrContains(table.concat(j.cmd, ' '), 'Bearer t-cached')
  -- GET carries no stdin body
  lu.assertNil(j.stdin[1])
  lu.assertNil(j.stdin_closed)
end

function TestLarkSheets:testReadUrlEncodesRange()
  auth._set_token('t-cached')
  call({
    action = 'read',
    spreadsheet_token = 'shtcnABC',
    range = 'My Sheet!A1:B2',
  })

  -- the space must be percent-encoded, or the request line breaks
  local j = first_job('values/My%20Sheet!A1:B2')
  lu.assertNotNil(
    j,
    'range encoded: ' .. table.concat(j and j.cmd or {}, ' ')
  )
end

function TestLarkSheets:testWriteSendsValueRangeOverStdin()
  auth._set_token('t-cached')
  call({
    action = 'write',
    spreadsheet_token = 'shtcnABC',
    range = 'Sheet1!A1:B2',
    values = { { 'Name', 'Age' }, { 'Ann', 3 } },
  })

  local j = first_job('sheets/v2/spreadsheets/shtcnABC/values')
  lu.assertNotNil(j)
  lu.assertStrContains(table.concat(j.cmd, ' '), 'PUT')
  lu.assertNotNil(j.stdin[1], 'body piped to stdin')
  lu.assertTrue(j.stdin_closed, 'stdin closed after body')

  local body = vim.json.decode(j.stdin[1])
  lu.assertEquals(body.valueRange.range, 'Sheet1!A1:B2')
  lu.assertEquals(body.valueRange.values[1][1], 'Name')
  lu.assertEquals(body.valueRange.values[2][2], 3)
end

function TestLarkSheets:testAppendUsesPost()
  auth._set_token('t-cached')
  call({
    action = 'append',
    spreadsheet_token = 'shtcnABC',
    range = 'Sheet1!A1:B2',
    values = { { 'Ann' } },
  })

  local j = first_job('values_append')
  lu.assertNotNil(j)
  lu.assertStrContains(table.concat(j.cmd, ' '), 'POST')
  lu.assertNotNil(j.stdin[1])
end

function TestLarkSheets:testBatchUpdateBodyShape()
  auth._set_token('t-cached')
  call({
    action = 'batch_update',
    spreadsheet_token = 'shtcnABC',
    value_ranges = {
      { range = 'Sheet1!A1:B2', values = { { 1, 2 } } },
      { range = 'Sheet1!D1:E2', values = { { 3, 4 } } },
    },
  })

  local j = first_job('values_batch_update')
  lu.assertNotNil(j)
  local body = vim.json.decode(j.stdin[1])
  lu.assertEquals(#body.valueRanges, 2)
  lu.assertEquals(body.valueRanges[2].range, 'Sheet1!D1:E2')
  lu.assertEquals(body.valueRanges[2].values[1][2], 4)
end

function TestLarkSheets:testCreateHasNoSpreadsheetToken()
  auth._set_token('t-cached')
  call({ action = 'create', title = 'Report' })

  local j = first_job('open-apis/sheets/v3/spreadsheets')
  lu.assertNotNil(j)
  lu.assertStrContains(table.concat(j.cmd, ' '), 'POST')
  local body = vim.json.decode(j.stdin[1])
  lu.assertEquals(body.title, 'Report')
  lu.assertNil(body.folder_token, 'omitted when not given')
end

function TestLarkSheets:testCreateIncludesFolderToken()
  auth._set_token('t-cached')
  call({ action = 'create', title = 'Report', folder_token = 'fldcnX' })

  local j = first_job('open-apis/sheets/v3/spreadsheets')
  local body = vim.json.decode(j.stdin[1])
  lu.assertEquals(body.folder_token, 'fldcnX')
end

-- ─── response mapping ───────────────────────────────────

function TestLarkSheets:testReadRendersMarkdownTable()
  auth._set_token('t-cached')
  local received
  local res = tools.call('lark_sheets', {
    action = 'read',
    spreadsheet_token = 'shtcnABC',
    range = 'Sheet1!A1:B3',
  }, {
    cwd = self.cwd,
    callback = function(r)
      received = r
    end,
  })

  lu.assertNotNil(res.jobid)
  job.emit_stdout(res.jobid, {
    vim.json.encode({
      code = 0,
      data = {
        valueRange = { values = { { 'Name', 'Age' }, { 'Ann', 3 }, { 'Bob', 4 } } },
      },
    }),
  })
  job.emit_exit(res.jobid, 0)

  lu.assertNotNil(received)
  lu.assertNil(received.error)
  lu.assertStrContains(received.content, '| Name | Age |')
  lu.assertStrContains(received.content, '| Ann | 3 |')
  lu.assertStrContains(received.content, '3 row(s) x 2 column(s)')
end

function TestLarkSheets:testReadPadsRaggedRows()
  auth._set_token('t-cached')
  local received
  local res = tools.call('lark_sheets', {
    action = 'read',
    spreadsheet_token = 'shtcnABC',
    range = 'Sheet1!A1:B2',
  }, {
    cwd = self.cwd,
    callback = function(r)
      received = r
    end,
  })

  -- the API drops trailing empty cells, so the second row is short
  job.emit_stdout(res.jobid, {
    vim.json.encode({
      code = 0,
      data = { valueRange = { values = { { 'A', 'B' }, { 'C' } } } },
    }),
  })
  job.emit_exit(res.jobid, 0)

  -- padding keeps the markdown table rectangular
  lu.assertStrContains(received.content, '| C |  |')
end

function TestLarkSheets:testListSheetsRendersSummary()
  auth._set_token('t-cached')
  local received
  local res = tools.call('lark_sheets', {
    action = 'list_sheets',
    spreadsheet_token = 'shtcnABC',
  }, {
    cwd = self.cwd,
    callback = function(r)
      received = r
    end,
  })

  job.emit_stdout(res.jobid, {
    vim.json.encode({
      code = 0,
      data = {
        sheets = {
          {
            title = 'Sheet1',
            sheet_id = 'sid1',
            grid_properties = { row_count = 10, column_count = 5 },
          },
        },
      },
    }),
  })
  job.emit_exit(res.jobid, 0)

  lu.assertStrContains(received.content, 'Sheet1')
  lu.assertStrContains(received.content, 'sheet_id: sid1')
  lu.assertStrContains(received.content, '10 row(s) x 5 column(s)')
end

function TestLarkSheets:testApiErrorCode()
  auth._set_token('t-cached')
  local received
  local res = tools.call('lark_sheets', {
    action = 'list_sheets',
    spreadsheet_token = 'shtcnABC',
  }, {
    cwd = self.cwd,
    callback = function(r)
      received = r
    end,
  })

  job.emit_stdout(res.jobid, {
    vim.json.encode({ code = 91403, msg = 'Forbidden', error = { log_id = 'log-7' } }),
  })
  job.emit_exit(res.jobid, 0)

  lu.assertNotNil(received.error)
  lu.assertStrContains(received.error, '91403')
  lu.assertStrContains(received.error, 'log-7')
end

function TestLarkSheets:testInvalidJson()
  auth._set_token('t-cached')
  local received
  local res = tools.call('lark_sheets', {
    action = 'list_sheets',
    spreadsheet_token = 'shtcnABC',
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

function TestLarkSheets:testSignalCancelled()
  auth._set_token('t-cached')
  local received
  local res = tools.call('lark_sheets', {
    action = 'list_sheets',
    spreadsheet_token = 'shtcnABC',
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

-- ─── cold token path ────────────────────────────────────

function TestLarkSheets:testColdTokenReturnsSyntheticHandle()
  local res = call({ action = 'list_sheets', spreadsheet_token = 'shtcnABC' })

  lu.assertNil(res.jobid)
  lu.assertNotNil(res.mcp_tool_call_id, 'synthetic async handle reported')
  lu.assertTrue(res.mcp_tool_call_id < 0)
  lu.assertNotNil(first_job('tenant_access_token'))
  lu.assertNil(first_job('sheets/v3/spreadsheets/shtcnABC'))
end

function TestLarkSheets:testColdTokenStartsRequestAfterToken()
  local received
  local res = tools.call('lark_sheets', {
    action = 'list_sheets',
    spreadsheet_token = 'shtcnABC',
  }, {
    cwd = self.cwd,
    callback = function(r)
      received = r
    end,
  })

  local _, token_id = first_job('tenant_access_token')
  lu.assertNotNil(token_id)
  job.emit_stdout(token_id, { TOKEN_JSON })

  local real_job, real_id = first_job('sheets/v3/spreadsheets/shtcnABC')
  lu.assertNotNil(real_job, 'real request started once the token arrived')
  lu.assertStrContains(table.concat(real_job.cmd, ' '), 'Bearer t-abc123')

  job.emit_stdout(real_id, { vim.json.encode({ code = 0, data = {} }) })
  job.emit_exit(real_id, 0)
  lu.assertNotNil(received)
  lu.assertEquals(received.mcp_tool_call_id, res.mcp_tool_call_id)
end

function TestLarkSheets:testColdTokenFailureSurfacesError()
  config.config.integrations.lark.app_secret = nil
  auth.reset()

  local received
  local res = tools.call('lark_sheets', {
    action = 'list_sheets',
    spreadsheet_token = 'shtcnABC',
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

function TestLarkSheets:testCancelWhileWaitingForToken()
  local received
  local res = tools.call('lark_sheets', {
    action = 'write',
    spreadsheet_token = 'shtcnABC',
    range = 'Sheet1!A1',
    values = { { 'must not be written' } },
  }, {
    cwd = self.cwd,
    callback = function(r)
      received = r
    end,
  })

  lu.assertTrue(async.cancel_handle(res.mcp_tool_call_id), 'cancel handler invoked')

  local _, token_id = first_job('tenant_access_token')
  lu.assertNotNil(token_id)
  job.emit_stdout(token_id, { TOKEN_JSON })

  lu.assertNil(
    first_job('sheets/v2/spreadsheets/shtcnABC/values'),
    'cancelled call must not write to the sheet'
  )
  lu.assertNil(received, 'no callback after cancellation')
end

-- ─── wiki link path ─────────────────────────────────────

function TestLarkSheets:testWikiLinkResolvesBeforeRequest()
  auth._set_token('t-cached')
  local res = call({
    action = 'list_sheets',
    url = 'https://xxx.feishu.cn/wiki/wikcnNODE',
  })

  lu.assertNil(res.jobid, 'the final jobid is unknown up front')
  lu.assertNotNil(res.mcp_tool_call_id)
  lu.assertNotNil(first_job('wiki/v2/spaces/get_node?token=wikcnNODE'))
  lu.assertNil(first_job('sheets/v3/spreadsheets/'), 'real request waits')
end

function TestLarkSheets:testWikiLinkStartsRequestWithResolvedToken()
  auth._set_token('t-cached')
  local received
  local res = tools.call('lark_sheets', {
    action = 'list_sheets',
    url = 'https://xxx.feishu.cn/wiki/wikcnNODE',
  }, {
    cwd = self.cwd,
    callback = function(r)
      received = r
    end,
  })

  local _, wiki_id = first_job('get_node?token=wikcnNODE')
  job.emit_stdout(wiki_id, {
    vim.json.encode({
      code = 0,
      data = { node = { obj_type = 'sheet', obj_token = 'shtcnReal', title = 'Q1' } },
    }),
  })
  job.emit_exit(wiki_id, 0)

  local real_job = first_job('sheets/v3/spreadsheets/shtcnReal/sheets/query')
  lu.assertNotNil(real_job, 'the resolved obj_token is used, not the node_token')

  local _, real_id = first_job('sheets/v3/spreadsheets/shtcnReal')
  job.emit_stdout(real_id, { vim.json.encode({ code = 0, data = { sheets = {} } }) })
  job.emit_exit(real_id, 0)
  lu.assertNotNil(received)
  lu.assertEquals(received.mcp_tool_call_id, res.mcp_tool_call_id)
end

function TestLarkSheets:testWikiLinkPointingAtDocumentIsRejected()
  auth._set_token('t-cached')
  local received
  local res = tools.call('lark_sheets', {
    action = 'read',
    url = 'https://xxx.feishu.cn/wiki/wikcnNODE',
    range = 'Sheet1!A1:B2',
  }, {
    cwd = self.cwd,
    callback = function(r)
      received = r
    end,
  })

  local _, wiki_id = first_job('get_node?token=wikcnNODE')
  job.emit_stdout(wiki_id, {
    vim.json.encode({
      code = 0,
      data = { node = { obj_type = 'docx', obj_token = 'doxcnX' } },
    }),
  })
  job.emit_exit(wiki_id, 0)

  lu.assertNotNil(received.error)
  lu.assertStrContains(received.error, 'not a spreadsheet')
  lu.assertNil(first_job('sheets/v2/spreadsheets/doxcnX'), 'no request fired')
end

function TestLarkSheets:testWikiNodeApiError()
  auth._set_token('t-cached')
  local received
  local res = tools.call('lark_sheets', {
    action = 'list_sheets',
    url = 'https://xxx.feishu.cn/wiki/wikcnNODE',
  }, {
    cwd = self.cwd,
    callback = function(r)
      received = r
    end,
  })

  local _, wiki_id = first_job('get_node?token=wikcnNODE')
  job.emit_stdout(wiki_id, {
    vim.json.encode({ code = 131006, msg = 'node not found' }),
  })
  job.emit_exit(wiki_id, 0)

  lu.assertNotNil(received.error)
  lu.assertStrContains(received.error, '131006')
end

function TestLarkSheets:testCancelWhileResolvingWiki()
  auth._set_token('t-cached')
  local received
  local res = tools.call('lark_sheets', {
    action = 'write',
    url = 'https://xxx.feishu.cn/wiki/wikcnNODE',
    range = 'Sheet1!A1',
    values = { { 'nope' } },
  }, {
    cwd = self.cwd,
    callback = function(r)
      received = r
    end,
  })

  lu.assertTrue(async.cancel_handle(res.mcp_tool_call_id), 'cancel handler invoked')

  local _, wiki_id = first_job('get_node?token=wikcnNODE')
  job.emit_stdout(wiki_id, {
    vim.json.encode({
      code = 0,
      data = { node = { obj_type = 'sheet', obj_token = 'shtcnReal' } },
    }),
  })
  job.emit_exit(wiki_id, 0)

  lu.assertNil(first_job('sheets/v2/spreadsheets/shtcnReal'), 'no write after cancel')
  lu.assertNil(received)
end

-- ─── scheme / info ──────────────────────────────────────

function TestLarkSheets:testScheme()
  local scheme = lark_sheets.scheme()
  lu.assertEquals('function', scheme.type)
  lu.assertEquals('lark_sheets', scheme['function'].name)
  local props = scheme['function'].parameters.properties
  lu.assertNotNil(props.action)
  lu.assertNotNil(props.url)
  lu.assertNotNil(props.spreadsheet_token)
  lu.assertNotNil(props.range)
  lu.assertNotNil(props.values)
  lu.assertNotNil(props.value_ranges)
  lu.assertNotNil(props.title)

  local seen = {}
  for _, name in ipairs(props.action.enum) do
    seen[name] = true
  end
  for _, name in ipairs({ 'list_sheets', 'read', 'write', 'append', 'batch_update', 'create' }) do
    lu.assertTrue(seen[name], name .. ' in action enum')
  end
end

function TestLarkSheets:testInfo()
  local info = lark_sheets.info(vim.json.encode({
    action = 'read',
    spreadsheet_token = 'shtcn1',
    range = 'Sheet1!A1:B2',
  }))
  lu.assertStrContains(info, 'lark_sheets read')
  lu.assertStrContains(info, 'sheet=shtcn1')
  lu.assertStrContains(info, 'range=Sheet1!A1:B2')
end

function TestLarkSheets:testInfoFallsBackToUrl()
  local info = lark_sheets.info(vim.json.encode({
    action = 'list_sheets',
    url = 'https://x.feishu.cn/sheets/shtcn1',
  }))
  lu.assertStrContains(info, 'lark_sheets list_sheets')
  lu.assertStrContains(info, 'url=https://x.feishu.cn/sheets/shtcn1')
end

function TestLarkSheets:testInfoFallback()
  lu.assertEquals('lark_sheets', lark_sheets.info('not json'))
  lu.assertEquals('lark_sheets list_sheets', lark_sheets.info(nil))
end

function TestLarkSheets:testToMarkdownEmptyRows()
  lu.assertEquals(
    '(empty range: Sheet1!A1:B2)',
    lark_sheets._to_markdown({}, 'Sheet1!A1:B2')
  )
end

function TestLarkSheets:testToMarkdownEscapesPipes()
  local md = lark_sheets._to_markdown({ { 'a|b' }, { 'c' } })
  lu.assertStrContains(md, '\\|')
end

return TestLarkSheets

