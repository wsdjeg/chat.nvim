local lu = require('luaunit')
local bridge = require('chat.bridge')
local integrations = require('chat.integrations')

local saved_platform
local saved_list_platforms

--- Fake platform module registered as `fake`.
---
--- The facade is tested against a stub platform instead of a real one: the
--- real modules own process-wide state and would leak bindings between tests.
local function chat_platform(state)
  return {
    current_session = function()
      return state.session
    end,
    set_session = function(session)
      state.session = session
    end,
    bridge = {
      session = function()
        return state.session
      end,
      set_session = function(session)
        state.session = session
      end,
      session_for_chat = function(chat_id)
        if not chat_id then
          return state.session
        end
        return state.chats[chat_id] or state.session
      end,
      bind_chat = function(chat_id, session)
        if not chat_id then
          return false
        end
        if session == nil then
          state.chats[chat_id] = nil
        else
          state.chats[chat_id] = session
        end
        return true
      end,
      chats = function(session)
        local out = {}
        for chat_id, value in pairs(state.chats) do
          if value == session then
            table.insert(out, chat_id)
          end
        end
        table.sort(out)
        return out
      end,
    },
  }
end

local function platform_only(state)
  return {
    current_session = function()
      return state.session
    end,
    set_session = function(session)
      state.session = session
    end,
  }
end

TestBridge = {}

function TestBridge:setUp()
  saved_platform = integrations.platform
  saved_list_platforms = integrations.list_platforms

  self.state = { session = nil, chats = {} }
  self.mod = chat_platform(self.state)

  integrations.platform = function(name)
    if name == 'fake' then
      return self.mod
    end
    return nil
  end
  integrations.list_platforms = function()
    return { 'fake' }
  end
end

function TestBridge:tearDown()
  integrations.platform = saved_platform
  integrations.list_platforms = saved_list_platforms
end

function TestBridge:test_caps_unknown_platform_is_nil()
  lu.assertNil(bridge.caps('nonexistent'))
  lu.assertFalse(bridge.supports_chat('nonexistent'))
  lu.assertNil(bridge.session('nonexistent'))
end

function TestBridge:test_caps_platform_only_uses_current_session()
  self.mod = platform_only(self.state)
  self.state.session = 's1'

  lu.assertFalse(bridge.supports_chat('fake'))
  lu.assertEquals('s1', bridge.session('fake'))
  lu.assertEquals('s1', bridge.session_for('fake', 'oc_a'))
  lu.assertEquals({}, bridge.chats('fake', 's1'))
end

function TestBridge:test_caps_incomplete_bridge_raises()
  self.mod.bridge = { session = function() return nil end }
  lu.assertError(function()
    bridge.caps('fake')
  end)
end

function TestBridge:test_session_for_falls_back_to_platform_session()
  self.state.session = 's1'
  lu.assertEquals('s1', bridge.session_for('fake', nil))
  lu.assertEquals('s1', bridge.session_for('fake', 'unknown-chat'))
end

function TestBridge:test_session_for_chat_binding()
  self.state.session = 's-main'
  self.state.chats['oc_p2p'] = 'sess-p2p'
  lu.assertEquals('sess-p2p', bridge.session_for('fake', 'oc_p2p'))
end

function TestBridge:test_bind_unknown_platform_is_false()
  lu.assertFalse(bridge.bind('nonexistent', 's1'))
end

function TestBridge:test_bind_without_session_is_nil()
  lu.assertNil(bridge.bind('fake', nil))
end

function TestBridge:test_bind_sets_platform_session()
  lu.assertTrue(bridge.bind('fake', 's1'))
  lu.assertEquals('s1', bridge.session('fake'))
end

function TestBridge:test_bind_is_idempotent()
  self.state.session = 's1'
  lu.assertTrue(bridge.bind('fake', 's1'))
  lu.assertEquals('s1', self.state.session)
end

-- Regression: rebinding used to leave the previous session's per-chat
-- bindings alive, so a chat kept talking in a session the plugin no longer
-- considered bridged.
function TestBridge:test_bind_drops_previous_chat_bindings()
  self.state.session = 's1'
  self.state.chats['oc_a'] = 's1'

  lu.assertTrue(bridge.bind('fake', 's2'))
  lu.assertEquals('s2', self.state.session)
  lu.assertNil(self.state.chats['oc_a'])
end

function TestBridge:test_bind_chat_without_capability_is_false()
  self.mod = platform_only(self.state)
  lu.assertFalse(bridge.bind_chat('fake', 'oc_a', 's1'))
end

function TestBridge:test_bind_chat_sets_chat_binding()
  self.state.session = 's-main'
  lu.assertTrue(bridge.bind_chat('fake', 'oc_p2p', 'sess-p2p'))
  lu.assertEquals('sess-p2p', self.state.chats['oc_p2p'])
  lu.assertEquals('s-main', self.state.session)
end

function TestBridge:test_unbind_unknown_platform_is_zero()
  lu.assertEquals(0, bridge.unbind('nonexistent', 's1'))
end

function TestBridge:test_unbind_unbound_session_is_zero()
  self.state.session = 'other'
  lu.assertEquals(0, bridge.unbind('fake', 's1'))
end

-- Regression: `unbridge` reported success while per-chat bindings survived,
-- which kept delivering replies to a session the UI showed as unbridged.
function TestBridge:test_unbind_clears_platform_and_chat_bindings()
  self.state.session = 's1'
  self.state.chats['oc_a'] = 's1'
  self.state.chats['oc_b'] = 'other'

  lu.assertEquals(2, bridge.unbind('fake', 's1'))
  lu.assertNil(self.state.session)
  lu.assertNil(self.state.chats['oc_a'])
  lu.assertEquals('other', self.state.chats['oc_b'])
end

function TestBridge:test_unbind_counts_only_matching_bindings()
  self.state.session = 's1'
  self.state.chats['oc_a'] = 's1'
  lu.assertEquals(2, bridge.unbind('fake', 's1'))
  lu.assertEquals(0, bridge.unbind('fake', 's1'))
end

function TestBridge:test_list_empty_for_unbound_session()
  lu.assertEquals({}, bridge.list('s1'))
  lu.assertEquals({}, bridge.list(nil))
end

function TestBridge:test_list_includes_platform_binding()
  self.state.session = 's1'
  lu.assertEquals({ 'fake' }, bridge.list('s1'))
end

-- Regression: display used to read only the platform session, so a session
-- bound to one chat was invisible to the title bar and `GET /bridge` while
-- still receiving replies.
function TestBridge:test_list_includes_per_chat_binding()
  self.state.chats['oc_p2p'] = 'sess-p2p'
  lu.assertEquals({ 'fake' }, bridge.list('sess-p2p'))
end

return TestBridge

