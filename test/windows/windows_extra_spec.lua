-- Coverage for the interactive logic of chat/windows.lua and
-- chat/windows/result.lua:
--   * windows: api-key validation branches, session ensure/switch, cwd
--     handling, services startup (http/queue/mcp), captured keymap
--     handlers (send / retry / delete / focus / cancel), programmatic
--     send_message (skill + request branches) and skill dispatch with
--     request triggering
--   * result: push_text start/reasoning/content branches, tool-call
--     separators, progress rendering on create/render, delete-at-cursor
--     boundaries, auto-scroll detection and title composition

local lu = require('luaunit')

local config = require('chat.config')
local sessions = require('chat.sessions')
local storage = require('chat.sessions.storage')
local protocol = require('chat.protocol')
local spinners = require('chat.spinners')
local queue = require('chat.queue')
local integrations = require('chat.integrations')
local keymaps = require('chat.windows.keymaps')
local skills = require('chat.skills')

local WINDOWS_MODULE = 'chat.windows'

local function save(module, name, holder)
  table.insert(holder, { module = module, name = name, fn = module[name] })
end

-- =========================================================================
-- windows.lua
-- =========================================================================

TestWindowsExtra = {}

function TestWindowsExtra:setUp()
  self.orig = {}

  -- Reload a pristine chat.windows: its module-local current_session and
  -- services_started flags otherwise leak between tests.
  package.loaded[WINDOWS_MODULE] = nil
  self.windows = require(WINDOWS_MODULE)

  -- config
  self.api_key_orig = config.config.api_key
  self.http_api_key_orig = config.config.http.api_key
  config.config.api_key = { provider_a = 'key' }
  config.config.http.api_key = ''

  -- sessions
  save(sessions, 'exists', self.orig)
  self.session_exists = true
  sessions.exists = function(_)
    return self.session_exists
  end
  save(sessions, 'new', self.orig)
  self.new_sessions = { 'ws-session' }
  sessions.new = function()
    local id = table.remove(self.new_sessions, 1) or 'ws-fallback'
    return id
  end
  save(sessions, 'is_in_progress', self.orig)
  self.in_progress = false
  sessions.is_in_progress = function(_)
    return self.in_progress
  end
  save(sessions, 'change_cwd', self.orig)
  self.cwd_changes = {}
  sessions.change_cwd = function(sid, cwd)
    table.insert(self.cwd_changes, { sid = sid, cwd = cwd })
  end
  save(sessions, 'append_message', self.orig)
  self.appended = {}
  sessions.append_message = function(sid, msg)
    table.insert(self.appended, { sid = sid, msg = msg })
  end
  save(sessions, 'get_request_messages', self.orig)
  self.request_messages = {}
  sessions.get_request_messages = function(_)
    return self.request_messages
  end
  for _, fn_name in ipairs({
    'reset_retry_count',
    'cancel_progress',
    'nudge_reset',
    'clear_cancelled',
  }) do
    save(sessions, fn_name, self.orig)
    self[fn_name .. '_calls'] = 0
    sessions[fn_name] = function(_)
      self[fn_name .. '_calls'] = self[fn_name .. '_calls'] + 1
    end
  end
  save(sessions, 'get_session_title', self.orig)
  sessions.get_session_title = function(_)
    return ''
  end
  save(sessions, 'set_session_title', self.orig)
  self.title_sets = {}
  sessions.set_session_title = function(sid, t)
    table.insert(self.title_sets, { sid = sid, title = t })
  end
  save(sessions, 'get', self.orig)
  sessions.get = function()
    return {}
  end
  save(sessions, 'delete_message', self.orig)
  self.deleted_messages = {}
  sessions.delete_message = function(sid, idx)
    table.insert(self.deleted_messages, { sid = sid, idx = idx })
  end

  -- storage
  save(storage, 'write_cache', self.orig)
  self.cache_writes = 0
  storage.write_cache = function(_)
    self.cache_writes = self.cache_writes + 1
  end

  -- protocol
  save(protocol, 'request', self.orig)
  self.protocol_result = 7
  self.protocol_calls = {}
  protocol.request = function(opts)
    table.insert(self.protocol_calls, opts)
    return self.protocol_result
  end

  -- spinners
  save(spinners, 'start', self.orig)
  save(spinners, 'stop', self.orig)
  self.spinner_starts = 0
  spinners.start = function()
    self.spinner_starts = self.spinner_starts + 1
  end
  self.spinner_stops = 0
  spinners.stop = function()
    self.spinner_stops = self.spinner_stops + 1
  end

  -- queue
  save(queue, 'start', self.orig)
  save(queue, 'push', self.orig)
  self.queue_starts = 0
  queue.start = function()
    self.queue_starts = self.queue_starts + 1
  end
  self.queue_pushes = {}
  queue.push = function(sid, content)
    table.insert(self.queue_pushes, { sid = sid, content = content })
  end

  -- integrations
  save(integrations, 'on_message', self.orig)
  self.integrations_handler = nil
  integrations.on_message = function(handler)
    self.integrations_handler = handler
  end

  -- http + mcp
  local http = require('chat.http')
  save(http, 'start', self.orig)
  self.http_starts = 0
  http.start = function()
    self.http_starts = self.http_starts + 1
  end
  local mcp = require('chat.mcp')
  save(mcp, 'connect', self.orig)
  self.mcp_connects = 0
  mcp.connect = function()
    self.mcp_connects = self.mcp_connects + 1
  end

  -- skills
  save(skills, 'dispatch', self.orig)
  self.skill_dispatches = {}
  self.skill_result = nil
  skills.dispatch = function(text, sid)
    table.insert(self.skill_dispatches, { text = text, sid = sid })
    return self.skill_result
  end

  -- submodules: stub away all real UI
  local result = require('chat.windows.result')
  local prompt = require('chat.windows.prompt')

  save(result, 'is_buf_valid', self.orig)
  result.is_buf_valid = function()
    return false -- forces open() to run create_buffer + keymap setup
  end
  save(result, 'get_buf', self.orig)
  result.get_buf = function()
    return 1
  end
  save(result, 'get_win', self.orig)
  result.get_win = function()
    return -1 -- nvim_win_is_valid(-1) == false
  end
  save(result, 'create_buffer', self.orig)
  result.create_buffer = function() end
  save(result, 'open_window', self.orig)
  self.result_opens = 0
  result.open_window = function()
    self.result_opens = self.result_opens + 1
  end
  save(result, 'render', self.orig)
  self.renders = 0
  result.render = function(_)
    self.renders = self.renders + 1
  end
  save(result, 'delete_message_at_cursor', self.orig)
  self.result_deletes = {}
  result.delete_message_at_cursor = function(sid)
    table.insert(self.result_deletes, sid)
  end
  save(result, 'close', self.orig)
  result.close = function() end

  save(prompt, 'is_buf_valid', self.orig)
  prompt.is_buf_valid = function()
    return false -- forces open() to run create_buffer + keymap setup
  end
  save(prompt, 'get_buf', self.orig)
  prompt.get_buf = function()
    return 2
  end
  save(prompt, 'is_valid', self.orig)
  prompt.is_valid = function()
    return false
  end
  save(prompt, 'open_window', self.orig)
  self.prompt_opens = 0
  prompt.open_window = function()
    self.prompt_opens = self.prompt_opens + 1
  end
  save(prompt, 'focus', self.orig)
  self.focuses = 0
  prompt.focus = function()
    self.focuses = self.focuses + 1
  end
  save(prompt, 'redraw_title', self.orig)
  self.title_redraws = 0
  prompt.redraw_title = function(_)
    self.title_redraws = self.title_redraws + 1
  end
  save(prompt, 'get_content', self.orig)
  self.prompt_content = {}
  prompt.get_content = function()
    return self.prompt_content
  end
  save(prompt, 'clear', self.orig)
  self.prompt_clears = 0
  prompt.clear = function()
    self.prompt_clears = self.prompt_clears + 1
  end
  save(prompt, 'close', self.orig)
  prompt.close = function() end

  -- keymaps: capture the handler tables instead of installing keymaps
  save(keymaps, 'setup_result_keymaps', self.orig)
  self.result_opts = nil
  keymaps.setup_result_keymaps = function(_, opts)
    self.result_opts = opts
  end
  save(keymaps, 'setup_prompt_keymaps', self.orig)
  self.prompt_opts = nil
  keymaps.setup_prompt_keymaps = function(_, opts)
    self.prompt_opts = opts
  end
end

function TestWindowsExtra:tearDown()
  for _, entry in ipairs(self.orig) do
    entry.module[entry.name] = entry.fn
  end
  config.config.api_key = self.api_key_orig
  config.config.http.api_key = self.http_api_key_orig
  -- evict the reloaded module so later specs start from the pristine one
  package.loaded[WINDOWS_MODULE] = nil
end

-- open ----------------------------------------------------------------------

function TestWindowsExtra:testOpenCreatesThenReusesSession()
  self.windows.open()
  local first = self.windows.current_session()
  lu.assertEquals('ws-session', first)
  -- second open: existing session is kept (ensure_session fast path)
  self.windows.open()
  lu.assertEquals(first, self.windows.current_session())
end

function TestWindowsExtra:testOpenRejectedWithEmptyApiKeyTable()
  config.config.api_key = {}
  lu.assertNil(self.windows.open())
end

function TestWindowsExtra:testOpenRejectedWithEmptyApiKeyString()
  config.config.api_key = ''
  lu.assertNil(self.windows.open())
end

function TestWindowsExtra:testOpenRejectedWhenSessionCreationFails()
  sessions.new = function()
    return nil
  end
  lu.assertNil(self.windows.open())
  lu.assertNil(self.windows.current_session())
end

function TestWindowsExtra:testOpenWithCwdChangesDirectory()
  self.windows.open()
  self.windows.open({ cwd = '/new/cwd' })
  lu.assertEquals(1, #self.cwd_changes)
  lu.assertEquals('/new/cwd', self.cwd_changes[1].cwd)
end

function TestWindowsExtra:testOpenWithCwdRefusedWhileInProgress()
  self.windows.open()
  self.in_progress = true
  self.windows.open({ cwd = '/new/cwd' })
  lu.assertEquals(0, #self.cwd_changes)
end

function TestWindowsExtra:testOpenSwitchesToProvidedSession()
  self.windows.open()
  self.windows.open({ session = 'ws-other' })
  lu.assertEquals('ws-other', self.windows.current_session())
  lu.assertTrue(self.renders >= 1)
end

function TestWindowsExtra:testOpenRedrawOptionRenders()
  self.windows.open()
  self.windows.open({ redraw = true })
  lu.assertTrue(self.renders >= 1)
end

function TestWindowsExtra:testStartWithCwdOnExistingSession()
  self.windows.open()
  local sid = self.windows.current_session()
  self.windows.start({ cwd = '/start/cwd' })
  lu.assertEquals(1, #self.cwd_changes)
  lu.assertEquals(sid, self.cwd_changes[1].sid)
end

function TestWindowsExtra:testStartWithCwdRefusedWhileInProgress()
  self.windows.open()
  self.in_progress = true
  self.windows.start({ cwd = '/start/cwd' })
  lu.assertEquals(0, #self.cwd_changes)
end

function TestWindowsExtra:testStartRejectedWithoutApiKey()
  config.config.api_key = {}
  lu.assertNil(self.windows.start())
end

-- services ------------------------------------------------------------------

function TestWindowsExtra:testStartServicesWithHttpKey()
  config.config.http.api_key = 'http-secret'
  self.windows.open()
  lu.assertEquals(1, self.http_starts)
  lu.assertEquals(1, self.queue_starts)
  lu.assertEquals(1, self.mcp_connects)
end

function TestWindowsExtra:testStartServicesWithoutHttpKey()
  self.windows.open()
  lu.assertEquals(0, self.http_starts)
  lu.assertEquals(1, self.queue_starts)
end

function TestWindowsExtra:testServicesStartOnlyOnce()
  self.windows.open()
  self.windows.open()
  lu.assertEquals(1, self.queue_starts)
end

function TestWindowsExtra:testIntegrationHandlerPushesOntoQueue()
  self.windows.open()
  lu.assertNotNil(self.integrations_handler)
  self.integrations_handler({ session = 'ws-x', content = 'hello' })
  lu.assertEquals(1, #self.queue_pushes)
  lu.assertEquals('ws-x', self.queue_pushes[1].sid)
  lu.assertEquals('hello', self.queue_pushes[1].content)
end

function TestWindowsExtra:testOpenSpinnerFollowsProgressState()
  self.in_progress = true
  self.windows.open()
  lu.assertEquals(1, self.spinner_starts)
  lu.assertEquals(0, self.spinner_stops)
end

function TestWindowsExtra:testOpenSpinnerStoppedWhenIdle()
  self.windows.open()
  lu.assertEquals(1, self.spinner_stops)
end

-- keymap handlers -------------------------------------------------------------

function TestWindowsExtra:testSendKeymapRequiresSession()
  self.windows.open()
  self.session_exists = false
  self.prompt_opts.send_message_fn()
  lu.assertEquals(0, #self.protocol_calls)
end

function TestWindowsExtra:testSendKeymapRefusedWhileInProgress()
  self.windows.open()
  self.in_progress = true
  self.prompt_opts.send_message_fn()
  lu.assertEquals(0, #self.protocol_calls)
end

function TestWindowsExtra:testSendKeymapDispatchesSkill()
  self.windows.open()
  self.skill_result = 'skill output'
  self.prompt_content = { '/model gpt-4o' }
  self.prompt_opts.send_message_fn()

  lu.assertEquals(1, #self.skill_dispatches)
  lu.assertEquals('/model gpt-4o', self.skill_dispatches[1].text)
  -- skill output appended as assistant message
  lu.assertEquals(1, #self.appended)
  lu.assertEquals('assistant', self.appended[1].msg.role)
  lu.assertEquals('skill output', self.appended[1].msg.content)
  lu.assertEquals(1, self.prompt_clears)
  -- no LLM request for plain string skill output
  lu.assertEquals(0, #self.protocol_calls)
end

function TestWindowsExtra:testSendKeymapNormalMessageStartsRequest()
  self.windows.open()
  self.prompt_content = { 'hello world' }
  self.protocol_result = 9
  self.prompt_opts.send_message_fn()

  lu.assertEquals(1, #self.appended)
  lu.assertEquals('user', self.appended[1].msg.role)
  lu.assertEquals(1, #self.protocol_calls)
  lu.assertEquals(1, self.reset_retry_count_calls)
  lu.assertEquals(1, self.spinner_starts)
  lu.assertEquals(1, self.prompt_clears)
end

function TestWindowsExtra:testSendKeymapRequestFailureLogsError()
  self.windows.open()
  self.prompt_content = { 'hello world' }
  self.protocol_result = nil
  self.prompt_opts.send_message_fn()

  lu.assertEquals(1, #self.protocol_calls)
  lu.assertEquals(0, self.spinner_starts)
end

function TestWindowsExtra:testRetryKeymapStartsRequest()
  self.windows.open()
  self.request_messages = { { role = 'user', content = 'again' } }
  self.protocol_result = 4
  self.prompt_opts.retry_message_fn()

  lu.assertEquals(1, #self.protocol_calls)
  lu.assertEquals(1, self.spinner_starts)
end

function TestWindowsExtra:testRetryKeymapSkipsTrailingAssistant()
  self.windows.open()
  self.request_messages = { { role = 'assistant', content = 'done' } }
  self.prompt_opts.retry_message_fn()
  lu.assertEquals(0, #self.protocol_calls)
end

function TestWindowsExtra:testRetryKeymapEmptyMessagesNoop()
  self.windows.open()
  self.request_messages = {}
  self.prompt_opts.retry_message_fn()
  lu.assertEquals(0, #self.protocol_calls)
end

function TestWindowsExtra:testRetryKeymapRefusedWhileInProgress()
  self.windows.open()
  self.in_progress = true
  self.prompt_opts.retry_message_fn()
  lu.assertEquals(0, #self.protocol_calls)
end

function TestWindowsExtra:testRetryKeymapRequiresSession()
  self.windows.open()
  self.session_exists = false
  self.prompt_opts.retry_message_fn()
  lu.assertEquals(0, #self.protocol_calls)
end

function TestWindowsExtra:testDeleteKeymapRequiresSession()
  self.windows.open()
  self.session_exists = false
  self.result_opts.delete_message_fn()
  lu.assertEquals(0, #self.result_deletes)
end

function TestWindowsExtra:testDeleteKeymapDeletesAtCursor()
  self.windows.open()
  self.result_opts.delete_message_fn()
  lu.assertEquals(1, #self.result_deletes)
  lu.assertEquals(self.windows.current_session(), self.result_deletes[1])
end

function TestWindowsExtra:testFocusResultKeymapSwitchesWindow()
  self.windows.open()
  local result = require('chat.windows.result')
  local real_win = vim.api.nvim_open_win(0, false, { relative = 'editor', row = 1, col = 1, width = 5, height = 5 })
  result.get_win = function()
    return real_win
  end
  self.prompt_opts.focus_result_fn()
  lu.assertEquals(real_win, vim.api.nvim_get_current_win())
  vim.api.nvim_win_close(real_win, true)
end

function TestWindowsExtra:testFocusResultKeymapIgnoresInvalidWindow()
  self.windows.open()
  self.prompt_opts.focus_result_fn() -- get_win() returns -1: no crash
  lu.assertTrue(true)
end

function TestWindowsExtra:testCancelProgressKeymap()
  self.windows.open()
  self.prompt_opts.cancel_progress_fn()
  lu.assertEquals(1, self.cancel_progress_calls)
end

function TestWindowsExtra:testCancelProgressKeymapWithoutSession()
  self.windows.open()
  self.session_exists = false
  self.prompt_opts.cancel_progress_fn()
  lu.assertEquals(0, self.cancel_progress_calls)
end

-- rename_title ----------------------------------------------------------------

function TestWindowsExtra:testRenameTitleWithoutSessionNoop()
  lu.assertNil(self.windows.rename_title())
end

function TestWindowsExtra:testRenameTitleSetsAndRedraws()
  self.windows.open()
  local sid = self.windows.current_session()
  local ui_input_orig = vim.ui.input
  vim.ui.input = function(_, on_input)
    on_input('Fresh Title')
  end
  self.windows.rename_title()
  vim.ui.input = ui_input_orig
  lu.assertEquals(1, #self.title_sets)
  lu.assertEquals(sid, self.title_sets[1].sid)
  lu.assertEquals('Fresh Title', self.title_sets[1].title)
  lu.assertEquals(1, self.title_redraws)
end

-- dispatch_skill via programmatic send_message ----------------------------------

function TestWindowsExtra:testDispatchSkillTableWithRequestTriggersLlm()
  self.windows.open()
  self.skill_result = {
    content = 'setup instructions',
    role = 'user',
    request = true,
  }
  self.protocol_result = 11
  local ok = self.windows.send_message(self.windows.current_session(), '/setup')
  lu.assertTrue(ok)
  lu.assertEquals(1, #self.skill_dispatches)
  lu.assertEquals(1, #self.appended)
  lu.assertEquals('user', self.appended[1].msg.role)
  lu.assertEquals(1, #self.protocol_calls)
  lu.assertEquals(1, self.spinner_starts)
end

function TestWindowsExtra:testDispatchSkillRequestFailureLogsError()
  self.windows.open()
  self.skill_result = { content = 'x', role = 'user', request = true }
  self.protocol_result = nil
  self.windows.send_message(self.windows.current_session(), '/x')
  lu.assertEquals(0, self.spinner_starts)
end

function TestWindowsExtra:testDispatchSkillSessionDeletedDuringDispatch()
  -- the session disappears while the skill handler runs: dispatch_skill
  -- must bail out without appending anything
  self.windows.open()
  skills.dispatch = function(_, _)
    self.session_exists = false
    return { content = 'ghost', role = 'assistant' }
  end
  self.windows.send_message(self.windows.current_session(), '/ghost')
  lu.assertEquals(0, #self.appended)
  lu.assertEquals(0, #self.protocol_calls)
end

function TestWindowsExtra:testSendMessageProgrammaticRequest()
  self.windows.open()
  local sid = self.windows.current_session()
  self.protocol_result = 3
  self.windows.send_message(sid, 'plain text')
  lu.assertEquals(1, #self.appended)
  lu.assertEquals('user', self.appended[1].msg.role)
  lu.assertEquals(1, #self.protocol_calls)
  lu.assertEquals(1, self.spinner_starts)
  lu.assertEquals(1, self.clear_cancelled_calls)
  lu.assertEquals(1, self.nudge_reset_calls)
end

function TestWindowsExtra:testSendMessageWithoutContentNoop()
  self.windows.send_message('ws-session', nil)
  lu.assertEquals(0, #self.protocol_calls)
end

-- =========================================================================
-- windows/result.lua
-- =========================================================================

TestWindowsResultExtra = {}

local SID = 'result-extra-session'

function TestWindowsResultExtra:setUp()
  self.orig = {}

  storage.sessions[SID] = {
    id = SID,
    messages = {},
    cwd = vim.fs.normalize(vim.fn.getcwd()),
  }

  save(sessions, 'is_in_progress', self.orig)
  self.in_progress = false
  sessions.is_in_progress = function(_)
    return self.in_progress
  end
  save(sessions, 'get_progress_message', self.orig)
  self.progress_message = nil
  sessions.get_progress_message = function(_)
    return self.progress_message
  end
  save(sessions, 'get_progress_reasoning_content', self.orig)
  self.progress_reasoning = nil
  sessions.get_progress_reasoning_content = function(_)
    return self.progress_reasoning
  end
  save(sessions, 'delete_message', self.orig)
  self.deleted = {}
  sessions.delete_message = function(sid, idx)
    table.insert(self.deleted, { sid = sid, idx = idx })
  end
  save(sessions, 'get_session_title', self.orig)
  sessions.get_session_title = function(_)
    return ''
  end

  self.auto_scroll_orig = config.config.auto_scroll
  self.render_markdown_orig = config.config.render_markdown
  config.config.render_markdown = false

  local result = require('chat.windows.result')
  result.close()
  result.create_buffer(SID)
  result.open_window(result.get_buf(), 0, 0, 20, 60)
  self.result = result
end

function TestWindowsResultExtra:tearDown()
  for _, entry in ipairs(self.orig) do
    entry.module[entry.name] = entry.fn
  end
  config.config.auto_scroll = self.auto_scroll_orig
  config.config.render_markdown = self.render_markdown_orig
  self.result.close()
  storage.sessions[SID] = nil
end

local function buf_lines(result)
  return vim.api.nvim_buf_get_lines(result.get_buf(), 0, -1, false)
end

local function buf_contains(result, text)
  for _, l in ipairs(buf_lines(result)) do
    if l == text then
      return true
    end
  end
  return false
end

--- True when any buffer line contains the substring (formatter prefixes
--- like "> " or role headers may wrap the text).
local function buf_has_substr(result, text)
  for _, l in ipairs(buf_lines(result)) do
    if l:find(text, 1, true) then
      return true
    end
  end
  return false
end

function TestWindowsResultExtra:testPushTextStartWithReasoning()
  self.result.push_text({
    is_start = true,
    reasoning_content = 'pondering',
  })
  lu.assertTrue(buf_contains(self.result, '> pondering'))
end

function TestWindowsResultExtra:testPushTextStartWithContentWritesBlank()
  self.result.push_text({
    is_start = true,
    content = 'answer body',
  })
  lu.assertTrue(buf_contains(self.result, 'answer body'))
  lu.assertTrue(buf_contains(self.result, ''))
end

function TestWindowsResultExtra:testPushTextMultiLineReasoning()
  self.result.push_text({
    is_start = true,
    reasoning_content = 'first\nsecond',
  })
  lu.assertTrue(buf_contains(self.result, '> first'))
  lu.assertTrue(buf_contains(self.result, '> second'))
end

function TestWindowsResultExtra:testPushTextMultiLineContent()
  self.result.push_text({ content = 'l1\nl2' })
  lu.assertTrue(buf_contains(self.result, 'l1'))
  lu.assertTrue(buf_contains(self.result, 'l2'))
end

function TestWindowsResultExtra:testPushTextWithoutAutoScrollStillWrites()
  config.config.auto_scroll = false
  self.result.push_text({ content = 'plain' })
  lu.assertTrue(buf_contains(self.result, 'plain'))
end

function TestWindowsResultExtra:testOnToolCallStartAddsSeparator()
  self.result.push_text({ content = 'streamed tail' })
  self.result.on_tool_call_start(SID, SID, {
    role = 'assistant',
    tool_calls = {},
  })
  local lines = buf_lines(self.result)
  -- a blank separator line was inserted between the blocks
  local has_blank = false
  for _, l in ipairs(lines) do
    if l == '' then
      has_blank = true
      break
    end
  end
  lu.assertTrue(has_blank)
end

function TestWindowsResultExtra:testCreateBufferWithProgressMessage()
  self.result.close()
  self.in_progress = true
  self.progress_message = 'partial answer'
  self.result.create_buffer(SID)
  lu.assertTrue(buf_has_substr(self.result, 'partial answer'))
end

function TestWindowsResultExtra:testRenderWithProgressReasoning()
  self.in_progress = true
  self.progress_reasoning = 'streaming thoughts'
  self.result.render(SID)
  lu.assertTrue(buf_has_substr(self.result, 'streaming thoughts'))
end

function TestWindowsResultExtra:testRenderIdleSessionClearsProgress()
  self.result.render(SID)
  -- renders without crashing and leaves the buffer valid
  lu.assertTrue(vim.api.nvim_buf_is_valid(self.result.get_buf()))
end

function TestWindowsResultExtra:testDeleteAtCursorSkipsStreamingBlock()
  -- build a rendered buffer with one stored message
  storage.sessions[SID].messages = {
    { role = 'user', content = 'stored', created = os.time() },
  }
  self.result.render(SID)
  -- start streaming: the live block appears below all stored messages
  self.in_progress = true
  self.progress_message = 'streaming now'
  self.result.render(SID)
  self.result.scroll_to_bottom()
  lu.assertFalse(self.result.delete_message_at_cursor(SID))
  lu.assertEquals(0, #self.deleted)
end

function TestWindowsResultExtra:testDeleteAtCursorUnknownLine()
  self.result.render(SID)
  -- line 1 of an empty buffer is not mapped to any message
  vim.api.nvim_win_set_cursor(self.result.get_win(), { 1, 0 })
  lu.assertFalse(self.result.delete_message_at_cursor(SID))
end

function TestWindowsResultExtra:testDeleteAtCursorWithoutWindow()
  self.result.close()
  lu.assertFalse(self.result.delete_message_at_cursor(SID))
end

function TestWindowsResultExtra:testSetTitleIncludesSessionTitleAndTokens()
  sessions.get_session_title = function(_)
    return 'My Session'
  end
  self.result.set_title('chat.nvim', SID)
  local conf = vim.api.nvim_win_get_config(self.result.get_win())
  local title_text = ''
  for _, part in ipairs(conf.title or {}) do
    title_text = title_text .. tostring(part[1])
  end
  lu.assertStrContains(title_text, 'My Session | chat.nvim')
end

return TestWindowsExtra, TestWindowsResultExtra

