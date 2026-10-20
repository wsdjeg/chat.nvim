local lu = require('luaunit')
local config = require('chat.config')
local windows = require('chat.windows')
local sessions = require('chat.sessions')
local protocol = require('chat.protocol')
local queue = require('chat.queue')
local integrations = require('chat.integrations')
local mcp = require('chat.mcp')
local skills = require('chat.skills')
local spinners = require('chat.spinners')
local storage_mod = require('chat.sessions.storage')

TestWindows = {}

local saved = {}

local function snap(mod, method)
  if not saved[mod] then saved[mod] = {} end
  if saved[mod][method] == nil then
    saved[mod][method] = mod[method]
  end
end

local function restore_all()
  for mod, methods in pairs(saved) do
    for method, orig in pairs(methods) do
      mod[method] = orig
    end
  end
  saved = {}
end

function TestWindows:setUp()
  restore_all()
  for _, m in ipairs({
    'exists', 'get', 'new', 'get_messages', 'is_in_progress', 'append_message',
    'get_request_messages', 'reset_retry_count', 'clear_cancelled', 'nudge_reset',
    'get_session_title', 'set_session_title', 'get_session_provider',
    'get_session_model', 'getcwd', 'get_total_tokens',
    'get_progress_reasoning_content', 'get_progress_message', 'delete_message',
    'cancel_progress',
  }) do snap(sessions, m) end
  snap(protocol, 'request')
  snap(queue, 'start'); snap(queue, 'push')
  snap(integrations, 'on_message')
  snap(mcp, 'connect')
  snap(spinners, 'start'); snap(spinners, 'stop')
  snap(skills, 'dispatch')
  snap(storage_mod, 'write_cache')
  snap(config, 'config')
  snap(storage_mod, 'cache_dir')
  snap(storage_mod, 'sessions')

  config.setup({
    storage_dir = vim.fn.tempname(),
    allowed_path = vim.fs.normalize(vim.fn.getcwd()),
    api_key = 'test-key',
    http = { api_key = '', host = '127.0.0.1', port = 7777 },
    render_markdown = false,
    auto_scroll = false,
    border = 'single',
    highlights = { title_badge = 'Normal', title = 'Normal' },
    winhighlight = '',
  })

  self.current_id = 'sess-' .. math.random(100000, 999999)
  self.requests = {}
  self.messages = {}
  self.skill_invocations = {}

  sessions.exists = function(id) return id == self.current_id end
  sessions.get = function() return { [self.current_id] = { cwd = vim.fn.getcwd() } } end
  sessions.new = function() return self.current_id end
  sessions.get_messages = function() return self.messages end
  sessions.is_in_progress = function() return false end
  sessions.append_message = function(_, msg) table.insert(self.messages, msg) end
  sessions.get_request_messages = function() return self.messages end
  sessions.reset_retry_count = function() end
  sessions.clear_cancelled = function() end
  sessions.nudge_reset = function() end
  sessions.get_session_title = function() return '' end
  sessions.set_session_title = function() end
  sessions.get_session_provider = function() return 'openai' end
  sessions.get_session_model = function() return 'gpt' end
  sessions.getcwd = function() return vim.fn.getcwd() end
  sessions.get_total_tokens = function() return 0, 0, 0 end
  sessions.get_progress_reasoning_content = function() return nil end
  sessions.get_progress_message = function() return nil end
  sessions.delete_message = function() end
  sessions.cancel_progress = function() end

  protocol.request = function(opts)
    table.insert(self.requests, opts)
    return 1
  end
  storage_mod.write_cache = function() end

  queue.start = function() end
  queue.push = function() end
  integrations.on_message = function(handler) self.msg_handler = handler end
  mcp.connect = function() end
  spinners.start = function() end
  spinners.stop = function() end

  skills.dispatch = function(text, session)
    table.insert(self.skill_invocations, { text = text, session = session })
    return nil
  end

  windows.close()
end

function TestWindows:tearDown()
  windows.close()
  restore_all()
end

function TestWindows:testOpenAndClose()
  windows.open()
  lu.assertTrue(windows.is_open())
  windows.close()
  lu.assertFalse(windows.is_open())
end

function TestWindows:testOpenWithCwd()
  windows.open({ cwd = vim.fn.getcwd() })
  lu.assertTrue(windows.is_open())
end

function TestWindows:testStartNoAutoSession()
  windows.start()
end

function TestWindows:testCurrentSessionNilInitially()
  lu.assertNil(windows.current_session())
end

function TestWindows:testSendMessageSkill()
  local handled = windows.send_message(self.current_id, '/help')
  lu.assertTrue(handled)
  lu.assertEquals(1, #self.skill_invocations)
  lu.assertEquals('/help', self.skill_invocations[1].text)
end

function TestWindows:testSendMessageNormal()
  windows.send_message(self.current_id, 'hello world')
  lu.assertEquals(1, #self.requests)
  lu.assertEquals('hello world', self.requests[1].messages[1].content)
end

function TestWindows:testSendMessageNoSession()
  windows.send_message(nil, 'hello')
  lu.assertEquals(0, #self.requests)
end

function TestWindows:testSendMessageNilContent()
  windows.send_message(self.current_id, nil)
  lu.assertEquals(0, #self.requests)
end

function TestWindows:testDispatchSkillTableOutput()
  skills.dispatch = function(_, _)
    return { content = 'skill result', role = 'assistant', request = false }
  end
  windows.send_message(self.current_id, '/tool')
  lu.assertEquals('skill result', self.messages[#self.messages].content)
  lu.assertEquals('assistant', self.messages[#self.messages].role)
end

function TestWindows:testDispatchSkillTableOutputWithRequest()
  skills.dispatch = function(_, _)
    return { content = 'trigger llm', request = true }
  end
  local before = #self.requests
  windows.send_message(self.current_id, '/tool')
  lu.assertTrue(#self.requests > before)
end

function TestWindows:testDispatchSkillStringOutput()
  skills.dispatch = function(_, _) return 'plain output' end
  windows.send_message(self.current_id, '/tool')
  lu.assertEquals('plain output', self.messages[#self.messages].content)
end

function TestWindows:testOpenNoApiKey()
  config.setup({
    storage_dir = vim.fn.tempname(),
    api_key = '',
  })
  windows.close()
  windows.open()
  lu.assertFalse(windows.is_open())
end

function TestWindows:testStartNoApiKey()
  config.setup({
    storage_dir = vim.fn.tempname(),
    api_key = '',
  })
  windows.start()
end

function TestWindows:testOnMessageForwards()
  windows.open()
  windows.on_message(self.current_id, { role = 'assistant', content = 'hi' })
  lu.assertTrue(vim.api.nvim_buf_is_valid(require('chat.windows.result').get_buf()))
end

function TestWindows:testOnToolCallDone()
  windows.on_tool_call_done(self.current_id, { { role = 'assistant', content = 'x' } })
end

function TestWindows:testOnToolCallStart()
  windows.on_tool_call_start(self.current_id, { role = 'assistant', content = 'x' })
end

function TestWindows:testRedrawTitle()
  windows.open()
  windows.redraw_title()
end

function TestWindows:testSetResultWinTitle()
  windows.open()
  windows.set_result_win_title('custom title')
end

function TestWindows:testRenderResultBuf()
  windows.open()
  windows.render_result_buf()
end

function TestWindows:testPushText()
  windows.open()
  windows.push_text({ content = 'streaming' })
end

function TestWindows:testRenameTitle()
  windows.open()
  local called = false
  vim.ui.input = function(opts, cb)
    called = true
    cb('New Title')
  end
  windows.rename_title()
  lu.assertTrue(called)
end

function TestWindows:testRenameTitleNoSession()
  windows.close()
  vim.ui.input = function(opts, cb) cb('') end
  windows.rename_title()
end

return TestWindows
