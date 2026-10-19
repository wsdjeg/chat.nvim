local lu = require('luaunit')
local skills = require('chat.skills')
local sessions = require('chat.sessions')
local windows = require('chat.windows')
local spinners = require('chat.spinners')

local sessions_orig = {}
local windows_orig = {}
local spinners_start_orig = spinners.start

TestSkillsBuiltin = {}

function TestSkillsBuiltin:setUp()
  for _, m in ipairs({
    'is_in_progress', 'clear', 'new', 'delete', 'set_session_model',
    'get_session_provider', 'set_session_provider', 'change_cwd',
    'get_session_pin', 'set_session_pin', 'set_session_title',
    'get_session_title', 'retry',
  }) do
    sessions_orig[m] = sessions[m]
  end
  windows_orig = {
    render_result_buf = windows.render_result_buf,
    set_result_win_title = windows.set_result_win_title,
    open = windows.open,
    redraw_title = windows.redraw_title,
  }
  sessions.is_in_progress = function() return false end
end

function TestSkillsBuiltin:tearDown()
  for m, orig in pairs(sessions_orig) do
    sessions[m] = orig
  end
  for m, orig in pairs(windows_orig) do
    windows[m] = orig
  end
  spinners.start = spinners_start_orig
end

function TestSkillsBuiltin:testClearInProgress()
  sessions.is_in_progress = function() return true end
  lu.assertNil(skills._builtin_clear.handler('', { session = 's1' }))
end

function TestSkillsBuiltin:testClear()
  sessions.clear = function() return true end
  windows.render_result_buf = function() end
  windows.set_result_win_title = function() end
  skills._builtin_clear.handler('', { session = 's1' })
  lu.assertTrue(true)
end

function TestSkillsBuiltin:testNew()
  sessions.new = function() return 'new-id' end
  windows.open = function() end
  local out = skills._builtin_new.handler('', {})
  lu.assertStrContains(out, 'new-id')
end

function TestSkillsBuiltin:testNewFails()
  sessions.new = function() return nil, 'err' end
  local out = skills._builtin_new.handler('', {})
  lu.assertEquals('err', out)
end

function TestSkillsBuiltin:testModelWithArgs()
  sessions.set_session_model = function(sid, m) end
  local out = skills._builtin_model.handler('gpt-4o', { session = 's1' })
  lu.assertStrContains(out, 'gpt-4o')
end

function TestSkillsBuiltin:testCwdValid()
  sessions.change_cwd = function() end
  windows.redraw_title = function() end
  local out = skills._builtin_cwd.handler('.', { session = 's1' })
  lu.assertStrContains(out, 'CWD')
end

function TestSkillsBuiltin:testCwdInvalid()
  local out = skills._builtin_cwd.handler('/nonexistent/xyz', { session = 's1' })
  lu.assertStrContains(out, 'Not a valid directory')
end

function TestSkillsBuiltin:testCwdNoArgs()
  local out = skills._builtin_cwd.handler('', { session = 's1' })
  lu.assertStrContains(out, 'Usage')
end

function TestSkillsBuiltin:testPinToggle()
  sessions.get_session_pin = function() return false end
  sessions.set_session_pin = function() end
  local out = skills._builtin_pin.handler('', { session = 's1' })
  lu.assertEquals('Pinned', out)
end

function TestSkillsBuiltin:testTitleWithArgs()
  sessions.set_session_title = function() end
  windows.redraw_title = function() end
  local out = skills._builtin_title.handler('My Title', { session = 's1' })
  lu.assertStrContains(out, 'My Title')
end

function TestSkillsBuiltin:testRetryInProgress()
  sessions.is_in_progress = function() return true end
  lu.assertNil(skills._builtin_retry.handler('', { session = 's1' }))
end

function TestSkillsBuiltin:testRetryNothing()
  sessions.retry = function() return nil end
  local out = skills._builtin_retry.handler('', { session = 's1' })
  lu.assertEquals('Nothing to retry', out)
end

function TestSkillsBuiltin:testHelp()
  local out = skills._builtin_help.handler('', {})
  lu.assertStrContains(out, 'Available skills')
end

function TestSkillsBuiltin:testProviderWithArgs()
  sessions.set_session_provider = function() end
  windows.redraw_title = function() end
  local out = skills._builtin_provider.handler('openai', { session = 's1' })
  lu.assertStrContains(out, 'openai')
end

return TestSkillsBuiltin
