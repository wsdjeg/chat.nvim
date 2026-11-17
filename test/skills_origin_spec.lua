-- Coverage for the origin-aware receipt channel in lua/chat/skills.lua.
--
-- Contract under test:
--   * ctx.origin = 'local'  -> receipt goes to log.notify, handler returns nil
--   * ctx.origin = 'http'   -> receipt is returned as a string, no popup, so
--                             dispatch_skill appends it to the session and the
--                             remote caller can read it
--   * Neovim-UI-only paths (vim.ui.select / vim.ui.input / window switching)
--     are skipped for remote callers and answered with a usage string
--   * windows.redraw_title / set_result_win_title accept an optional session
--     and stay a no-op for a session the desktop is not showing

local lu = require('luaunit')

local skills = require('chat.skills')
local sessions = require('chat.sessions')
local windows = require('chat.windows')
local prompt = require('chat.windows.prompt')
local result = require('chat.windows.result')
local spinners = require('chat.spinners')
local log = require('chat.log')

TestSkillsOrigin = {}

local SESSION_ORIG = {}
local WINDOWS_ORIG = {}

function TestSkillsOrigin:setUp()
  for _, m in ipairs({
    'is_in_progress',
    'clear',
    'new',
    'delete',
    'get_session_provider',
    'set_session_provider',
    'get_session_model',
    'set_session_model',
    'change_cwd',
    'getcwd',
    'get_session_pin',
    'set_session_pin',
    'set_session_title',
    'get_session_title',
    'retry',
    'get_session_disable_force_push',
    'set_session_disable_force_push',
  }) do
    SESSION_ORIG[m] = sessions[m]
  end
  WINDOWS_ORIG = {
    open = windows.open,
    redraw_title = windows.redraw_title,
    set_result_win_title = windows.set_result_win_title,
    render_result_buf = windows.render_result_buf,
    current_session = windows.current_session,
  }
  self.spinners_start_orig = spinners.start
  self.log_notify_orig = log.notify
  self.ui_select_orig = vim.ui.select
  self.ui_input_orig = vim.ui.input
  self.prompt_redraw_orig = prompt.redraw_title
  self.result_set_title_orig = result.set_title

  -- Everything defaults to the benign local desktop case.
  sessions.is_in_progress = function()
    return false
  end
  sessions.getcwd = function()
    return vim.fn.getcwd()
  end
  windows.current_session = function()
    return 's1'
  end
  windows.open = function() end
  windows.render_result_buf = function() end

  -- Capture the window bumps instead of touching real windows.
  self.windows_calls = {}
  prompt.redraw_title = function(sid)
    table.insert(self.windows_calls, { redraw = sid })
  end
  result.set_title = function(text, sid)
    table.insert(self.windows_calls, { result_title = text, session = sid })
  end
  spinners.start = function() end

  -- Capture the popup channel; a remote receipt must never land here.
  self.notified = {}
  log.notify = function(msg, _)
    table.insert(self.notified, msg)
  end

  -- Any UI prompt reached in a remote test is a bug.
  self.ui_prompts = 0
  vim.ui.select = function()
    self.ui_prompts = self.ui_prompts + 1
  end
  vim.ui.input = function()
    self.ui_prompts = self.ui_prompts + 1
  end
end

function TestSkillsOrigin:tearDown()
  for m, orig in pairs(SESSION_ORIG) do
    sessions[m] = orig
  end
  for m, orig in pairs(WINDOWS_ORIG) do
    windows[m] = orig
  end
  spinners.start = self.spinners_start_orig
  log.notify = self.log_notify_orig
  vim.ui.select = self.ui_select_orig
  vim.ui.input = self.ui_input_orig
  prompt.redraw_title = self.prompt_redraw_orig
  result.set_title = self.result_set_title_orig
end

--- Join everything the handler put on the popup channel.
function TestSkillsOrigin:notify_text()
  return table.concat(self.notified, '\n')
end

-- skills.notify routing -------------------------------------------------

function TestSkillsOrigin:testNotifyLocalGoesToPopupAndReturnsNil()
  local ctx = {
    session = 's1',
    origin = 'local',
    notify = function(msg, _)
      log.notify(msg)
      return nil
    end,
  }
  lu.assertNil(skills.notify(ctx, 'hello'))
  lu.assertEquals('hello', self:notify_text())
end

function TestSkillsOrigin:testNotifyWithoutCtxFallsBackToPopup()
  lu.assertNil(skills.notify(nil, 'standalone'))
  lu.assertEquals('standalone', self:notify_text())
end

function TestSkillsOrigin:testNotifyFlattensTableMessagesForRemote()
  local ctx = {
    session = 's1',
    origin = 'http',
    notify = function(msg, _)
      if type(msg) == 'table' then
        return table.concat(msg, '\n')
      end
      return msg
    end,
  }
  lu.assertEquals('line one\nline two', skills.notify(ctx, { 'line one', 'line two' }))
  lu.assertEquals(0, #self.notified)
end

-- dispatch() wires the channel -----------------------------------------

function TestSkillsOrigin:testDispatchLocalOriginSuppressesReturn()
  skills.register({
    name = 'originlocal',
    handler = function(_, ctx)
      return skills.notify(ctx, 'local receipt')
    end,
  })
  local out = skills.dispatch('/originlocal', 's1', 'local')
  lu.assertNil(out)
  lu.assertEquals('local receipt', self:notify_text())
  skills.unregister('originlocal')
end

function TestSkillsOrigin:testDispatchHttpOriginReturnsReceipt()
  skills.register({
    name = 'originhttp',
    handler = function(_, ctx)
      return skills.notify(ctx, 'remote receipt')
    end,
  })
  local out = skills.dispatch('/originhttp', 's1', 'http')
  lu.assertEquals('remote receipt', out)
  lu.assertEquals(0, #self.notified)
  skills.unregister('originhttp')
end

function TestSkillsOrigin:testDispatchDefaultsOriginToLocal()
  local seen_origin
  skills.register({
    name = 'origindefault',
    handler = function(_, ctx)
      seen_origin = ctx.origin
      return skills.notify(ctx, 'defaulted')
    end,
  })
  local out = skills.dispatch('/origindefault', 's1')
  lu.assertEquals('local', seen_origin)
  lu.assertNil(out)
  lu.assertEquals('defaulted', self:notify_text())
  skills.unregister('origindefault')
end

-- /title ---------------------------------------------------------------

function TestSkillsOrigin:testTitleWithArgsRemoteReturnsReceipt()
  local title_set
  sessions.set_session_title = function(_, v)
    title_set = v
  end
  local out =
    skills._builtin_title.handler('My Title', { session = 's1', origin = 'http' })
  lu.assertEquals('Title: My Title', out)
  lu.assertEquals('My Title', title_set)
  lu.assertEquals(0, #self.notified)
end

function TestSkillsOrigin:testTitleNoArgsRemoteRefusesUI()
  local out =
    skills._builtin_title.handler('', { session = 's1', origin = 'http' })
  lu.assertStrContains(out, 'Usage: /title')
  lu.assertEquals(0, self.ui_prompts)
  lu.assertEquals(0, #self.notified)
end

function TestSkillsOrigin:testTitleNoArgsLocalStillPrompts()
  sessions.get_session_title = function()
    return 'Old'
  end
  local title_set
  sessions.set_session_title = function(_, v)
    title_set = v
  end
  vim.ui.input = function(_, on_input)
    on_input('Renamed')
  end
  lu.assertNil(
    skills._builtin_title.handler('', { session = 's1', origin = 'local' })
  )
  lu.assertEquals('Renamed', title_set)
end

-- /model ---------------------------------------------------------------

function TestSkillsOrigin:testModelWithArgsRemoteReturnsReceipt()
  local model_set
  sessions.set_session_model = function(_, v)
    model_set = v
  end
  local out =
    skills._builtin_model.handler('gpt-4o', { session = 's1', origin = 'http' })
  lu.assertEquals('Model: gpt-4o', out)
  lu.assertEquals('gpt-4o', model_set)
  lu.assertEquals(0, #self.notified)
end

function TestSkillsOrigin:testModelNoArgsRemoteRefusesUI()
  local out =
    skills._builtin_model.handler('', { session = 's1', origin = 'http' })
  lu.assertStrContains(out, 'Usage: /model')
  lu.assertEquals(0, self.ui_prompts)
end

-- /provider ------------------------------------------------------------

function TestSkillsOrigin:testProviderWithArgsRemoteReturnsReceipt()
  local provider_set
  sessions.set_session_provider = function(_, v)
    provider_set = v
  end
  local out = skills._builtin_provider.handler('openai', {
    session = 's1',
    origin = 'http',
  })
  lu.assertEquals('Provider: openai', out)
  lu.assertEquals('openai', provider_set)
  lu.assertEquals(0, #self.notified)
end

function TestSkillsOrigin:testProviderNoArgsRemoteRefusesUI()
  local out =
    skills._builtin_provider.handler('', { session = 's1', origin = 'http' })
  lu.assertStrContains(out, 'Usage: /provider')
  lu.assertEquals(0, self.ui_prompts)
end

-- /new -----------------------------------------------------------------

function TestSkillsOrigin:testNewRemoteDoesNotStealDesktopWindow()
  sessions.new = function()
    return 'brand-new'
  end
  local opened = 0
  windows.open = function()
    opened = opened + 1
  end
  local out =
    skills._builtin_new.handler('', { session = 's1', origin = 'http' })
  lu.assertEquals('New session: brand-new', out)
  lu.assertEquals(0, opened)
  lu.assertEquals(0, #self.notified)
end

function TestSkillsOrigin:testNewLocalStillOpensWindow()
  sessions.new = function()
    return 'brand-new'
  end
  local opened = 0
  windows.open = function()
    opened = opened + 1
  end
  lu.assertNil(
    skills._builtin_new.handler('', { session = 's1', origin = 'local' })
  )
  lu.assertEquals(1, opened)
end

function TestSkillsOrigin:testNewLocalFailureKeepsErrorReceipt()
  sessions.new = function()
    return nil, 'boom'
  end
  lu.assertNil(
    skills._builtin_new.handler('', { session = 's1', origin = 'local' })
  )
  lu.assertStrContains(self:notify_text(), 'boom')
end

-- /delete --------------------------------------------------------------

function TestSkillsOrigin:testDeleteRemoteDoesNotOpenNextSession()
  sessions.delete = function()
    return 'next-session'
  end
  local opened = 0
  windows.open = function()
    opened = opened + 1
  end
  local out =
    skills._builtin_delete.handler('', { session = 's1', origin = 'http' })
  lu.assertStrContains(out, 'next-session')
  lu.assertEquals(0, opened)
end

-- /clear ---------------------------------------------------------------

function TestSkillsOrigin:testClearRemoteSkipsDesktopRepaint()
  sessions.clear = function()
    return true
  end
  local rendered = 0
  windows.render_result_buf = function()
    rendered = rendered + 1
  end
  -- Desktop shows another session: repainting it would show the wrong buffer.
  windows.current_session = function()
    return 'other'
  end
  local out =
    skills._builtin_clear.handler('', { session = 's1', origin = 'http' })
  lu.assertEquals('Session cleared', out)
  lu.assertEquals(0, rendered)
end

function TestSkillsOrigin:testClearLocalRepaintsWhenItIsCurrent()
  sessions.clear = function()
    return true
  end
  local rendered = 0
  windows.render_result_buf = function()
    rendered = rendered + 1
  end
  lu.assertNil(
    skills._builtin_clear.handler('', { session = 's1', origin = 'local' })
  )
  lu.assertEquals(1, rendered)
  lu.assertEquals('Session cleared', self:notify_text())
end

-- /retry ---------------------------------------------------------------

function TestSkillsOrigin:testRetryRemoteSkipsLocalSpinner()
  sessions.retry = function()
    return 42
  end
  local started = 0
  spinners.start = function()
    started = started + 1
  end
  local out =
    skills._builtin_retry.handler('', { session = 's1', origin = 'http' })
  lu.assertEquals('Retrying...', out)
  lu.assertEquals(0, started)
end

function TestSkillsOrigin:testRetryLocalStartsSpinner()
  sessions.retry = function()
    return 42
  end
  local started = 0
  spinners.start = function()
    started = started + 1
  end
  lu.assertNil(
    skills._builtin_retry.handler('', { session = 's1', origin = 'local' })
  )
  lu.assertEquals(1, started)
end

function TestSkillsOrigin:testRetryRemoteNothingToRetry()
  sessions.retry = function()
    return nil
  end
  local out =
    skills._builtin_retry.handler('', { session = 's1', origin = 'http' })
  lu.assertEquals('Nothing to retry', out)
end

-- in-progress guard + remaining state skills ---------------------------

function TestSkillsOrigin:testInProgressRemoteReturnsWarning()
  sessions.is_in_progress = function()
    return true
  end
  local out =
    skills._builtin_model.handler('gpt-4o', { session = 's1', origin = 'http' })
  lu.assertEquals('Request in progress.', out)
  lu.assertEquals(0, #self.notified)
end

function TestSkillsOrigin:testCwdRemoteReturnsReceipt()
  sessions.change_cwd = function() end
  local out =
    skills._builtin_cwd.handler('.', { session = 's1', origin = 'http' })
  lu.assertStrContains(out, 'CWD:')
  lu.assertEquals(0, #self.notified)
end

function TestSkillsOrigin:testPinRemoteReturnsReceipt()
  sessions.get_session_pin = function()
    return false
  end
  sessions.set_session_pin = function() end
  local out =
    skills._builtin_pin.handler('', { session = 's1', origin = 'http' })
  lu.assertEquals('Pinned', out)
  lu.assertEquals(0, #self.notified)
end

function TestSkillsOrigin:testToggleForcePushRemoteReturnsReceipt()
  local toggle = require('chat.skills.toggle-force-push')
  sessions.get_session_disable_force_push = function()
    return false
  end
  sessions.set_session_disable_force_push = function() end
  local out = toggle.handler('', { session = 's1', origin = 'http' })
  lu.assertEquals('Force push disabled for this session', out)
  lu.assertEquals(0, #self.notified)
end

-- windows title gating -------------------------------------------------

function TestSkillsOrigin:testRedrawTitleIgnoresForeignSession()
  windows.redraw_title('other')
  lu.assertEquals(0, #self.windows_calls)
end

function TestSkillsOrigin:testRedrawTitleTargetsGivenSession()
  windows.redraw_title('s1')
  lu.assertEquals(1, #self.windows_calls)
  lu.assertEquals('s1', self.windows_calls[1].redraw)
end

function TestSkillsOrigin:testRedrawTitleDefaultsToCurrentSession()
  windows.redraw_title()
  lu.assertEquals(1, #self.windows_calls)
  lu.assertEquals('s1', self.windows_calls[1].redraw)
end

function TestSkillsOrigin:testSetResultWinTitleIgnoresForeignSession()
  windows.set_result_win_title(' chat.nvim ', 'other')
  lu.assertEquals(0, #self.windows_calls)
end

function TestSkillsOrigin:testSetResultWinTitleTargetsGivenSession()
  windows.set_result_win_title(' chat.nvim ', 's1')
  lu.assertEquals(1, #self.windows_calls)
  lu.assertEquals('s1', self.windows_calls[1].session)
  lu.assertEquals(' chat.nvim ', self.windows_calls[1].result_title)
end

return TestSkillsOrigin

