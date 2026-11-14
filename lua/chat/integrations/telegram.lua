-- lua/chat/integrations/telegram.lua
-- Telegram Bot integration: facade over the modules in this directory.
--
--   telegram/util.lua       config readers, constants, list helpers
--   telegram/state.lua      the state table + its file round-trip
--   telegram/container.lua  containers (group / private chats) and bound sessions
--   telegram/acl.lua        access control + in-chat /allow, /deny, /acl
--   telegram/poll.lua       bot identity, message filtering, polling, connect
--   telegram/send.lua       chunked queued delivery
--
-- Everything below only wires those pieces together and exposes the platform
-- API the shared layer (`chat.integrations`) calls. Each `require` of this file
-- builds a fresh instance (state, queue, timers), which is what makes reloading
-- the module in the test suite a full reset.
--
-- Where this differs from Lark: `getUpdates` is ONE global stream for the whole
-- bot rather than one poll per conversation, so there is a single cursor and a
-- single in-flight request. Per-chat containers still exist, because routing
-- needs to know whether an @mention is required (groups: yes, private: no) and
-- which session owns the conversation.
local config = require('chat.config')
local log = require('chat.log')

local state_module = require('chat.integrations.telegram.state')
local container_module = require('chat.integrations.telegram.container')
local acl_module = require('chat.integrations.telegram.acl')
local send_module = require('chat.integrations.telegram.send')
local poll_module = require('chat.integrations.telegram.poll')

local M = {}

--------------------------------------------------
-- Instance context
--------------------------------------------------
local STATE_FILE = config.config.storage_dir .. 'integration/telegram.json'

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
}

ctx.container = container_module.new(ctx)
ctx.acl = acl_module.new(ctx)
ctx.send = send_module.new(ctx)
ctx.poll = poll_module.new(ctx)

--------------------------------------------------
-- ACL
--------------------------------------------------
M.get_acl = ctx.acl.get_acl
M.acl_mode = ctx.acl.acl_mode
M.is_allowed = ctx.acl.is_allowed
M.is_admin = ctx.acl.is_admin
M.is_p2p_allowed = ctx.acl.is_p2p_allowed
M.acl_allow = ctx.acl.acl_allow
M.acl_deny = ctx.acl.acl_deny
M.acl_status = ctx.acl.acl_status
M.get_recent_senders = ctx.acl.get_recent_senders
M.parse_acl_command = ctx.acl.parse_acl_command
M.resolve_target = ctx.acl.resolve_target

--------------------------------------------------
-- Polling
--------------------------------------------------
M.connect = ctx.poll.connect
M.disconnect = ctx.poll.disconnect
M.get_bot_info = ctx.poll.get_bot_info

--------------------------------------------------
-- Sending
--------------------------------------------------
M.send_message = ctx.send.send_message
M.reply = ctx.send.reply

--------------------------------------------------
-- Session management (platform level: meaning unchanged)
--------------------------------------------------
M.current_session = ctx.container.current_session
M.set_session = ctx.container.set_session

--------------------------------------------------
-- Bindings
--------------------------------------------------
-- Optional methods: the shared layer calls them only when they exist, so the
-- other integrations keep their exact current behaviour.
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
M.chat_session = ctx.container.chat_session

--------------------------------------------------
-- Status / state maintenance
--------------------------------------------------
function M.get_state()
  return {
    is_running = state.is_running,
    bot_id = state.bot_id,
    bot_username = state.bot_username,
    last_update_id = state.last_update_id,
    poll_interval = state.poll_interval,
    processed_count = vim.tbl_count(state.processed_ids),
    containers = ctx.container.get_containers(),
  }
end

--- Forget the saved cursor and bot identity, so the next connect starts clean.
---
--- The file is removed rather than rewritten: `save_state()` would immediately
--- recreate it with the cleared fields, and a half-written state file is worse
--- than none.
function M.clear_state()
  state.last_update_id = nil
  state.bot_id = nil
  state.bot_username = nil
  state.processed_ids = {}
  state.processed_order = {}
  state.containers = {}
  state.session = nil
  os.remove(STATE_FILE)
  log.info('[Telegram] State cleared')
end

--------------------------------------------------
-- Cleanup
--------------------------------------------------
function M.cleanup()
  M.disconnect()
end

-- Filled in last: submodules call back into the facade (ACL replies go through
-- M.send_message).
ctx.M = M

log.debug('[Telegram] Integration loaded')

return M

