-- lua/chat/integrations/discord/util.lua
-- Config readers, constants and small helpers shared by every discord
-- submodule.
--
-- Nothing here keeps state: reads go to `chat.config` live, so a `config.setup()`
-- between test specs is always visible.
local config = require('chat.config')

local M = {}

--- Discord REST base URL shared by every request this integration makes.
M.API_BASE = 'https://discord.com/api/v10'

-- curl-level timeouts: a failing request is fast and definitive instead
-- of hanging until the watchdog fires
M.CONNECT_TIMEOUT = 5
M.MAX_TIME = 10

-- Safety net for lost job callbacks. Must be larger than MAX_TIME so it
-- never fires in normal operation -- if it does, something is a bug.
M.WATCHDOG_TIMEOUT = 15000

-- While an outage persists, re-log a heartbeat every N failed polls
M.FAILURE_HEARTBEAT = 10

-- Poll ticks between two refreshes of the bot's DM channel list. A DM channel
-- only exists once a conversation was opened, so new peers are discovered by
-- re-listing. 12 ticks at the 3s interval = 36s.
M.DM_REFRESH_TICKS = 12

--- `integrations.discord` config table.
--- @return table
function M.discord_config()
  return (config.config.integrations and config.config.integrations.discord)
    or {}
end

--- Bot token from config.
--- @return string|nil
function M.token()
  return M.discord_config().token
end

--- The configured main container (`channel_id`).
---
--- Kept as a plain config read: `current_session()` / `set_session()` are
--- platform-level APIs, and the shared layer depends on them. The main
--- container is the one those APIs address.
--- @return string|nil
function M.main_channel_id()
  return M.discord_config().channel_id
end

--- Extra group channels, from `channel_ids` (one id or a list).
---
--- A bot can serve several guild channels at once, the same way Lark serves
--- several group chats: each becomes its own container with its own cursor and
--- its own session.
--- @return string[]
function M.extra_channel_ids()
  local ids = M.discord_config().channel_ids
  if type(ids) == 'string' then
    ids = { ids }
  end
  local list = {}
  for _, id in ipairs(ids or {}) do
    if type(id) == 'string' and id ~= '' then
      table.insert(list, id)
    end
  end
  return list
end

--- Guild whose text channels are registered on connect (`guild_id`).
---
--- Optional: it saves listing every channel id by hand. Without it only the
--- containers named in config are polled.
--- @return string|nil
function M.guild_id()
  local id = M.discord_config().guild_id
  if type(id) == 'string' and id ~= '' then
    return id
  end
  return nil
end

--- `integrations.discord.p2p` config table.
--- @return table
function M.p2p_config()
  return M.discord_config().p2p or {}
end

--- Whether private (DM) chats are served at all.
--- @return boolean
function M.p2p_enabled()
  return M.p2p_config().enable ~= false
end

--- Curated DM allow list.
---
--- Returns nil when `p2p.allow` is not configured: Discord already gates who
--- may open a DM with the bot (the DM channel only appears once the user
--- started the conversation), so without a list every DM channel the API
--- reports for the bot is served. A non-empty list is authoritative -- only
--- the ids in it are served.
--- @return string[]|nil
function M.p2p_allow()
  local allow = M.p2p_config().allow
  if type(allow) == 'string' then
    allow = { allow }
  end
  if type(allow) ~= 'table' then
    return nil
  end
  local list = {}
  for _, id in ipairs(allow) do
    if type(id) == 'string' and id ~= '' then
      table.insert(list, id)
    end
  end
  if #list == 0 then
    return nil
  end
  return list
end

--- Whether a Discord user id may talk to the bot privately.
---
--- A group channel is shared by nature (the bot only answers mentions there,
--- plus slash commands), while a DM is one person talking to the bot in a
--- workspace of their own -- two peers must never share it, so the admission
--- check lives here.
--- @param user_id string|nil
--- @return boolean
function M.is_p2p_allowed(user_id)
  if not M.p2p_enabled() then
    return false
  end
  if type(user_id) ~= 'string' or user_id == '' then
    return false
  end
  local allow = M.p2p_allow()
  if not allow then
    return true
  end
  for _, id in ipairs(allow) do
    if id == user_id then
      return true
    end
  end
  return false
end

--- Sorted keys of a map, for stable output.
--- @param map table
--- @return string[]
function M.sorted_keys(map)
  local list = {}
  for k in pairs(map) do
    table.insert(list, k)
  end
  table.sort(list)
  return list
end

--- Root directory under which per-peer (DM) workspaces are created.
---
--- `integrations.discord.p2p.cwd_root` wins; otherwise the first entry of
--- `allowed_path` is used. That is deliberate: a workspace outside
--- `allowed_path` is useless because every file tool would refuse it, and
--- keeping the root inside the allowed tree means the isolation never widens
--- what the bot may touch.
---
--- Returns nil when nothing usable is configured, which makes the container
--- keep the session's default directory (the Neovim cwd).
--- @return string|nil
function M.p2p_cwd_root()
  local root = M.p2p_config().cwd_root
  if type(root) == 'string' and root ~= '' then
    return vim.fs.normalize(root)
  end

  local allowed = config.config.allowed_path
  if type(allowed) == 'table' then
    for _, entry in ipairs(allowed) do
      if type(entry) == 'string' and entry ~= '' then
        return vim.fs.normalize(entry)
      end
    end
    return nil
  end
  if type(allowed) == 'string' and allowed ~= '' then
    return vim.fs.normalize(allowed)
  end
  return nil
end

--- Sanitize a channel id into a single filesystem-safe path segment.
---
--- Discord snowflake ids are already safe, but the value comes from the API and
--- ends up as a directory name: anything unexpected is replaced instead of
--- rejected, so a malformed id can not escape the workspace root.
--- @param channel_id string
--- @return string
function M.workspace_dir_name(channel_id)
  return (tostring(channel_id):gsub('[^%w%-_]', '_'))
end

return M

