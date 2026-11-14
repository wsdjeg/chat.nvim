-- lua/chat/integrations/discord/discover.lua
-- Finding containers that config does not name: DM channels and guild text
-- channels.
--
-- A polling bot can not learn a DM channel id from an incoming message: it has
-- no cursor for a conversation it does not know about yet. Discord does expose
-- the bot's DM channels, so unlike Lark there is no need to open the
-- conversation from this side -- it only has to be listed and registered.
local log = require('chat.log')
local util = require('chat.integrations.discord.util')
local http = require('chat.integrations.discord.http')

local M = {}

-- Discord channel types (the subset this integration cares about).
local CHANNEL_TYPE_GUILD_TEXT = 0
local CHANNEL_TYPE_DM = 1

--- @param ctx table shared instance context
--- @return table discover API
function M.new(ctx)
  local state = ctx.state

  local function save_state()
    return ctx.save_state()
  end

  --- Display name for a DM channel: prefer the peer's username.
  --- @param channel table channel object from the API
  --- @return string|nil
  local function dm_peer_name(channel)
    for _, r in ipairs(channel.recipients or {}) do
      if r and type(r.username) == 'string' and r.username ~= '' then
        return r.username
      end
    end
    return nil
  end

  --- Peer (recipient) id of a DM channel, skipping the bot itself.
  --- @param channel table channel object from the API
  --- @return string|nil
  local function dm_peer_id(channel)
    for _, r in ipairs(channel.recipients or {}) do
      if r and type(r.id) == 'string' and r.id ~= state.bot_id then
        return r.id
      end
    end
    return nil
  end

  --- Register a single DM channel if it is admissible.
  ---
  --- Returns the peer id when the container is usable, nil when it was skipped
  --- -- so the caller can log a single summary line instead of one per channel.
  --- @param channel table channel object from the API
  --- @return string|nil peer id
  local function register_dm(channel)
    if type(channel) ~= 'table' or channel.type ~= CHANNEL_TYPE_DM then
      return nil
    end
    local channel_id = channel.id
    if type(channel_id) ~= 'string' or channel_id == '' then
      return nil
    end

    local peer = dm_peer_id(channel)
    if not peer then
      -- Without a recipient there is no one to attribute the conversation to,
      -- and no one to admit: skip rather than registering an orphan.
      return nil
    end

    if not util.is_p2p_allowed(peer) then
      log.debug('[Discord] Skip DM channel (peer not allowed): ' .. peer)
      return nil
    end

    local known = state.containers[channel_id]
    ctx.container.ensure_container(channel_id, {
      chat_type = 'p2p',
      peer = peer,
      name = dm_peer_name(channel),
    })
    if not known then
      log.info(
        '[Discord] DM channel ready: ' .. channel_id .. ' (' .. tostring(peer) .. ')'
      )
      -- Bind the session now: a container that arrives with history but no
      -- session would otherwise borrow the platform session.
      ctx.container.ensure_container_session(channel_id, state.containers[channel_id])
    end
    return peer
  end

  --- List the bot's DM channels and register every admissible one.
  ---
  --- Runs periodically (see `DM_REFRESH_TICKS`) because a DM channel only
  --- exists once the conversation was opened: a peer who writes for the first
  --- time between two refreshes is picked up on the next one.
  ---
  --- `callback` fires exactly once, on every path: the poll loop uses it to
  --- release its lock.
  --- @param callback? fun(added: integer)
  local function discover_dm_channels(callback)
    callback = callback or function() end

    if not util.p2p_enabled() then
      callback(0)
      return
    end

    if state.dm_jobid then
      log.debug('[Discord] Skip DM discovery: request already in flight')
      callback(0)
      return
    end

    local jobid = http.request('GET', '/users/@me/channels', nil, function(channels, err)
      state.dm_jobid = nil

      if channels == nil then
        log.debug('[Discord] DM channel listing failed: ' .. (err or 'unknown'))
        callback(0)
        return
      end

      if type(channels) ~= 'table' or (channels.message and not channels[1]) then
        log.debug(
          '[Discord] DM channel listing returned an error: '
            .. tostring(type(channels) == 'table' and channels.message or channels)
        )
        callback(0)
        return
      end

      local added = 0
      for _, channel in ipairs(channels) do
        if register_dm(channel) then
          added = added + 1
        end
      end
      if added > 0 then
        save_state()
      end
      log.debug(
        string.format(
          '[Discord] DM discovery: %d channel(s) listed, %d served',
          #channels,
          added
        )
      )
      callback(added)
    end)

    -- A job that could not be spawned returns 0: its callback never fires, so
    -- the lock has to be released here instead of staying taken forever.
    if not jobid or jobid <= 0 then
      log.warn('[Discord] Failed to start DM channel listing')
      state.dm_jobid = nil
      callback(0)
      return
    end

    state.dm_jobid = jobid
  end

  --- Register the text channels of a guild.
  ---
  --- Optional convenience (`integrations.discord.guild_id`): it saves listing
  --- every channel id by hand. Voice channels, categories and anything else
  --- that can not carry chat messages are skipped by type.
  ---
  --- Runs once per connect: guild channel ids are stable, unlike DM channels.
  --- @param callback? fun(added: integer)
  local function discover_guild_channels(callback)
    callback = callback or function() end

    local guild = util.guild_id()
    if not guild then
      callback(0)
      return
    end

    http.request('GET', '/guilds/' .. guild .. '/channels', nil, function(channels, err)
      if channels == nil then
        log.debug('[Discord] Guild channel listing failed: ' .. (err or 'unknown'))
        callback(0)
        return
      end

      if type(channels) ~= 'table' or (channels.message and not channels[1]) then
        log.debug(
          '[Discord] Guild channel listing returned an error: '
            .. tostring(type(channels) == 'table' and channels.message or channels)
        )
        callback(0)
        return
      end

      local added = 0
      for _, channel in ipairs(channels) do
        if type(channel) == 'table'
          and channel.type == CHANNEL_TYPE_GUILD_TEXT
          and type(channel.id) == 'string'
          and channel.id ~= ''
        then
          local known = state.containers[channel.id]
          ctx.container.ensure_container(channel.id, {
            chat_type = 'group',
            name = channel.name,
          })
          if not known then
            added = added + 1
          end
        end
      end
      if added > 0 then
        save_state()
      end
      log.info(
        string.format('[Discord] Guild %s: %d text channel(s) registered', guild, added)
      )
      callback(added)
    end)
  end

  --- Register the containers named in config.
  ---
  --- Cheap and synchronous: `channel_id` is the main container (so
  --- `current_session()` keeps addressing it) and `channel_ids` adds more guild
  --- channels. Always called on connect, even when discovery is unavailable.
  --- @return integer number of containers registered
  local function register_config_containers()
    local added = 0
    local main = util.main_channel_id()
    if main then
      if not state.containers[main] then
        added = added + 1
      end
      ctx.container.ensure_container(main, { chat_type = 'group' })
      -- The platform session belongs to the main container: keep both in sync
      -- so `set_session()` right after a bridge is visible in the lookup.
      local ctr = state.containers[main]
      if state.session and not ctr.session then
        ctr.session = state.session
      end
    end

    for _, channel_id in ipairs(util.extra_channel_ids()) do
      if not state.containers[channel_id] then
        added = added + 1
      end
      ctx.container.ensure_container(channel_id, { chat_type = 'group' })
    end

    if added > 0 then
      save_state()
    end
    return added
  end

  return {
    discover_dm_channels = discover_dm_channels,
    discover_guild_channels = discover_guild_channels,
    register_config_containers = register_config_containers,
    dm_peer_id = dm_peer_id,
    dm_peer_name = dm_peer_name,
  }
end

return M

