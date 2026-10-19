local lu = require('luaunit')
local integrations = require('chat.integrations')
local windows = require('chat.windows')

local module_names = {
  'discord',
  'lark',
  'dingtalk',
  'wecom',
  'telegram',
  'weixin',
  'slack',
}
local integration_modules = {}
for _, n in ipairs(module_names) do
  integration_modules[n] = require('chat.integrations.' .. n)
end

local method_names = {
  'set_session',
  'send_message',
  'current_session',
  'send_typing',
  'disconnect',
  'connect',
}
local saved = {}
for name, mod in pairs(integration_modules) do
  saved[name] = {}
  for _, m in ipairs(method_names) do
    saved[name][m] = mod[m]
  end
end
local windows_current_session_orig = windows.current_session

local function stub_integrations()
  for _, mod in pairs(integration_modules) do
    mod.set_session = function() end
    mod.send_message = function() end
    mod.current_session = function() return nil end
    mod.send_typing = function() end
    mod.disconnect = function() end
    mod.connect = function() end
  end
end

local function restore_integrations()
  for name, mod in pairs(integration_modules) do
    for _, m in ipairs(method_names) do
      mod[m] = saved[name][m]
    end
  end
  windows.current_session = windows_current_session_orig
end

TestIntegrationsInit = {}

function TestIntegrationsInit:setUp()
  stub_integrations()
end

function TestIntegrationsInit:tearDown()
  restore_integrations()
end

function TestIntegrationsInit:testListPlatforms()
  local names = integrations.list_platforms()
  lu.assertNotNil(names)
  lu.assertTrue(#names >= 7)
  lu.assertTrue(vim.tbl_contains(names, 'discord'))
  lu.assertTrue(vim.tbl_contains(names, 'slack'))
end

function TestIntegrationsInit:testSetSessionInvalidBridge()
  lu.assertFalse(integrations.set_session('nonexistent', 's1'))
end

function TestIntegrationsInit:testSetSessionValidBridge()
  local called
  integration_modules.discord.set_session = function(sid) called = sid end
  local ok = integrations.set_session('discord', 'sess_1')
  lu.assertTrue(ok)
  lu.assertEquals('sess_1', called)
end

function TestIntegrationsInit:testOnResponseEmpty()
  integrations.on_response('s1', nil)
  integrations.on_response('s1', '')
  integrations.on_response('s1', '   ')
  lu.assertTrue(true)
end

function TestIntegrationsInit:testOnResponseNoMatch()
  integration_modules.discord.current_session = function() return 'other' end
  local sent = false
  integration_modules.discord.send_message = function() sent = true end
  integrations.on_response('s1', 'hello')
  lu.assertFalse(sent)
end

function TestIntegrationsInit:testOnResponseMatch()
  integration_modules.discord.current_session = function() return 's1' end
  local sent
  integration_modules.discord.send_message = function(c) sent = c end
  integrations.on_response('s1', 'hello')
  lu.assertEquals('hello', sent)
end

function TestIntegrationsInit:testGetIntegrations()
  integration_modules.discord.current_session = function() return 's1' end
  local names = integrations.get_integrations('s1')
  lu.assertTrue(vim.tbl_contains(names, 'discord'))
end

function TestIntegrationsInit:testUnbridgeNoSession()
  windows.current_session = function() return nil end
  lu.assertFalse(integrations.unbridge())
end

function TestIntegrationsInit:testUnbridgeSessionInvalidName()
  lu.assertFalse(integrations.unbridge_session('s1', 'nonexistent'))
end

function TestIntegrationsInit:testOnSessionDeleted()
  integration_modules.discord.current_session = function() return 's1' end
  local disconnected = false
  integration_modules.discord.disconnect = function() disconnected = true end
  integrations.on_session_deleted('s1')
  lu.assertTrue(disconnected)
end

function TestIntegrationsInit:testOnMessageCapturesHandler()
  local captured = {}
  for name, mod in pairs(integration_modules) do
    mod.connect = function(handler)
      captured[name] = handler
    end
  end
  local received = {}
  integrations.on_message(function(msg)
    table.insert(received, msg)
  end)

  lu.assertNotNil(captured.discord)

  local status_sent
  integration_modules.discord.send_message = function(c) status_sent = c end
  captured.discord({ content = '/status' })
  lu.assertStrContains(status_sent, 'No active session')

  captured.discord({ content = '/clear' })
  lu.assertTrue(true)
end

return TestIntegrationsInit
