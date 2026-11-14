-- lua/chat/integrations/discord.lua
-- Discord integration: facade over the modules in this directory.
--
--   discord/util.lua      config readers, constants, list helpers
--   discord/state.lua     the state table + its file round-trip
--   discord/http.lua      one authenticated REST request runner
--   discord/acl.lua       access control and the /allow, /deny, /acl commands
--   discord/container.lua containers (guild channels / DMs) and bound sessions
--   discord/discover.lua  DM channel and guild channel discovery
--   discord/send.lua      chunked queued delivery, typing, one-shot replies
--   discord/poll.lua      bot identity, filtering, per-container polling
--
-- Everything below only wires those pieces together and exposes the platform
-- API the shared layer (`chat.integrations`) calls. Each `require` of this file
-- builds a fresh instance (state, queue, timers), which is what makes reloading
-- the module in the test suite a full reset.
local config = require('chat.config')
local log = require('chat.log')

local util = require('chat.integrations.discord.util')
local state_module = require('chat.integrations.discord.state')
local acl_module = require('chat.integrations.discord.acl')
local container_module = require('chat.integrations.discord.container')
local discover_module = require('chat.integrations.discord.discover')
local send_module = require('chat.integrations.discord.send')
local poll_module = require('chat.integrations.discord.poll')

local M = {}

--------------------------------------------------
-- Instance context
--------------------------------------------------
local STATE_FILE = config.config.storage_dir .. 'integration/discord.json'

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

ctx.acl = acl_module.new(ctx)
ctx.container = container_module.new(ctx)
ctx.discover = discover_module.new(ctx)
ctx.send = send_module.new(ctx)
ctx.poll = poll_module.new(ctx)

--------------------------------------------------
-- Polling
--------------------------------------------------
M.connect = ctx.poll.connect
M.disconnect = ctx.poll.disconnect

--------------------------------------------------
-- Sending
--------------------------------------------------
M.send_message = ctx.send.send_message
M.reply = ctx.send.reply
M.send_typing = ctx.send.send_typing

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

--------------------------------------------------
-- Private chats
--------------------------------------------------
--- Admission policy for DM peers (`integrations.discord.p2p`, governed by
--- `integrations.discord.acl` when one is configured).
M.is_p2p_allowed = ctx.acl.is_p2p_allowed

--- List the bot's DM channels and register the admissible ones.
M.discover_dm_channels = ctx.discover.discover_dm_channels

--- Register the text channels of `integrations.discord.guild_id`.
M.discover_guild_channels = ctx.discover.discover_guild_channels

--------------------------------------------------
-- Access control
--------------------------------------------------
M.acl_mode = ctx.acl.acl_mode
M.get_acl = ctx.acl.get_acl
M.is_allowed = ctx.acl.is_allowed
M.is_admin = ctx.acl.is_admin
M.acl_allow = ctx.acl.acl_allow
M.acl_deny = ctx.acl.acl_deny
M.acl_status = ctx.acl.acl_status
M.get_recent_senders = ctx.acl.get_recent_senders

--------------------------------------------------
-- Status
--------------------------------------------------
function M.get_state()
  return {
    is_running = state.is_running,
    bot_id = state.bot_id,
    last_message_id = state.last_message_id,
    poll_interval = state.poll_interval,
    processed_count = vim.tbl_count(state.processed_ids),
    containers = vim.tbl_count(state.containers),
  }
end

--------------------------------------------------
-- Clear saved state
--------------------------------------------------
function M.clear_state()
  state.last_message_id = nil
  state.bot_id = nil
  state.bot_username = nil
  state.processed_ids = {}
  state.processed_order = {}
  state.containers = {}
  state.acl = { whitelist = {}, blacklist = {} }
  state.recent_senders = {}
  os.remove(STATE_FILE)
  log.info('[Discord] State cleared')
end

--------------------------------------------------
-- Legacy compatibility
--------------------------------------------------
M.receive_messages = M.connect

--------------------------------------------------
-- Cleanup on module unload
--------------------------------------------------
function M.cleanup()
  M.disconnect()
end

-- Filled in last: submodules call back into the facade (poll reaches
-- ctx.discover, discovery reaches ctx.container).
ctx.M = M

log.debug('[Discord] Integration loaded')

return M

