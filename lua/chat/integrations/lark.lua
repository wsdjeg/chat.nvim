-- lua/chat/integrations/lark.lua
-- Feishu/Lark IM integration: facade over the modules in this directory.
--
--   lark/util.lua       config readers, constants, list helpers
--   lark/state.lua      the state table + its file round-trip
--   lark/container.lua  containers (group / p2p chats) and bound sessions
--   lark/acl.lua        access control + in-chat /allow, /deny, /acl
--   lark/poll.lua       bot identity, message filtering, polling, connect
--   lark/send.lua       chunked queued delivery
--   lark/p2p.lua        opening / provisioning private chats
--
-- Everything below only wires those pieces together and exposes the platform
-- API the shared layer (`chat.integrations`) calls. Each `require` of this file
-- builds a fresh instance (state, queue, timers), which is what makes reloading
-- the module in the test suite a full reset.
local config = require('chat.config')
local log = require('chat.log')

local state_module = require('chat.integrations.lark.state')
local container_module = require('chat.integrations.lark.container')
local acl_module = require('chat.integrations.lark.acl')
local send_module = require('chat.integrations.lark.send')
local p2p_module = require('chat.integrations.lark.p2p')
local poll_module = require('chat.integrations.lark.poll')

local M = {}

-- Upper bound for the "recent speakers" cache lives in lark/util.lua together
-- with the API base URL.

--------------------------------------------------
-- Instance context
--------------------------------------------------
local STATE_FILE = config.config.storage_dir .. 'integration/lark.json'

local state = state_module.new()

--- Instance context shared by every submodule. `M` is filled in at the bottom
--- of this file; the modules only reach for it at call time (never while
--- building), so the cycle is harmless.
local ctx = {
  state = state,
}

ctx.save_state = function()
  return state_module.save(state, STATE_FILE)
end

ctx.state_io = {
  load = function()
    return state_module.load(state, STATE_FILE)
  end,
  save = ctx.save_state,
  reset_cursors_to_now = function()
    return state_module.reset_cursors_to_now(state)
  end,
}

ctx.container = container_module.new(ctx)
ctx.acl = acl_module.new(ctx)
ctx.send = send_module.new(ctx)
ctx.p2p = p2p_module.new(ctx)
ctx.poll = poll_module.new(ctx)

--------------------------------------------------
-- ACL (Phase 1 of ideas/lark-acl-bindings.md)
--------------------------------------------------
M.get_identities = ctx.acl.get_identities
M.resolve_acl = ctx.acl.resolve_acl
M.acl_mode = ctx.acl.acl_mode
M.get_acl = ctx.acl.get_acl
M.is_allowed = ctx.acl.is_allowed
M.is_admin = ctx.acl.is_admin
M.is_p2p_allowed = ctx.acl.is_p2p_allowed
M.get_p2p_provision_list = ctx.acl.get_p2p_provision_list
M.acl_allow = ctx.acl.acl_allow
M.acl_deny = ctx.acl.acl_deny
M.acl_status = ctx.acl.acl_status
M.get_recent_senders = ctx.acl.get_recent_senders

--------------------------------------------------
-- Polling
--------------------------------------------------
M.connect = ctx.poll.connect
M.disconnect = ctx.poll.disconnect

--------------------------------------------------
-- Sending
--------------------------------------------------
M.send_message = ctx.send.send_message

--------------------------------------------------
-- Session management (platform level: meaning unchanged)
--------------------------------------------------
M.current_session = ctx.container.current_session
M.set_session = ctx.container.set_session

--------------------------------------------------
-- Bindings (Phase 2 of ideas/lark-acl-bindings.md)
--------------------------------------------------
-- Optional methods: the shared layer calls them only when they exist, so the
-- other six integrations keep their exact current behaviour.
M.get_binding = ctx.container.get_binding
M.set_binding = ctx.container.set_binding
M.get_bound_sessions = ctx.container.get_bound_sessions
M.get_chat_bindings = ctx.container.get_chat_bindings

--- Bridge capabilities consumed by `chat.bridge`.
---
--- Wiring only: the storage stays `state.session` + `containers[].session`,
--- this table just lets the shared layer ask the questions without knowing
--- which fields hold the answers.
M.bridge = ctx.container.bridge

--------------------------------------------------
-- Containers
--------------------------------------------------
M.get_containers = ctx.container.get_containers
M.add_container = ctx.container.add_container
M.create_p2p = ctx.p2p.create_p2p
M.provision_p2p = ctx.p2p.provision_p2p

--------------------------------------------------
-- Cleanup
--------------------------------------------------
function M.cleanup()
  M.disconnect()
end

-- Filled in last: submodules call back into the facade (ACL replies go through
-- M.send_message, /allow provisions through M.provision_p2p).
ctx.M = M

log.debug('[Lark] Integration loaded')

return M

