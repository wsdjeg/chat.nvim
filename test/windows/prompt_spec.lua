local lu = require('luaunit')
local config = require('chat.config')
local prompt = require('chat.windows.prompt')
local sessions = require('chat.sessions')
local integrations = require('chat.integrations')

TestWindowsPrompt = {}

function TestWindowsPrompt:setUp()
  config.setup({
    storage_dir = vim.fn.tempname(),
    allowed_path = vim.fs.normalize(vim.fn.getcwd()),
    border = 'single',
    highlights = {
      title_badge = 'Normal',
      title = 'Normal',
    },
    winhighlight = '',
  })
  sessions.get_session_title = function() return 't' end
  sessions.get_session_provider = function() return 'openai' end
  sessions.get_session_model = function() return 'gpt' end
  sessions.getcwd = function() return vim.fn.getcwd() end
  integrations.get_integrations = function() return {} end

  self.buf = prompt.create_buffer()
end

function TestWindowsPrompt:tearDown()
  prompt.close()
  if vim.api.nvim_buf_is_valid(self.buf) then
    vim.api.nvim_buf_delete(self.buf, { force = true })
  end
end

function TestWindowsPrompt:testCreateBuffer()
  lu.assertTrue(vim.api.nvim_buf_is_valid(self.buf))
  lu.assertEquals('nofile', vim.api.nvim_get_option_value('buftype', { buf = self.buf }))
end

function TestWindowsPrompt:testOpenWindow()
  local win = prompt.open_window(self.buf, 0, 0, 40, 'sess')
  lu.assertTrue(vim.api.nvim_win_is_valid(win))
end

function TestWindowsPrompt:testFocus()
  prompt.open_window(self.buf, 0, 0, 40, 'sess')
  prompt.focus()
  lu.assertTrue(vim.api.nvim_win_is_valid(prompt.get_win()))
end

function TestWindowsPrompt:testGetContentAndClear()
  vim.api.nvim_buf_set_lines(self.buf, 0, -1, false, { 'hello', 'world' })
  local content = prompt.get_content()
  lu.assertEquals('hello', content[1])
  prompt.clear()
  local after = prompt.get_content()
  lu.assertEquals(1, #after)
  lu.assertEquals('', after[1])
end

function TestWindowsPrompt:testRedrawTitle()
  prompt.open_window(self.buf, 0, 0, 40, 'sess')
  prompt.redraw_title('sess')
  lu.assertTrue(vim.api.nvim_win_is_valid(prompt.get_win()))
end

function TestWindowsPrompt:testRedrawTitleNoWindow()
  prompt.set_win(-1)
  prompt.redraw_title('sess')
end

function TestWindowsPrompt:testClose()
  prompt.open_window(self.buf, 0, 0, 40, 'sess')
  prompt.close()
  lu.assertFalse(vim.api.nvim_win_is_valid(prompt.get_win()))
end

function TestWindowsPrompt:testIsValidWithoutWindow()
  prompt.set_win(-1)
  lu.assertFalse(prompt.is_valid())
end

function TestWindowsPrompt:testGetWinAndBuf()
  prompt.set_win(-1)
  prompt.set_buf(-1)
  lu.assertEquals(-1, prompt.get_win())
  lu.assertEquals(-1, prompt.get_buf())
end

return TestWindowsPrompt
