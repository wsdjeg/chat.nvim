local lu = require('luaunit')
local tools = require('chat.tools')
local config = require('chat.config')
local lsp_diagnostics = require('chat.tools.lsp_diagnostics')

TestLspDiagnosticsExtra = {}

function TestLspDiagnosticsExtra:setUp()
  self.cwd = vim.fs.normalize(vim.fn.getcwd())
  config.setup({ allowed_path = self.cwd })
  self._orig_get_clients = vim.lsp.get_clients
  self._orig_diag_get = vim.diagnostic.get
end

function TestLspDiagnosticsExtra:tearDown()
  vim.lsp.get_clients = self._orig_get_clients
  vim.diagnostic.get = self._orig_diag_get
end

function TestLspDiagnosticsExtra:testSecurityCwdOutsideAllowed()
  local tmp = vim.fs.normalize(vim.fn.stdpath('data')) .. '/lsp_out_' .. os.time()
  vim.fn.mkdir(tmp, 'p')
  local result = tools.call('lsp_diagnostics', {
    filepath = 'x.lua',
  }, { cwd = tmp })
  lu.assertNotNil(result)
  lu.assertNotNil(result.error)
  vim.fn.delete(tmp, 'rf')
end

function TestLspDiagnosticsExtra:testPathOutsideCwd()
  local base = vim.fs.normalize(vim.fn.stdpath('data')) .. '/lsp_base_' .. os.time() .. '_' .. math.random(1000, 9999)
  local sub1 = base .. '/sub1'
  vim.fn.mkdir(sub1, 'p')
  config.setup({ allowed_path = vim.fs.normalize(base) })

  local result = tools.call('lsp_diagnostics', {
    filepath = base .. '/outside.lua',
  }, { cwd = vim.fs.normalize(sub1) })
  lu.assertNotNil(result)
  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'outside cwd')

  vim.fn.delete(base, 'rf')
end

function TestLspDiagnosticsExtra:testBufferNotFound()
  local filepath = self.cwd .. '/unloaded_buffer_file.lua'
  local result = tools.call('lsp_diagnostics', {
    filepath = filepath,
  }, { cwd = self.cwd })
  lu.assertNotNil(result)
  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'Buffer not found')
end

function TestLspDiagnosticsExtra:testNoDiagnosticsFound()
  local buf = vim.api.nvim_create_buf(false, true)
  local filepath = self.cwd .. '/lsp_no_diag.lua'
  vim.api.nvim_buf_set_name(buf, filepath)

  vim.lsp.get_clients = function() return { {} } end
  vim.diagnostic.get = function() return {} end

  local result = tools.call('lsp_diagnostics', {
    filepath = filepath,
    severity = 'Warn',
  }, { cwd = self.cwd })
  lu.assertNotNil(result)
  lu.assertNotNil(result.content)
  lu.assertStrContains(result.content, 'No diagnostics found')
  lu.assertStrContains(result.content, 'severity: Warn')

  vim.api.nvim_buf_delete(buf, { force = true })
end

function TestLspDiagnosticsExtra:testWithDiagnostics()
  local buf = vim.api.nvim_create_buf(false, true)
  local filepath = self.cwd .. '/lsp_with_diag.lua'
  vim.api.nvim_buf_set_name(buf, filepath)

  vim.lsp.get_clients = function() return { {} } end
  vim.diagnostic.get = function()
    return {
      {
        lnum = 0,
        col = 3,
        message = 'Undefined variable x',
        severity = vim.diagnostic.severity.ERROR,
        source = 'lua_ls',
        code = 'undefined-global',
      },
      {
        lnum = 5,
        col = 0,
        message = 'Unused variable',
        severity = vim.diagnostic.severity.WARN,
      },
    }
  end

  local result = tools.call('lsp_diagnostics', {
    filepath = filepath,
    severity = 'Error',
    line_start = 1,
    line_to = 2,
  }, { cwd = self.cwd })
  lu.assertNotNil(result)
  lu.assertNotNil(result.content)
  lu.assertStrContains(result.content, 'Found 1 diagnostic(s)')
  lu.assertStrContains(result.content, 'Line 1, Col 4')
  lu.assertStrContains(result.content, 'Undefined variable x')
  lu.assertStrContains(result.content, 'source: lua_ls')
  lu.assertStrContains(result.content, 'code: undefined-global')

  vim.api.nvim_buf_delete(buf, { force = true })
end

function TestLspDiagnosticsExtra:testDiagnosticWithoutSourceCode()
  local buf = vim.api.nvim_create_buf(false, true)
  local filepath = self.cwd .. '/lsp_no_src.lua'
  vim.api.nvim_buf_set_name(buf, filepath)

  vim.lsp.get_clients = function() return { {} } end
  vim.diagnostic.get = function()
    return {
      { lnum = 0, col = 0, message = 'plain', severity = vim.diagnostic.severity.INFO },
    }
  end

  local result = tools.call('lsp_diagnostics', {
    filepath = filepath,
  }, { cwd = self.cwd })
  lu.assertNotNil(result)
  lu.assertNotNil(result.content)
  lu.assertStrContains(result.content, 'Found 1 diagnostic(s)')

  vim.api.nvim_buf_delete(buf, { force = true })
end

function TestLspDiagnosticsExtra:testInfoDefault()
  local info = lsp_diagnostics.info('not json', { cwd = self.cwd })
  lu.assertEquals('lsp_diagnostics', info)
end

function TestLspDiagnosticsExtra:testInfoFull()
  local info = lsp_diagnostics.info(
    vim.json.encode({ filepath = 'x.lua', severity = 'Error', line_start = 1, line_to = 3 }),
    { cwd = self.cwd }
  )
  lu.assertStrContains(info, 'filepath=x.lua')
  lu.assertStrContains(info, 'severity=Error')
  lu.assertStrContains(info, 'lines=1-3')
end

function TestLspDiagnosticsExtra:testScheme()
  local scheme = lsp_diagnostics.scheme()
  lu.assertEquals('function', scheme.type)
  lu.assertEquals('lsp_diagnostics', scheme['function'].name)
end

return TestLspDiagnosticsExtra
