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

-- Title composition ----------------------------------------------------------
-- The prompt window title no longer repeats the session title nor contains
-- the "Input" label: it only carries provider / model / cwd / integrations.

function TestWindowsPrompt:testBuildTitleSeparatesProviderAndModel()
  local title = prompt.build_title('sess')
  lu.assertStrContains(title, 'openai | gpt')
end

function TestWindowsPrompt:testBuildTitleHasNoInputLabel()
  local title = prompt.build_title('sess')
  lu.assertNotStrContains(title, 'Input')
end

function TestWindowsPrompt:testBuildTitleOmitsSessionTitle()
  sessions.get_session_title = function() return 'My Session' end
  local title = prompt.build_title('sess')
  lu.assertNotStrContains(title, 'My Session')
  lu.assertStrContains(title, 'openai | gpt')
end

function TestWindowsPrompt:testBuildTitleWithIntegrations()
  integrations.get_integrations = function() return { 'discord', 'lark' } end
  local title = prompt.build_title('sess')
  lu.assertStrContains(title, 'discord | lark')
end

function TestWindowsPrompt:testBuildTitleFallback()
  sessions.get_session_provider = function() return '' end
  sessions.get_session_model = function() return '' end
  sessions.getcwd = function() return '' end
  local title = prompt.build_title('sess')
  lu.assertStrContains(title, 'chat.nvim')
end

function TestWindowsPrompt:testWindowTitleUsesBuildTitle()
  prompt.open_window(self.buf, 0, 0, 40, 'sess')
  local conf = vim.api.nvim_win_get_config(prompt.get_win())
  local text = ''
  for _, part in ipairs(conf.title or {}) do
    text = text .. tostring(part[1])
  end
  lu.assertStrContains(text, 'openai | gpt')
  lu.assertNotStrContains(text, 'Input')
end

-- Placeholder ---------------------------------------------------------------

local function placeholder_marks()
  return vim.api.nvim_buf_get_extmarks(
    prompt.get_buf(),
    prompt.get_placeholder_ns(),
    0,
    -1,
    { details = true }
  )
end

function TestWindowsPrompt:testPlaceholderShownWhenEmpty()
  prompt.clear()
  local marks = placeholder_marks()
  lu.assertEquals(1, #marks)
  lu.assertEquals(prompt.placeholder, marks[1][4].virt_text[1][1])
  lu.assertEquals('Comment', marks[1][4].virt_text[1][2])
  lu.assertEquals('overlay', marks[1][4].virt_text_pos)
end

function TestWindowsPrompt:testPlaceholderHiddenWhenTyping()
  vim.api.nvim_buf_set_lines(self.buf, 0, -1, false, { 'hello' })
  prompt.render_placeholder()
  lu.assertEquals(0, #placeholder_marks())
end

function TestWindowsPrompt:testPlaceholderRestoredAfterClear()
  vim.api.nvim_buf_set_lines(self.buf, 0, -1, false, { 'hello' })
  prompt.render_placeholder()
  lu.assertEquals(0, #placeholder_marks())
  prompt.clear()
  lu.assertEquals(1, #placeholder_marks())
end

function TestWindowsPrompt:testPlaceholderNotInContent()
  prompt.clear()
  local content = prompt.get_content()
  lu.assertEquals(1, #content)
  lu.assertEquals('', content[1])
end

return TestWindowsPrompt

