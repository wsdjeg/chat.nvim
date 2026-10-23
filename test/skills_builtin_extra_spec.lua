-- Coverage for the remaining builtin skill handlers in lua/chat/skills.lua
-- (/delete, /model & /provider without args, /title without args, /retry
-- success) plus the autoloaded user skills toggle-force-push and
-- setup-nvim-plugin-test.

local lu = require('luaunit')
local skills = require('chat.skills')
local sessions = require('chat.sessions')
local windows = require('chat.windows')
local spinners = require('chat.spinners')

TestSkillsBuiltinExtra = {}

function TestSkillsBuiltinExtra:setUp()
  self.sessions_orig = {
    is_in_progress = sessions.is_in_progress,
    delete = sessions.delete,
    get_session_provider = sessions.get_session_provider,
    set_session_provider = sessions.set_session_provider,
    set_session_model = sessions.set_session_model,
    set_session_title = sessions.set_session_title,
    get_session_title = sessions.get_session_title,
    retry = sessions.retry,
    get_session_disable_force_push = sessions.get_session_disable_force_push,
    set_session_disable_force_push = sessions.set_session_disable_force_push,
  }
  self.windows_orig = {
    open = windows.open,
    redraw_title = windows.redraw_title,
  }
  self.spinners_start_orig = spinners.start
  self.ui_select_orig = vim.ui.select
  self.ui_input_orig = vim.ui.input

  sessions.is_in_progress = function()
    return false
  end
end

function TestSkillsBuiltinExtra:tearDown()
  for m, orig in pairs(self.sessions_orig) do
    sessions[m] = orig
  end
  for m, orig in pairs(self.windows_orig) do
    windows[m] = orig
  end
  spinners.start = self.spinners_start_orig
  vim.ui.select = self.ui_select_orig
  vim.ui.input = self.ui_input_orig
  package.preload['chat.providers.fakep'] = nil
  package.loaded['chat.providers.fakep'] = nil
  package.preload['chat.providers.emptymodels'] = nil
  package.loaded['chat.providers.emptymodels'] = nil
end

local function stub_fake_provider(name, models)
  package.preload['chat.providers.' .. name] = function()
    return {
      available_models = function()
        return models
      end,
    }
  end
end

-- /delete --------------------------------------------------------------

function TestSkillsBuiltinExtra:testDeleteOpensNextSession()
  local opened = {}
  sessions.delete = function(sid)
    lu.assertEquals('s1', sid)
    return 'next-session'
  end
  windows.open = function(opt)
    table.insert(opened, opt)
  end
  lu.assertNil(skills._builtin_delete.handler('', { session = 's1' }))
  lu.assertEquals(1, #opened)
  lu.assertEquals('next-session', opened[1].session)
end

function TestSkillsBuiltinExtra:testDeleteNoNextSessionDoesNotOpen()
  local opened = 0
  sessions.delete = function()
    return nil
  end
  windows.open = function()
    opened = opened + 1
  end
  lu.assertNil(skills._builtin_delete.handler('', { session = 's1' }))
  lu.assertEquals(0, opened)
end

function TestSkillsBuiltinExtra:testDeleteInProgressRefused()
  local deleted = false
  sessions.is_in_progress = function()
    return true
  end
  sessions.delete = function()
    deleted = true
    return 'x'
  end
  lu.assertNil(skills._builtin_delete.handler('', { session = 's1' }))
  lu.assertFalse(deleted)
end

-- /model (no args) -----------------------------------------------------

function TestSkillsBuiltinExtra:testModelNoArgsNoModelsReturnsHint()
  sessions.get_session_provider = function()
    return 'no-such-provider'
  end
  local out = skills._builtin_model.handler('', { session = 's1' })
  lu.assertEquals('No models available for provider: no-such-provider', out)
end

function TestSkillsBuiltinExtra:testModelNoArgsSelectionSetsModel()
  stub_fake_provider('fakep', { 'fake-model-1', 'fake-model-2' })
  sessions.get_session_provider = function()
    return 'fakep'
  end
  local set_model
  sessions.set_session_model = function(sid, model)
    set_model = model
  end
  local seen_items
  vim.ui.select = function(items, _, on_choice)
    seen_items = items
    on_choice(items[1])
  end
  lu.assertNil(skills._builtin_model.handler('', { session = 's1' }))
  lu.assertEquals({ 'fake-model-1', 'fake-model-2' }, seen_items)
  lu.assertEquals('fake-model-1', set_model)
end

function TestSkillsBuiltinExtra:testModelNoArgsAbortedSelection()
  stub_fake_provider('fakep', { 'm1' })
  sessions.get_session_provider = function()
    return 'fakep'
  end
  local set = false
  sessions.set_session_model = function()
    set = true
  end
  vim.ui.select = function(_, _, on_choice)
    on_choice(nil)
  end
  lu.assertNil(skills._builtin_model.handler('', { session = 's1' }))
  lu.assertFalse(set)
end

function TestSkillsBuiltinExtra:testModelInProgressRefused()
  sessions.is_in_progress = function()
    return true
  end
  lu.assertNil(skills._builtin_model.handler('', { session = 's1' }))
end

-- /provider (no args) --------------------------------------------------

function TestSkillsBuiltinExtra:testProviderNoArgsSelectionFullFlow()
  stub_fake_provider('fakep', { 'fake-model-1', 'fake-model-2' })
  local provider_set, model_set, redrawn = false, nil, false
  sessions.set_session_provider = function(sid, name)
    provider_set = name
  end
  sessions.set_session_model = function(_, model)
    model_set = model
  end
  windows.redraw_title = function()
    redrawn = true
  end
  vim.ui.select = function(items, _, on_choice)
    on_choice('fakep')
  end
  lu.assertNil(skills._builtin_provider.handler('', { session = 's1' }))
  lu.assertEquals('fakep', provider_set)
  lu.assertEquals('fake-model-1', model_set)
  lu.assertTrue(redrawn)
end

function TestSkillsBuiltinExtra:testProviderNoArgsNoModelsSkipsModel()
  stub_fake_provider('emptymodels', {})
  local model_set = false
  sessions.set_session_provider = function() end
  sessions.set_session_model = function()
    model_set = true
  end
  windows.redraw_title = function() end
  vim.ui.select = function(_, _, on_choice)
    on_choice('emptymodels')
  end
  lu.assertNil(skills._builtin_provider.handler('', { session = 's1' }))
  lu.assertFalse(model_set)
end

function TestSkillsBuiltinExtra:testProviderNoArgsUnknownChoiceStillSets()
  local provider_set
  sessions.set_session_provider = function(_, name)
    provider_set = name
  end
  local model_set = false
  sessions.set_session_model = function()
    model_set = true
  end
  windows.redraw_title = function() end
  vim.ui.select = function(_, _, on_choice)
    on_choice('definitely-not-a-provider')
  end
  lu.assertNil(skills._builtin_provider.handler('', { session = 's1' }))
  lu.assertEquals('definitely-not-a-provider', provider_set)
  lu.assertFalse(model_set)
end

function TestSkillsBuiltinExtra:testProviderNoArgsAbortedSelection()
  local set = false
  sessions.set_session_provider = function()
    set = true
  end
  windows.redraw_title = function() end
  vim.ui.select = function(_, _, on_choice)
    on_choice(nil)
  end
  lu.assertNil(skills._builtin_provider.handler('', { session = 's1' }))
  lu.assertFalse(set)
end

function TestSkillsBuiltinExtra:testProviderInProgressRefused()
  sessions.is_in_progress = function()
    return true
  end
  lu.assertNil(skills._builtin_provider.handler('', { session = 's1' }))
end

-- /title (no args) ------------------------------------------------------

function TestSkillsBuiltinExtra:testTitleNoArgsInputSetsTitle()
  sessions.get_session_title = function()
    return 'Old Title'
  end
  local title_set, redrawn = nil, false
  sessions.set_session_title = function(sid, title)
    title_set = title
  end
  windows.redraw_title = function()
    redrawn = true
  end
  local prompt_opts
  vim.ui.input = function(opts, on_input)
    prompt_opts = opts
    on_input('Brand New')
  end
  lu.assertNil(skills._builtin_title.handler('', { session = 's1' }))
  lu.assertEquals('Brand New', title_set)
  lu.assertTrue(redrawn)
  lu.assertEquals('Old Title', prompt_opts.default)
end

function TestSkillsBuiltinExtra:testTitleNoArgsEmptyInputKeepsTitle()
  sessions.get_session_title = function()
    return 'Old Title'
  end
  local title_set = false
  sessions.set_session_title = function()
    title_set = true
  end
  windows.redraw_title = function() end
  vim.ui.input = function(_, on_input)
    on_input('')
  end
  lu.assertNil(skills._builtin_title.handler('', { session = 's1' }))
  lu.assertFalse(title_set)
end

function TestSkillsBuiltinExtra:testTitleNoArgsNilInputKeepsTitle()
  sessions.get_session_title = function()
    return nil
  end
  local title_set = false
  sessions.set_session_title = function()
    title_set = true
  end
  windows.redraw_title = function() end
  vim.ui.input = function(_, on_input)
    on_input(nil)
  end
  lu.assertNil(skills._builtin_title.handler('', { session = 's1' }))
  lu.assertFalse(title_set)
end

-- /retry ----------------------------------------------------------------

function TestSkillsBuiltinExtra:testRetryStartsSpinner()
  local started = 0
  spinners.start = function()
    started = started + 1
  end
  sessions.retry = function()
    return 42
  end
  lu.assertNil(skills._builtin_retry.handler('', { session = 's1' }))
  lu.assertEquals(1, started)
end

-- /toggle-force-push ----------------------------------------------------

function TestSkillsBuiltinExtra:testToggleForcePushDisablesWhenEnabled()
  local toggle = require('chat.skills.toggle-force-push')
  local recorded = nil
  sessions.get_session_disable_force_push = function()
    return false
  end
  sessions.set_session_disable_force_push = function(sid, v)
    recorded = v
  end
  local out = toggle.handler('', { session = 's1' })
  lu.assertEquals('Force push disabled for this session', out)
  lu.assertTrue(recorded)
end

function TestSkillsBuiltinExtra:testToggleForcePushEnablesWhenDisabled()
  local toggle = require('chat.skills.toggle-force-push')
  local recorded = nil
  sessions.get_session_disable_force_push = function()
    return true
  end
  sessions.set_session_disable_force_push = function(_, v)
    recorded = v
  end
  local out = toggle.handler('', { session = 's1' })
  lu.assertEquals('Force push enabled for this session', out)
  lu.assertFalse(recorded)
end

-- /setup-nvim-plugin-test ------------------------------------------------

function TestSkillsBuiltinExtra:testSetupNvimPluginTestReturnsUserRequest()
  local skill = require('chat.skills.setup-nvim-plugin-test')
  local out = skill.handler('', {})
  lu.assertEquals('user', out.role)
  lu.assertTrue(out.request)
  lu.assertStrContains(out.content, 'AGENTS.md')
  lu.assertStrContains(out.content, 'release-please-manifest.json')
  lu.assertStrContains(out.content, 'https://raw.githubusercontent.com/wsdjeg/chat.nvim/master/Makefile')
end

return TestSkillsBuiltinExtra

