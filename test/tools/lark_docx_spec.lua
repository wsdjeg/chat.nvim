-- test/tools/lark_docx_spec.lua
-- Covers lua/chat/tools/lark_docx.lua: argument validation, URL/body
-- building, the text->blocks conversion, the block-tree->markdown flatten,
-- and the two async paths (cached token -> real jobid, cold token / wiki
-- link -> synthetic handle + cancel).
local lu = require('luaunit')
local tools = require('chat.tools')
local config = require('chat.config')
local curl = require('chat.curl')
local job = require('job')

local lark_docx = require('chat.tools.lark_docx')
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

--- A text_run payload, the shape every text-ish docx block uses.
local function run(content)
  return { elements = { { text_run = { content = content } } } }
end

TestLarkDocx = {}

function TestLarkDocx:setUp()
  job.reset()
  job.intercept()
  auth.reset()
  lark_http._reset()

  self.storage_dir = vim.fn.tempname() .. '_lark_docx_test/'
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

function TestLarkDocx:tearDown()
  curl.is_available = self._orig_available
  job.reset()
  auth.reset()
  lark_http._reset()
  vim.fn.delete(self.storage_dir, 'rf')
end

--- Call the tool with a captured callback, assuming it stays synchronous.
local function call(action)
  local result = tools.call('lark_docx', action, { cwd = vim.fn.getcwd() })
  lu.assertNotNil(result)
  return result
end

-- ─── validation ───────────────────────────────────────────

function TestLarkDocx:testUnknownAction()
  local res = call({ action = 'nope', document_id = 'doxcn1' })
  lu.assertNotNil(res.error)
  lu.assertStrContains(res.error, 'Unknown action')
end

function TestLarkDocx:testMissingDocumentId()
  local res = call({ action = 'read' })
  lu.assertNotNil(res.error)
  lu.assertStrContains(res.error, 'document_id (or url) is required')
end

function TestLarkDocx:testUpdateBlockRequiresBlockId()
  local res = call({ action = 'update_block', document_id = 'doxcn1' })
  lu.assertNotNil(res.error)
  lu.assertStrContains(res.error, 'block_id is required for the update_block action')
end

function TestLarkDocx:testDeleteBlockRequiresBlockId()
  local res = call({ action = 'delete_block', document_id = 'doxcn1' })
  lu.assertNotNil(res.error)
  lu.assertStrContains(res.error, 'block_id is required for the delete_block action')
end

function TestLarkDocx:testUpdateBlockRequiresBlock()
  local res = call({
    action = 'update_block',
    document_id = 'doxcn1',
    block_id = 'blk1',
  })
  lu.assertNotNil(res.error)
  lu.assertStrContains(res.error, 'block is required for the update_block action')
end

function TestLarkDocx:testAppendRequiresTextOrBlocks()
  local res = call({ action = 'append', document_id = 'doxcn1' })
  lu.assertNotNil(res.error)
  lu.assertStrContains(res.error, 'Provide either blocks')
end

function TestLarkDocx:testAppendRejectsBlockWithoutType()
  -- Bypass tools.call(): normalize_arguments would coerce the string
  -- block_type into a number, which is exactly what the tool accepts.
  local res = lark_docx.lark_docx({
    action = 'append',
    document_id = 'doxcn1',
    blocks = { { text = run('no type') } },
  }, { cwd = vim.fn.getcwd() })
  lu.assertNotNil(res.error)
  lu.assertStrContains(res.error, 'blocks[1].block_type is required')
end

function TestLarkDocx:testAppendRejectsEmptyText()
  local res = call({ action = 'append', document_id = 'doxcn1', text = '\n\n  \n' })
  lu.assertNotNil(res.error)
  lu.assertStrContains(res.error, 'text contains no content to append')
end

function TestLarkDocx:testCreateRequiresTitle()
  local res = call({ action = 'create' })
  lu.assertNotNil(res.error)
  lu.assertStrContains(res.error, 'title is required for the create action')
end

function TestLarkDocx:testUrlPointingAtWrongResource()
  local res = call({
    action = 'read',
    url = 'https://xxx.feishu.cn/sheets/shtcnABC',
  })
  lu.assertNotNil(res.error)
  lu.assertStrContains(res.error, 'not a cloud document')
end

function TestLarkDocx:testUnrecognisedUrl()
  local res = call({ action = 'read', url = 'https://example.com/x' })
  lu.assertNotNil(res.error)
  lu.assertStrContains(res.error, 'Could not recognise')
end

function TestLarkDocx:testCurlUnavailable()
  curl.is_available = function()
    return false
  end
  local res = call({ action = 'read', document_id = 'doxcn1' })
  lu.assertNotNil(res.error)
  lu.assertStrContains(res.error, 'curl is not installed')
end

-- ─── cached-token path: URL, method, body ────────────────

function TestLarkDocx:testGetUrl()
  auth._set_token('t-cached')
  call({ action = 'get', document_id = 'doxcnABC' })

  local j = first_job('docx/v1/documents/doxcnABC')
  lu.assertNotNil(j, 'request job started')
  lu.assertStrContains(table.concat(j.cmd, ' '), 'Bearer t-cached')
  lu.assertNil(j.stdin[1], 'GET carries no body')
  lu.assertNil(j.stdin_closed)
end

function TestLarkDocx:testReadUrlHasPagination()
  auth._set_token('t-cached')
  call({ action = 'read', document_id = 'doxcnABC' })

  local j = first_job('docx/v1/documents/doxcnABC/blocks?page_size=500')
  lu.assertNotNil(j, 'default page size applied')
  lu.assertNil(j.stdin[1])
end

function TestLarkDocx:testReadUrlForwardsPageToken()
  auth._set_token('t-cached')
  call({
    action = 'read',
    document_id = 'doxcnABC',
    page_size = 100,
    page_token = 'pg2',
  })

  local j = first_job('blocks?page_token=pg2&page_size=100')
  lu.assertNotNil(j, 'query string composed: ' .. table.concat(j and j.cmd or {}, ' '))
end

function TestLarkDocx:testAppendDefaultsToRootBlock()
  auth._set_token('t-cached')
  call({ action = 'append', document_id = 'doxcnABC', text = 'hello' })

  -- no block_id means "append to the document root", whose id is the doc id
  local j = first_job('docx/v1/documents/doxcnABC/blocks/doxcnABC/children')
  lu.assertNotNil(j, 'root block id reused as the parent')
  lu.assertStrContains(table.concat(j.cmd, ' '), 'POST')
  lu.assertNotNil(j.stdin[1])
  lu.assertTrue(j.stdin_closed, 'stdin closed after body')
end

function TestLarkDocx:testAppendUsesExplicitParent()
  auth._set_token('t-cached')
  call({
    action = 'append',
    document_id = 'doxcnABC',
    block_id = 'blkParent',
    text = 'hello',
  })

  local j = first_job('/blocks/blkParent/children')
  lu.assertNotNil(j, 'parent block id in URL')
end

function TestLarkDocx:testAppendConvertsTextToBlocks()
  auth._set_token('t-cached')
  call({
    action = 'append',
    document_id = 'doxcnABC',
    text = '# Title\n- point\n1. first\nplain line',
  })

  local j = first_job('docx/v1/documents/doxcnABC/blocks/doxcnABC/children')
  local body = vim.json.decode(j.stdin[1])
  lu.assertEquals(#body.children, 4)
  lu.assertEquals(body.children[1].block_type, 3)
  lu.assertEquals(body.children[1].heading1.elements[1].text_run.content, 'Title')
  lu.assertEquals(body.children[2].block_type, 12)
  lu.assertEquals(body.children[2].bullet.elements[1].text_run.content, 'point')
  lu.assertEquals(body.children[3].block_type, 13)
  lu.assertEquals(body.children[3].ordered.elements[1].text_run.content, 'first')
  lu.assertEquals(body.children[4].block_type, 2)
  lu.assertEquals(body.children[4].text.elements[1].text_run.content, 'plain line')
  lu.assertEquals(body.index, 0)
end

function TestLarkDocx:testAppendPassesRawBlocksUntouched()
  auth._set_token('t-cached')
  local raw = { { block_type = 2, text = run('raw') } }
  call({ action = 'append', document_id = 'doxcnABC', blocks = raw })

  local j = first_job('/children')
  local body = vim.json.decode(j.stdin[1])
  lu.assertEquals(body.children[1].block_type, 2)
  lu.assertEquals(body.children[1].text.elements[1].text_run.content, 'raw')
end

function TestLarkDocx:testUpdateBlockUsesPatch()
  auth._set_token('t-cached')
  call({
    action = 'update_block',
    document_id = 'doxcnABC',
    block_id = 'blk1',
    block = { block_type = 2, text = run('new') },
  })

  local j = first_job('docx/v1/documents/doxcnABC/blocks/blk1')
  lu.assertNotNil(j)
  lu.assertStrContains(table.concat(j.cmd, ' '), 'PATCH')
  -- the replacement block goes at the top level, not wrapped
  local body = vim.json.decode(j.stdin[1])
  lu.assertEquals(body.block_type, 2)
  lu.assertNil(body.block)
end

function TestLarkDocx:testDeleteBlockUsesDelete()
  auth._set_token('t-cached')
  call({ action = 'delete_block', document_id = 'doxcnABC', block_id = 'blk1' })

  local j = first_job('docx/v1/documents/doxcnABC/blocks/blk1')
  lu.assertNotNil(j)
  lu.assertStrContains(table.concat(j.cmd, ' '), 'DELETE')
  lu.assertNil(j.stdin[1], 'DELETE carries no body')
end

function TestLarkDocx:testCreateBody()
  auth._set_token('t-cached')
  call({ action = 'create', title = 'Report', folder_token = 'fldcnX' })

  local j = first_job('open-apis/docx/v1/documents')
  lu.assertNotNil(j)
  local body = vim.json.decode(j.stdin[1])
  lu.assertEquals(body.title, 'Report')
  lu.assertEquals(body.folder_token, 'fldcnX')
end

function TestLarkDocx:testCreateOmitsEmptyFolderToken()
  auth._set_token('t-cached')
  call({ action = 'create', title = 'Report' })

  local j = first_job('open-apis/docx/v1/documents')
  local body = vim.json.decode(j.stdin[1])
  lu.assertNil(body.folder_token)
end

-- ─── response mapping ───────────────────────────────────

function TestLarkDocx:testReadFlattensBlocksToMarkdown()
  auth._set_token('t-cached')
  local received
  local res = tools.call('lark_docx', {
    action = 'read',
    document_id = 'doxcnABC',
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
        items = {
          { block_id = 'doxcnABC', block_type = 1, children = { 'h1', 'b1' } },
          { block_id = 'h1', block_type = 3, heading1 = run('Title') },
          { block_id = 'b1', block_type = 12, bullet = run('point') },
        },
      },
    }),
  })
  job.emit_exit(res.jobid, 0)

  lu.assertNotNil(received)
  lu.assertNil(received.error)
  lu.assertStrContains(received.content, '# Title')
  lu.assertStrContains(received.content, '- point')
end

function TestLarkDocx:testReadNestsChildBlocks()
  auth._set_token('t-cached')
  local received
  local res = tools.call('lark_docx', {
    action = 'read',
    document_id = 'doxcnABC',
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
        items = {
          { block_id = 'doxcnABC', block_type = 1, children = { 'b1' } },
          { block_id = 'b1', block_type = 12, bullet = run('parent'), children = { 'b2' } },
          { block_id = 'b2', block_type = 12, bullet = run('child') },
        },
      },
    }),
  })
  job.emit_exit(res.jobid, 0)

  -- children of a list item indent one level
  lu.assertStrContains(received.content, '- parent')
  lu.assertStrContains(received.content, '  - child')
end

function TestLarkDocx:testReadWithoutTreeKeepsApiOrder()
  auth._set_token('t-cached')
  local received
  local res = tools.call('lark_docx', {
    action = 'read',
    document_id = 'doxcnABC',
  }, {
    cwd = self.cwd,
    callback = function(r)
      received = r
    end,
  })

  -- Partial pages return blocks whose parent is on a previous page, so the
  -- tree links are incomplete: the API order is the fallback.
  job.emit_stdout(res.jobid, {
    vim.json.encode({
      code = 0,
      data = {
        items = {
          { block_id = 'b1', block_type = 2, text = run('first') },
          { block_id = 'b2', block_type = 2, text = run('second') },
        },
      },
    }),
  })
  job.emit_exit(res.jobid, 0)

  local first_at = received.content:find('first', 1, true)
  local second_at = received.content:find('second', 1, true)
  lu.assertTrue(first_at < second_at, 'document order preserved')
end

function TestLarkDocx:testReadNotesContinuation()
  auth._set_token('t-cached')
  local received
  local res = tools.call('lark_docx', {
    action = 'read',
    document_id = 'doxcnABC',
  }, {
    cwd = self.cwd,
    callback = function(r)
      received = r
    end,
  })

  job.emit_stdout(res.jobid, {
    vim.json.encode({
      code = 0,
      data = { items = { { block_id = 'b1', block_type = 2, text = run('hi') } }, has_more = true, page_token = 'next1' },
    }),
  })
  job.emit_exit(res.jobid, 0)

  lu.assertStrContains(received.content, 'document continues')
  lu.assertStrContains(received.content, 'next1')
end

function TestLarkDocx:testReadEmptyDocument()
  auth._set_token('t-cached')
  local received
  local res = tools.call('lark_docx', {
    action = 'read',
    document_id = 'doxcnABC',
  }, {
    cwd = self.cwd,
    callback = function(r)
      received = r
    end,
  })

  job.emit_stdout(res.jobid, { vim.json.encode({ code = 0, data = { items = {} } }) })
  job.emit_exit(res.jobid, 0)
  lu.assertEquals('(empty document)', received.content)
end

function TestLarkDocx:testGetRendersMetadata()
  auth._set_token('t-cached')
  local received
  local res = tools.call('lark_docx', {
    action = 'get',
    document_id = 'doxcnABC',
  }, {
    cwd = self.cwd,
    callback = function(r)
      received = r
    end,
  })

  job.emit_stdout(res.jobid, {
    vim.json.encode({
      code = 0,
      data = { document = { document_id = 'doxcnABC', title = 'Q1 Report', revision_id = 7 } },
    }),
  })
  job.emit_exit(res.jobid, 0)

  lu.assertStrContains(received.content, 'Q1 Report')
  lu.assertStrContains(received.content, 'revision: 7')
end

function TestLarkDocx:testAppendReportsBlockCount()
  auth._set_token('t-cached')
  local received
  local res = tools.call('lark_docx', {
    action = 'append',
    document_id = 'doxcnABC',
    text = 'a\nb',
  }, {
    cwd = self.cwd,
    callback = function(r)
      received = r
    end,
  })

  job.emit_stdout(res.jobid, {
    vim.json.encode({ code = 0, data = { children = { {}, {} } } }),
  })
  job.emit_exit(res.jobid, 0)
  lu.assertStrContains(received.content, 'appended 2 block(s)')
end

function TestLarkDocx:testCreateReportsDocumentId()
  auth._set_token('t-cached')
  local received
  local res = tools.call('lark_docx', {
    action = 'create',
    title = 'New Doc',
  }, {
    cwd = self.cwd,
    callback = function(r)
      received = r
    end,
  })

  job.emit_stdout(res.jobid, {
    vim.json.encode({ code = 0, data = { document = { document_id = 'doxcnNew', title = 'New Doc' } } }),
  })
  job.emit_exit(res.jobid, 0)

  lu.assertStrContains(received.content, 'New Doc')
  lu.assertStrContains(received.content, 'doxcnNew')
end

function TestLarkDocx:testApiErrorCode()
  auth._set_token('t-cached')
  local received
  local res = tools.call('lark_docx', {
    action = 'get',
    document_id = 'doxcnABC',
  }, {
    cwd = self.cwd,
    callback = function(r)
      received = r
    end,
  })

  job.emit_stdout(res.jobid, {
    vim.json.encode({ code = 91403, msg = 'Forbidden', error = { log_id = 'log-9' } }),
  })
  job.emit_exit(res.jobid, 0)

  lu.assertNotNil(received.error)
  lu.assertStrContains(received.error, '91403')
  lu.assertStrContains(received.error, 'log-9')
end

function TestLarkDocx:testInvalidJson()
  auth._set_token('t-cached')
  local received
  local res = tools.call('lark_docx', {
    action = 'get',
    document_id = 'doxcnABC',
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

function TestLarkDocx:testSignalCancelled()
  auth._set_token('t-cached')
  local received
  local res = tools.call('lark_docx', {
    action = 'get',
    document_id = 'doxcnABC',
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

function TestLarkDocx:testColdTokenReturnsSyntheticHandle()
  local res = call({ action = 'get', document_id = 'doxcnABC' })

  lu.assertNil(res.jobid)
  lu.assertNotNil(res.mcp_tool_call_id, 'synthetic async handle reported')
  lu.assertTrue(res.mcp_tool_call_id < 0)
  lu.assertNotNil(first_job('tenant_access_token'))
  lu.assertNil(first_job('docx/v1/documents/doxcnABC'))
end

function TestLarkDocx:testColdTokenStartsRequestAfterToken()
  local received
  local res = tools.call('lark_docx', {
    action = 'get',
    document_id = 'doxcnABC',
  }, {
    cwd = self.cwd,
    callback = function(r)
      received = r
    end,
  })

  local _, token_id = first_job('tenant_access_token')
  lu.assertNotNil(token_id)
  job.emit_stdout(token_id, { TOKEN_JSON })

  local real_job, real_id = first_job('docx/v1/documents/doxcnABC')
  lu.assertNotNil(real_job, 'real request started once the token arrived')
  lu.assertStrContains(table.concat(real_job.cmd, ' '), 'Bearer t-abc123')

  job.emit_stdout(real_id, { vim.json.encode({ code = 0, data = {} }) })
  job.emit_exit(real_id, 0)
  lu.assertNotNil(received)
  lu.assertEquals(received.mcp_tool_call_id, res.mcp_tool_call_id)
end

function TestLarkDocx:testColdTokenFailureSurfacesError()
  config.config.integrations.lark.app_secret = nil
  auth.reset()

  local received
  local res = tools.call('lark_docx', {
    action = 'get',
    document_id = 'doxcnABC',
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

function TestLarkDocx:testCancelWhileWaitingForToken()
  local received
  local res = tools.call('lark_docx', {
    action = 'append',
    document_id = 'doxcnABC',
    text = 'must not be written',
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
    first_job('blocks/doxcnABC/children'),
    'cancelled call must not write to the document'
  )
  lu.assertNil(received, 'no callback after cancellation')
end

-- ─── wiki link path ─────────────────────────────────────

function TestLarkDocx:testWikiLinkResolvesBeforeRequest()
  auth._set_token('t-cached')
  local res = call({
    action = 'get',
    url = 'https://xxx.feishu.cn/wiki/wikcnNODE',
  })

  lu.assertNil(res.jobid, 'the final jobid is unknown up front')
  lu.assertNotNil(res.mcp_tool_call_id)
  lu.assertNotNil(first_job('wiki/v2/spaces/get_node?token=wikcnNODE'))
  lu.assertNil(first_job('docx/v1/documents/'), 'real request waits')
end

function TestLarkDocx:testWikiLinkStartsRequestWithResolvedToken()
  auth._set_token('t-cached')
  local received
  local res = tools.call('lark_docx', {
    action = 'get',
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
      data = { node = { obj_type = 'docx', obj_token = 'doxcnReal', title = 'Doc' } },
    }),
  })
  job.emit_exit(wiki_id, 0)

  local real_job = first_job('docx/v1/documents/doxcnReal')
  lu.assertNotNil(real_job, 'the resolved obj_token is used, not the node_token')

  local _, real_id = first_job('docx/v1/documents/doxcnReal')
  job.emit_stdout(real_id, {
    vim.json.encode({
      code = 0,
      data = { document = { document_id = 'doxcnReal', title = 'Doc' } },
    }),
  })
  job.emit_exit(real_id, 0)
  lu.assertNotNil(received)
  -- the resolved id must reach the renderer, not the empty placeholder
  lu.assertStrContains(received.content, 'doxcnReal')
end

function TestLarkDocx:testWikiLinkPointingAtSheetIsRejected()
  auth._set_token('t-cached')
  local received
  local res = tools.call('lark_docx', {
    action = 'read',
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
      data = { node = { obj_type = 'sheet', obj_token = 'shtcnX' } },
    }),
  })
  job.emit_exit(wiki_id, 0)

  lu.assertNotNil(received.error)
  lu.assertStrContains(received.error, 'not a cloud document')
  lu.assertNil(first_job('docx/v1/documents/shtcnX'), 'no request fired')
end

-- ─── text -> blocks conversion ─────────────────────────

function TestLarkDocx:testTextToBlocksHeadings()
  local blocks = lark_docx._text_to_blocks('# One\n## Two\n###### Six')
  lu.assertEquals(3, #blocks)
  lu.assertEquals(3, blocks[1].block_type)
  lu.assertEquals(4, blocks[2].block_type)
  lu.assertEquals(8, blocks[3].block_type)
  lu.assertEquals('One', blocks[1].heading1.elements[1].text_run.content)
  lu.assertEquals('Six', blocks[3].heading6.elements[1].text_run.content)
end

function TestLarkDocx:testTextToBlocksSkipsBlankLines()
  local blocks = lark_docx._text_to_blocks('a\n\n\nb')
  lu.assertEquals(2, #blocks)
end

function TestLarkDocx:testTextToBlocksBulletAndOrdered()
  local blocks = lark_docx._text_to_blocks('- bullet\n* star\n1. first\n2) paren')
  lu.assertEquals(4, #blocks)
  lu.assertEquals(12, blocks[1].block_type)
  lu.assertEquals(12, blocks[2].block_type)
  lu.assertEquals(13, blocks[3].block_type)
  -- "2)" is not a recognised ordered marker, so it stays a plain line
  lu.assertEquals(2, blocks[4].block_type)
end

function TestLarkDocx:testTextToBlocksDeepHeadingFallsBackToText()
  -- seven hashes is not a heading level, so the line stays plain text
  local blocks = lark_docx._text_to_blocks('####### too deep')
  lu.assertEquals(1, #blocks)
  lu.assertEquals(2, blocks[1].block_type)
end

-- ─── scheme / info ──────────────────────────────────────

function TestLarkDocx:testScheme()
  local scheme = lark_docx.scheme()
  lu.assertEquals('function', scheme.type)
  lu.assertEquals('lark_docx', scheme['function'].name)
  local props = scheme['function'].parameters.properties
  lu.assertNotNil(props.action)
  lu.assertNotNil(props.url)
  lu.assertNotNil(props.document_id)
  lu.assertNotNil(props.block_id)
  lu.assertNotNil(props.text)
  lu.assertNotNil(props.blocks)
  lu.assertNotNil(props.title)

  local seen = {}
  for _, name in ipairs(props.action.enum) do
    seen[name] = true
  end
  for _, name in ipairs({ 'get', 'read', 'append', 'update_block', 'delete_block', 'create' }) do
    lu.assertTrue(seen[name], name .. ' in action enum')
  end
end

function TestLarkDocx:testInfo()
  local info = lark_docx.info(vim.json.encode({
    action = 'read',
    document_id = 'doxcn1',
    block_id = 'blk1',
  }))
  lu.assertStrContains(info, 'lark_docx read')
  lu.assertStrContains(info, 'doc=doxcn1')
  lu.assertStrContains(info, 'block=blk1')
end

function TestLarkDocx:testInfoFallback()
  lu.assertEquals('lark_docx', lark_docx.info('not json'))
  lu.assertEquals('lark_docx read', lark_docx.info(nil))
end

return TestLarkDocx

