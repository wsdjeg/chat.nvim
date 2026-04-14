local lu = require('luaunit')
local tools = require('chat.tools')
local config = require('chat.config')

TestLspDiagnostics = {}

function TestLspDiagnostics:setUp()
  config.setup({
    allowed_path = vim.fs.normalize(vim.fn.getcwd()),
  })
  -- Create a test buffer
  self.test_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(self.test_buf, 0, -1, false, {
    'local x = 1',
    'local y = ',
    'print(x)',
  })
end

function TestLspDiagnostics:tearDown()
  if self.test_buf then
    vim.api.nvim_buf_delete(self.test_buf, { force = true })
  end
end

function TestLspDiagnostics:testToolExists()
  local available = tools.available_tools()
  local tool_names = {}
  for _, tool in ipairs(available) do
    table.insert(tool_names, tool['function'].name)
  end
  lu.assertTrue(vim.tbl_contains(tool_names, 'lsp_diagnostics'))
end

function TestLspDiagnostics:testNoLspAttached()
  -- Get the buffer's file path
  local filepath = vim.api.nvim_buf_get_name(self.test_buf)
  if filepath == '' then
    filepath = '/tmp/test_file.lua'
    vim.api.nvim_buf_set_name(self.test_buf, filepath)
  end

  local result = tools.call(
    'lsp_diagnostics',
    {},
    { cwd = vim.fs.normalize(vim.fn.getcwd()), filepath = filepath }
  )

  lu.assertNotNil(result)
  lu.assertNotNil(result.error)
  lu.assertTrue(result.error:match('No LSP client attached') ~= nil)
end

function TestLspDiagnostics:testWithSeverityFilter()
  local filepath = vim.api.nvim_buf_get_name(self.test_buf)
  if filepath == '' then
    filepath = '/tmp/test_file.lua'
    vim.api.nvim_buf_set_name(self.test_buf, filepath)
  end

  local result = tools.call(
    'lsp_diagnostics',
    { severity = 'Error' },
    { cwd = vim.fs.normalize(vim.fn.getcwd()), filepath = filepath }
  )

  lu.assertNotNil(result)
  lu.assertNotNil(result.error) -- No LSP attached
end

function TestLspDiagnostics:testWithLineRange()
  local filepath = vim.api.nvim_buf_get_name(self.test_buf)
  if filepath == '' then
    filepath = '/tmp/test_file.lua'
    vim.api.nvim_buf_set_name(self.test_buf, filepath)
  end

  local result = tools.call(
    'lsp_diagnostics',
    { line_start = 1, line_to = 2 },
    { cwd = vim.fs.normalize(vim.fn.getcwd()), filepath = filepath }
  )

  lu.assertNotNil(result)
  lu.assertNotNil(result.error) -- No LSP attached
end

return TestLspDiagnostics

