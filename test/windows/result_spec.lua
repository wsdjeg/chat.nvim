local lu = require('luaunit')
local config = require('chat.config')
local result = require('chat.windows.result')
local sessions = require('chat.sessions')

local SESSION = 'sess-1'
local OTHER = 'sess-other'

TestWindowsResult = {}

function TestWindowsResult:setUp()
  config.setup({
    storage_dir = vim.fn.tempname(),
    allowed_path = vim.fs.normalize(vim.fn.getcwd()),
    border = 'single',
    auto_scroll = false,
    render_markdown = false,
    highlights = { title_badge = 'Normal', title = 'Normal' },
    winhighlight = '',
  })
  result.close()
  self.deleted = {}

  sessions.get_messages = function() return {} end
  sessions.is_in_progress = function() return false end
  sessions.get_total_tokens = function() return 0, 0, 0 end
  sessions.get_session_title = function() return '' end
  sessions.get_progress_reasoning_content = function() return nil end
  sessions.get_progress_message = function() return nil end
  sessions.delete_message = function(_, idx)
    table.insert(self.deleted, idx)
  end

  self.buf = result.create_buffer(SESSION)
end

function TestWindowsResult:tearDown()
  result.close()
end

function TestWindowsResult:testCreateBuffer()
  lu.assertTrue(vim.api.nvim_buf_is_valid(self.buf))
  lu.assertEquals('markdown', vim.api.nvim_get_option_value('filetype', { buf = self.buf }))
end

function TestWindowsResult:testOpenWindow()
  local win = result.open_window(self.buf, 0, 0, 20, 80)
  lu.assertTrue(vim.api.nvim_win_is_valid(win))
end

function TestWindowsResult:testSetTitle()
  result.open_window(self.buf, 0, 0, 20, 80)
  sessions.get_session_title = function() return 'My Chat' end
  sessions.get_total_tokens = function() return 100, 40, 60 end
  result.set_title('chat.nvim', SESSION)
  lu.assertTrue(vim.api.nvim_win_is_valid(result.get_win()))
end

function TestWindowsResult:testScrollToBottom()
  result.open_window(self.buf, 0, 0, 20, 80)
  result.scroll_to_bottom()
  lu.assertTrue(vim.api.nvim_win_is_valid(result.get_win()))
end

function TestWindowsResult:testAutoScrollDisabled()
  lu.assertFalse(result.auto_scroll())
end

function TestWindowsResult:testOnMessageCurrentSession()
  result.on_message(SESSION, SESSION, { role = 'assistant', content = 'hi' })
  lu.assertTrue(vim.api.nvim_buf_is_valid(self.buf))
end

function TestWindowsResult:testOnMessageOtherSession()
  local before = vim.api.nvim_buf_line_count(self.buf)
  result.on_message(OTHER, SESSION, { role = 'assistant', content = 'hi' })
  lu.assertEquals(before, vim.api.nvim_buf_line_count(self.buf))
end

function TestWindowsResult:testPushText()
  result.push_text({ content = 'hello' })
  result.push_text({ content = ' world' })
  lu.assertTrue(vim.api.nvim_buf_is_valid(self.buf))
end

function TestWindowsResult:testPushTextNoBuffer()
  result.close()
  result.push_text({ content = 'x' })
end

function TestWindowsResult:testOnToolCallDone()
  result.on_tool_call_done(
    SESSION,
    SESSION,
    { { role = 'assistant', content = 'tool result' } }
  )
  lu.assertTrue(vim.api.nvim_buf_is_valid(self.buf))
end

function TestWindowsResult:testOnToolCallStart()
  result.on_tool_call_start(SESSION, SESSION, { role = 'assistant', content = 'calling tool' })
  lu.assertTrue(vim.api.nvim_buf_is_valid(self.buf))
end

function TestWindowsResult:testRender()
  sessions.get_messages = function() return { { role = 'assistant', content = 'a' } } end
  result.render(SESSION)
  lu.assertTrue(vim.api.nvim_buf_is_valid(self.buf))
end

function TestWindowsResult:testRenderNoBuffer()
  result.close()
  result.render(SESSION)
end

function TestWindowsResult:testDeleteMessageAtCursor()
  sessions.get_messages = function()
    return { { role = 'user', content = 'q', created = os.time() } }
  end
  local buf = result.create_buffer(SESSION)
  result.open_window(buf, 0, 0, 20, 80)
  vim.api.nvim_win_set_cursor(result.get_win(), { 1, 0 })
  local ok = result.delete_message_at_cursor(SESSION)
  lu.assertTrue(ok)
  lu.assertEquals(1, self.deleted[1])
end

function TestWindowsResult:testDeleteMessageAtCursorNoWindow()
  result.close()
  lu.assertFalse(result.delete_message_at_cursor(SESSION))
end

function TestWindowsResult:testClose()
  result.close()
  lu.assertFalse(vim.api.nvim_buf_is_valid(result.get_buf()))
end

function TestWindowsResult:testGetSetWinBuf()
  result.set_win(111)
  result.set_buf(222)
  lu.assertEquals(111, result.get_win())
  lu.assertEquals(222, result.get_buf())
end

return TestWindowsResult
