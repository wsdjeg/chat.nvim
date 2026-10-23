-- Coverage for the remaining branches of chat.sessions.core:
-- system_prompt function config, delete switching/cleanup, previous/next
-- navigation, clear in-progress refusal, provider/model/prompt validation,
-- cwd fallback, upload_dir, pin/disable_force_push/title lifecycles and
-- M.retry branches.

local lu = require('luaunit')

local core = require('chat.sessions')
local storage = require('chat.sessions.storage')
local config = require('chat.config')
local windows = require('chat.windows')
local progress = require('chat.sessions.progress')
local protocol = require('chat.protocol')
local memory = require('chat.memory')
local integrations = require('chat.integrations')
local scheduler = require('chat.scheduler')
local spinners = require('chat.spinners')
local retry = require('chat.sessions.retry')
local failover = require('chat.sessions.failover')
local messages = require('chat.sessions.messages')

TestSessionsCoreExtra = {}

local orig = {}

local function save(module, name)
  table.insert(orig, { module = module, name = name, fn = module[name] })
end

function TestSessionsCoreExtra:setUp()
  orig = {}

  save(windows, 'current_session')
  save(windows, 'render_result_buf')
  save(windows, 'set_result_win_title')
  save(windows, 'redraw_title')
  self.current_session = nil
  windows.current_session = function()
    return self.current_session
  end
  self.renders = 0
  windows.render_result_buf = function()
    self.renders = self.renders + 1
  end
  self.titles_set = {}
  windows.set_result_win_title = function(t)
    table.insert(self.titles_set, t)
  end
  self.redraws = 0
  windows.redraw_title = function()
    self.redraws = self.redraws + 1
  end

  save(progress, 'is_in_progress')
  save(progress, 'cancel_progress')
  self.in_progress = false
  self.cancels = {}
  progress.is_in_progress = function(_)
    return self.in_progress
  end
  progress.cancel_progress = function(sid)
    table.insert(self.cancels, sid)
  end

  save(protocol, 'request')
  self.protocol_result = 7
  self.protocol_calls = {}
  protocol.request = function(opts)
    table.insert(self.protocol_calls, opts)
    return self.protocol_result
  end

  save(memory, 'get_memories')
  save(memory, 'delete')
  self.memories_list = {}
  self.memory_deletes = {}
  memory.get_memories = function()
    return self.memories_list
  end
  memory.delete = function(id)
    table.insert(self.memory_deletes, id)
  end

  save(integrations, 'on_session_deleted')
  self.deleted_notifications = {}
  integrations.on_session_deleted = function(sid)
    table.insert(self.deleted_notifications, sid)
  end

  save(scheduler, 'cancel_session')
  self.scheduler_cancels = {}
  scheduler.cancel_session = function(sid)
    table.insert(self.scheduler_cancels, sid)
  end

  save(spinners, 'start')
  self.spinner_starts = 0
  spinners.start = function()
    self.spinner_starts = self.spinner_starts + 1
  end

  save(retry, 'reset_retry_count')
  self.retry_resets = 0
  retry.reset_retry_count = function(_)
    self.retry_resets = self.retry_resets + 1
  end

  save(failover, 'reset')
  self.failover_resets = 0
  failover.reset = function(_)
    self.failover_resets = self.failover_resets + 1
  end

  save(messages, 'get_request_messages')
  self.request_messages = {}
  messages.get_request_messages = function(_)
    return self.request_messages
  end

  save(storage, 'write_cache')
  self.cache_writes = {}
  storage.write_cache = function(sid)
    table.insert(self.cache_writes, sid)
  end

  self.system_prompt_orig = config.config.system_prompt

  -- Isolate the session table: minimal_init's chat.setup() creates a
  -- session whose id is the startup timestamp. Sessions created here run
  -- within the same second, so M.new() would see an id collision and
  -- return nil. Swap in a clean table and restore the original in tearDown.
  self.saved_sessions = storage.sessions
  storage.sessions = {}
end

function TestSessionsCoreExtra:tearDown()
  for _, entry in ipairs(orig) do
    entry.module[entry.name] = entry.fn
  end
  config.config.system_prompt = self.system_prompt_orig
  storage.sessions = self.saved_sessions
  for _, sid in ipairs({ 'a', 'b', 'c', 'extra-1', 'extra-2' }) do
    storage.sessions[sid] = nil
  end
end

local function add_session(id)
  storage.sessions[id] = {
    id = id,
    messages = {},
    provider = 'p',
    model = 'm',
    prompt = '',
    cwd = vim.fs.normalize(vim.fn.getcwd()),
  }
end

-- system_prompt config function ------------------------------------------

function TestSessionsCoreExtra:testNewWithSystemPromptFunction()
  config.config.system_prompt = function()
    return 'custom prompt'
  end
  local id = core.new()
  lu.assertNotNil(id)
  lu.assertEquals('custom prompt', storage.sessions[id].prompt)
  storage.sessions[id] = nil
end

function TestSessionsCoreExtra:testNewWithSystemPromptNonString()
  config.config.system_prompt = function()
    return 42
  end
  local id = core.new()
  lu.assertNotNil(id)
  lu.assertEquals('42', storage.sessions[id].prompt)
  storage.sessions[id] = nil
end

function TestSessionsCoreExtra:testNewWithSystemPromptError()
  config.config.system_prompt = function()
    error('boom')
  end
  local id = core.new()
  lu.assertNotNil(id)
  lu.assertEquals('', storage.sessions[id].prompt)
  storage.sessions[id] = nil
end

-- delete ------------------------------------------------------------------

function TestSessionsCoreExtra:testDeleteDefaultsToCurrentSession()
  add_session('a')
  self.current_session = 'a'
  core.delete()
  lu.assertNil(storage.sessions['a'])
end

function TestSessionsCoreExtra:testDeleteWithoutAnySessionNoop()
  self.current_session = nil
  lu.assertNil(core.delete())
end

function TestSessionsCoreExtra:testDeleteCancelsProgressAndCleansUp()
  add_session('a')
  self.in_progress = true
  self.memories_list = {
    { id = 'm1', session = 'a' },
    { id = 'm2', session = 'other' },
  }
  core.delete('a')
  lu.assertEquals({ 'a' }, self.cancels)
  lu.assertEquals({ 'm1' }, self.memory_deletes)
  lu.assertEquals({ 'a' }, self.deleted_notifications)
  lu.assertEquals({ 'a' }, self.scheduler_cancels)
end

function TestSessionsCoreExtra:testDeleteCurrentSwitchesToNextSession()
  add_session('a')
  add_session('b')
  self.current_session = 'a'
  local next_id = core.delete('a')
  lu.assertEquals('b', next_id)
  lu.assertNil(storage.sessions['a'])
end

function TestSessionsCoreExtra:testDeleteCurrentWithNoRemainingCreatesNew()
  add_session('a')
  self.current_session = 'a'
  local next_id = core.delete('a')
  lu.assertNotNil(next_id)
  lu.assertNotNil(storage.sessions[next_id])
  storage.sessions[next_id] = nil
end

function TestSessionsCoreExtra:testDeleteNonCurrentReturnsNil()
  add_session('a')
  add_session('b')
  self.current_session = 'b'
  lu.assertNil(core.delete('a'))
  lu.assertNil(storage.sessions['a'])
end

-- previous / next ----------------------------------------------------------

function TestSessionsCoreExtra:testPreviousWrapsAround()
  add_session('a')
  add_session('b')
  add_session('c')
  self.current_session = 'a'
  lu.assertEquals('c', core.previous())
end

function TestSessionsCoreExtra:testPreviousMiddle()
  add_session('a')
  add_session('b')
  add_session('c')
  self.current_session = 'b'
  lu.assertEquals('a', core.previous())
end

function TestSessionsCoreExtra:testPreviousWithoutCurrentReturnsLast()
  add_session('a')
  add_session('b')
  self.current_session = nil
  lu.assertEquals('b', core.previous())
end

function TestSessionsCoreExtra:testPreviousEmptyCreatesNewSession()
  self.current_session = nil
  local id = core.previous()
  lu.assertNotNil(id)
  lu.assertNotNil(storage.sessions[id])
  storage.sessions[id] = nil
end

function TestSessionsCoreExtra:testNextAdvances()
  add_session('a')
  add_session('b')
  self.current_session = 'a'
  lu.assertEquals('b', core.next())
end

function TestSessionsCoreExtra:testNextWrapsAround()
  add_session('a')
  add_session('b')
  add_session('c')
  self.current_session = 'c'
  lu.assertEquals('a', core.next())
end

function TestSessionsCoreExtra:testNextWithoutCurrentReturnsFirst()
  add_session('a')
  add_session('b')
  self.current_session = nil
  lu.assertEquals('a', core.next())
end

function TestSessionsCoreExtra:testNextEmptyCreatesNewSession()
  self.current_session = nil
  local id = core.next()
  lu.assertNotNil(id)
  storage.sessions[id] = nil
end

-- clear --------------------------------------------------------------------

function TestSessionsCoreExtra:testClearInProgressRefused()
  add_session('a')
  self.in_progress = true
  lu.assertFalse(core.clear('a'))
end

function TestSessionsCoreExtra:testClearCurrentSessionResetsAndRenders()
  add_session('a')
  storage.sessions['a'].messages = { { role = 'user', content = 'x' } }
  self.current_session = 'a'
  lu.assertTrue(core.clear('a'))
  lu.assertEquals({}, storage.sessions['a'].messages)
  lu.assertEquals(0, storage.sessions['a'].usage.total_tokens)
  lu.assertNotNil(storage.sessions['a'].cleared_at)
  lu.assertEquals(1, self.renders)
  lu.assertEquals(1, #self.titles_set)
  lu.assertEquals({ 'a' }, self.cache_writes)
end

function TestSessionsCoreExtra:testClearOtherSessionSkipsRender()
  add_session('a')
  self.current_session = 'other'
  lu.assertTrue(core.clear('a'))
  lu.assertEquals(0, self.renders)
  lu.assertEquals(0, #self.titles_set)
end

function TestSessionsCoreExtra:testClearMissingSessionReturnsNil()
  lu.assertNil(core.clear('nope'))
  self.current_session = nil
  lu.assertNil(core.clear())
end

-- set_session_prompt -------------------------------------------------------

function TestSessionsCoreExtra:testSetSessionPromptValidation()
  lu.assertFalse(core.set_session_prompt('a', 42))
  add_session('a')
  lu.assertFalse(core.set_session_prompt(nil, 'x'))
  lu.assertFalse(core.set_session_prompt('nope', 'x'))
  lu.assertTrue(core.set_session_prompt('a', 'prompt here'))
  lu.assertEquals('prompt here', storage.sessions['a'].prompt)
end

-- provider / model ---------------------------------------------------------

function TestSessionsCoreExtra:testSetSessionProviderInProgressRefused()
  add_session('a')
  self.in_progress = true
  lu.assertNil(core.set_session_provider('a', 'p2'))
  lu.assertEquals('p', storage.sessions['a'].provider)
end

function TestSessionsCoreExtra:testSetSessionProviderSuccess()
  add_session('a')
  lu.assertTrue(core.set_session_provider('a', 'p2'))
  lu.assertEquals('p2', storage.sessions['a'].provider)
end

function TestSessionsCoreExtra:testSetSessionModelInProgressRefused()
  add_session('a')
  self.in_progress = true
  lu.assertNil(core.set_session_model('a', 'm2'))
  lu.assertEquals('m', storage.sessions['a'].model)
end

function TestSessionsCoreExtra:testSetSessionModelCurrentSessionRedraws()
  add_session('a')
  self.current_session = 'a'
  lu.assertNil(core.set_session_model('a', 'm2'))
  lu.assertEquals('m2', storage.sessions['a'].model)
  lu.assertEquals(1, self.redraws)
end

function TestSessionsCoreExtra:testSetSessionModelOtherSessionNoRedraw()
  add_session('a')
  self.current_session = 'other'
  core.set_session_model('a', 'm2')
  lu.assertEquals(0, self.redraws)
end

-- cwd ----------------------------------------------------------------------

function TestSessionsCoreExtra:testGetcwdFallsBackToCurrentDirectory()
  storage.sessions['a'] = {
    id = 'a',
    messages = {},
  }
  local cwd = core.getcwd('a')
  lu.assertEquals(vim.fs.normalize(vim.fn.getcwd()), cwd)
  -- fallback value is cached on the session
  lu.assertEquals(cwd, storage.sessions['a'].cwd)
  lu.assertNil(core.getcwd('nope'))
end

function TestSessionsCoreExtra:testChangeCwdCurrentSessionRedraws()
  add_session('a')
  self.current_session = 'a'
  core.change_cwd('a', '/some/new/cwd')
  lu.assertEquals('/some/new/cwd', storage.sessions['a'].cwd)
  lu.assertEquals(1, self.redraws)
end

function TestSessionsCoreExtra:testChangeCwdOtherSessionNoRedraw()
  add_session('a')
  self.current_session = 'other'
  core.change_cwd('a', '/some/new/cwd')
  lu.assertEquals(0, self.redraws)
end

function TestSessionsCoreExtra:testChangeCwdMissingSessionNoop()
  self.current_session = 'a'
  core.change_cwd('nope', '/x')
  lu.assertEquals(0, self.redraws)
end

-- upload_dir ----------------------------------------------------------------

function TestSessionsCoreExtra:testUploadDirLifecycle()
  lu.assertNil(core.get_upload_dir('nope'))
  core.set_upload_dir('nope', '/x') -- no-op, must not raise
  add_session('a')
  lu.assertNil(core.get_upload_dir('a'))
  core.set_upload_dir('a', '/tmp/upload/dir')
  lu.assertEquals(vim.fs.normalize('/tmp/upload/dir'), core.get_upload_dir('a'))
  -- reset with empty string / nil
  core.set_upload_dir('a', '')
  lu.assertNil(core.get_upload_dir('a'))
  core.set_upload_dir('a', '/tmp/again')
  core.set_upload_dir('a', nil)
  lu.assertNil(core.get_upload_dir('a'))
end

-- pin -----------------------------------------------------------------------

function TestSessionsCoreExtra:testPinValidationAndLifecycle()
  lu.assertNil(core.get_session_pin('nope'))
  lu.assertFalse(core.set_session_pin('a', 'yes'))
  lu.assertFalse(core.set_session_pin(nil, true))
  lu.assertFalse(core.set_session_pin('nope', true))
  add_session('a')
  lu.assertFalse(core.get_session_pin('a'))
  lu.assertTrue(core.set_session_pin('a', true))
  lu.assertTrue(core.get_session_pin('a'))
  lu.assertEquals({ 'a' }, self.cache_writes)
end

-- disable_force_push ----------------------------------------------------------

function TestSessionsCoreExtra:testDisableForcePushValidationAndLifecycle()
  lu.assertNil(core.get_session_disable_force_push('nope'))
  lu.assertFalse(core.set_session_disable_force_push('a', 'x'))
  lu.assertFalse(core.set_session_disable_force_push(nil, true))
  lu.assertFalse(core.set_session_disable_force_push('nope', true))
  add_session('a')
  lu.assertFalse(core.get_session_disable_force_push('a'))
  lu.assertTrue(core.set_session_disable_force_push('a', true))
  lu.assertTrue(core.get_session_disable_force_push('a'))
  core.set_session_disable_force_push('a', false)
  lu.assertFalse(core.get_session_disable_force_push('a'))
end

-- title -----------------------------------------------------------------------

function TestSessionsCoreExtra:testTitleValidationAndLifecycle()
  lu.assertNil(core.get_session_title('nope'))
  lu.assertFalse(core.set_session_title('a', 42))
  lu.assertFalse(core.set_session_title(nil, 't'))
  lu.assertFalse(core.set_session_title('nope', 't'))
  add_session('a')
  lu.assertEquals('', core.get_session_title('a'))
  lu.assertTrue(core.set_session_title('a', 'My Title'))
  lu.assertEquals('My Title', core.get_session_title('a'))
  lu.assertEquals({ 'a' }, self.cache_writes)
end

-- retry -----------------------------------------------------------------------

function TestSessionsCoreExtra:testRetryInProgressRefused()
  add_session('a')
  self.in_progress = true
  lu.assertNil(core.retry('a'))
  lu.assertEquals(0, #self.protocol_calls)
end

function TestSessionsCoreExtra:testRetryEmptyMessagesRefused()
  add_session('a')
  self.request_messages = {}
  lu.assertNil(core.retry('a'))
  lu.assertEquals(0, #self.protocol_calls)
end

function TestSessionsCoreExtra:testRetryTrailingAssistantRefused()
  add_session('a')
  self.request_messages = { { role = 'assistant', content = 'done' } }
  lu.assertNil(core.retry('a'))
  lu.assertEquals(0, #self.protocol_calls)
end

function TestSessionsCoreExtra:testRetryStartsRequestAndSpinner()
  add_session('a')
  self.current_session = 'a'
  self.request_messages = { { role = 'user', content = 'hi' } }
  self.protocol_result = 5
  local jobid = core.retry('a')
  lu.assertEquals(5, jobid)
  lu.assertEquals(1, #self.protocol_calls)
  lu.assertEquals(1, self.retry_resets)
  lu.assertEquals(1, self.failover_resets)
  lu.assertEquals(1, self.spinner_starts)
end

function TestSessionsCoreExtra:testRetryOtherSessionNoSpinner()
  add_session('a')
  self.current_session = 'other'
  self.request_messages = { { role = 'user', content = 'hi' } }
  self.protocol_result = 6
  lu.assertEquals(6, core.retry('a'))
  lu.assertEquals(0, self.spinner_starts)
end

function TestSessionsCoreExtra:testRetryRequestStartFailureReturnsNil()
  add_session('a')
  self.request_messages = { { role = 'user', content = 'hi' } }
  self.protocol_result = nil
  lu.assertNil(core.retry('a'))
  lu.assertEquals(0, self.spinner_starts)
end

return TestSessionsCoreExtra

