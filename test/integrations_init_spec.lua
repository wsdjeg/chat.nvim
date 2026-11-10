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
  -- Lark declares `bridge` for per-chat routing. Some tests replace it with a
  -- stub, so it has to be saved and restored alongside the methods: leaving it
  -- in place would leak a fake capability set into every later spec.
  'bridge',
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

-- One contract for both `:Chat bridge` and `PUT /session/:id/bridge`:
-- unknown platform is `false`, "nothing to bind" is `nil`. Collapsing the two
-- made the HTTP route report an unknown platform when the caller simply had
-- no session.
function TestIntegrationsInit:testSetSessionUnknownPlatformIsFalse()
  lu.assertFalse(integrations.set_session('nonexistent', 'sess_1'))
  lu.assertFalse(integrations.set_session('nonexistent', nil))
end

function TestIntegrationsInit:testSetSessionWithoutSessionIsNil()
  lu.assertNil(integrations.set_session('discord', nil))
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

-- The second argument of `send_message` is a routing hint, and its meaning is
-- per-platform: Lark reads it as a session, weixin reads it as the WeChat
-- `user_id`. Passing it to every platform made command replies
-- (`/status`, `/list`, `/session`) look up a context token under a session id
-- and die with "missing context_token", so nothing was sent back.
function TestIntegrationsInit:testReplyOmitsSessionForPlatformWithoutChats()
  local captured = {}
  for name, mod in pairs(integration_modules) do
    mod.connect = function(handler)
      captured[name] = handler
    end
  end
  integrations.on_message(function() end)

  local argc, first
  integration_modules.weixin.send_message = function(...)
    argc, first = select('#', ...), (...)
  end
  integration_modules.weixin.current_session = function() return 's1' end

  captured.weixin({ content = '/status' })

  lu.assertEquals(1, argc, 'platform without chat support takes content only')
  lu.assertStrContains(first, 'Session:')
end

-- The other half of the same contract: a platform that *can* address one chat
-- still receives the session, which is how Lark routes the reply.
function TestIntegrationsInit:testReplyKeepsSessionForPlatformWithChats()
  local captured = {}
  for name, mod in pairs(integration_modules) do
    mod.connect = function(handler)
      captured[name] = handler
    end
  end
  integrations.on_message(function() end)

  -- `bridge.caps` requires all five members when `integration.bridge` is set.
  integration_modules.lark.bridge = {
    session = function() return 'lark-session' end,
    set_session = function() end,
    session_for_chat = function() return nil end,
    bind_chat = function() return false end,
    chats = function() return {} end,
  }

  local argc, content, session
  integration_modules.lark.send_message = function(...)
    argc, content, session = select('#', ...), ...
  end

  captured.lark({ content = '/status' })

  lu.assertEquals(2, argc, 'chat-capable platform also receives a routing hint')
  lu.assertNotNil(content)
  lu.assertEquals('lark-session', session)
end

-- Another platform reads the same argument differently again: weixin's second
-- parameter is the WeChat `user_id`, so a session id reaching it is a bug that
-- silently drops the message.
function TestIntegrationsInit:testReplyWeixinNeverGetsSessionAsUserId()
  local captured = {}
  for name, mod in pairs(integration_modules) do
    mod.connect = function(handler)
      captured[name] = handler
    end
  end
  integrations.on_message(function() end)

  local argc, content, user_id
  integration_modules.weixin.send_message = function(...)
    argc, content, user_id = select('#', ...), ...
  end
  integration_modules.weixin.current_session = function() return 'wx-sess' end

  captured.weixin({ content = '/list' })

  lu.assertEquals(1, argc, 'no routing hint for a platform that has none')
  lu.assertNil(user_id, 'session id must not be passed as a user id')
  lu.assertStrContains(content, 'Available sessions')
end

-- Contract guard for every platform, not just the two that broke.
--
-- `reply()` passes a second argument only when the platform can address one
-- chat; the earlier bug passed it to everybody and weixin read it as a
-- `user_id`. Hardcoding weixin/lark in a spec only pins those two: the next
-- platform added would still be free to reintroduce it. So instead assert the
-- invariant against `bridge.supports_chat()` for *every* registered platform -
-- a new one is covered the moment it is registered.
function TestIntegrationsInit:testReplyArgCountFollowsChatCapabilityForEveryPlatform()
  local captured = {}
  for name, mod in pairs(integration_modules) do
    mod.connect = function(handler)
      captured[name] = handler
    end
  end
  integrations.on_message(function() end)

  local bridge = require('chat.bridge')
  for name, mod in pairs(integration_modules) do
    -- A session must resolve, otherwise the handler short-circuits before
    -- calling `send_message` and the assertion would pass vacuously.
    mod.current_session = function() return 's1' end

    local argc
    mod.send_message = function(...)
      argc = select('#', ...)
    end
    captured[name]({ content = '/status' })

    local expected = bridge.supports_chat(name) and 2 or 1
    lu.assertEquals(
      expected,
      argc,
      string.format(
        '%s: routing hint must be passed only when the platform supports one chat',
        name
      )
    )
  end
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
