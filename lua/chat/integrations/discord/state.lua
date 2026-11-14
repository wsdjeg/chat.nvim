-- lua/chat/integrations/discord/state.lua
-- The state table plus its file round-trip.
--
-- `new()` hands out the table an integration *instance* owns: reloading
-- `chat.integrations.discord` (which the specs do on every setUp) therefore
-- starts from a blank state instead of inheriting the previous run's cursors
-- and in-flight flags.
--
-- Deduplication (`processed_ids`) is kept as a map plus an insertion-ordered
-- list of the same ids. The list is what makes eviction meaningful: the cap
-- keeps the *newest* messages, and both the in-memory table and the state file
-- stay bounded for the whole lifetime of the process.
local log = require('chat.log')
local util = require('chat.integrations.discord.util')

local json = vim.json

local M = {}

--- Fresh state table.
--- @return table
function M.new()
  return {
    timer = nil,
    callback = nil,
    is_running = false,
    is_fetching = false,
    processed_ids = {},
    -- Ids in processing order, oldest first. Mirrors `processed_ids`; the
    -- eviction rule needs to know which ids are the recent ones, and a plain
    -- map can not answer that (`pairs()` order is arbitrary).
    processed_order = {},
    max_processed_cache = 100,
    poll_interval = 3000,
    session = nil,
    -- Legacy mirror of the main container's cursor. Kept so a state file
    -- written by an older single-channel build resumes where it left off.
    last_message_id = nil,
    -- Bot identity, learned from /users/@me and persisted: group messages are
    -- only accepted when they @mention the bot, so an unknown id would drop
    -- every mention until the lookup answers again.
    bot_id = nil,
    bot_username = nil,
    -- In-flight /users/@me request, so a second tick does not start another.
    bot_jobid = nil,
    -- In-flight DM channel listing, same reason (it runs every DM_REFRESH_TICKS).
    dm_jobid = nil,
    -- Ticks since the last DM channel refresh.
    dm_ticks = 0,
    -- Channel the most recent inbound message came from.
    --
    -- The shared layer calls `send_typing(true)` with no routing hint at all
    -- (`start_typing_timer` in chat/integrations/init.lua), so a platform that
    -- serves several channels has no argument to address the right one with.
    -- Remembering the last active channel keeps the "typing…" indicator in the
    -- conversation being answered instead of leaking into the configured main
    -- channel -- where a DM peer's wait would be visible to the whole guild.
    --
    -- Not persisted: it describes the current run, not a durable binding.
    last_active_channel = nil,
    -- Consecutive failed polls (state-change logging).
    fail_count = 0,
    -- channel_id -> { chat_type, peer, name, session, last_message_id }
    --
    -- A guild channel and a DM channel are both *containers*: the messages
    -- endpoint takes `/channels/{id}/messages` for either. What differs is
    -- whether an @mention is required and where a reply goes -- plus the
    -- isolated workspace a DM peer gets. The `channel_id` config entry stays
    -- the main container, so `current_session()` / `set_session()` keep their
    -- platform-level meaning.
    containers = {},
  }
end

--------------------------------------------------
-- Dedup cache
--------------------------------------------------

--- Drop the oldest ids until the cache fits its cap.
---
--- Trimming happens in memory, not only on save: a long-running Neovim would
--- otherwise accumulate one entry per message ever seen and only bound the
--- table it writes to disk.
--- @param state table
--- @return integer number of ids evicted
function M.trim_processed(state)
  local cap = state.max_processed_cache or 100
  local order = state.processed_order
  if type(order) ~= 'table' then
    order = {}
    state.processed_order = order
  end

  local evicted = 0
  local overflow = #order - cap
  for _ = 1, overflow do
    local id = table.remove(order, 1)
    if id then
      state.processed_ids[id] = nil
      evicted = evicted + 1
    end
  end
  return evicted
end

--- Record a message id as processed.
---
--- Order matters: the id is appended after the existing ones, so eviction
--- always drops the least recently seen message and the newest `max` ids stay
--- guarded.
--- @param state table
--- @param id string|nil message id
--- @return boolean true when the id was new
function M.remember_processed(state, id)
  if type(id) ~= 'string' or id == '' then
    return false
  end
  if state.processed_ids[id] then
    return false
  end

  state.processed_ids[id] = true
  table.insert(state.processed_order, id)
  M.trim_processed(state)
  return true
end

--------------------------------------------------
-- File round-trip
--------------------------------------------------

--- Persist the state table.
--- @param state table
--- @param path string state file
--- @return boolean
function M.save(state, path)
  local containers = {}
  for channel_id, ctr in pairs(state.containers) do
    containers[channel_id] = {
      chat_type = ctr.chat_type,
      peer = ctr.peer,
      name = ctr.name,
      session = ctr.session,
      last_message_id = ctr.last_message_id,
    }
  end

  -- Walk the order list, not `processed_ids`: `pairs()` returns an arbitrary
  -- selection, so a "first N" cap threw away recent ids as often as old ones
  -- and let already-answered messages through after a restart.
  local processed_ids = {}
  local cap = state.max_processed_cache or 100
  local order = state.processed_order or {}
  local first = math.max(1, #order - cap + 1)
  for index = first, #order do
    local id = order[index]
    if id then
      processed_ids[id] = true
    end
  end

  -- Ids remembered before the order list existed (state file written by an
  -- older build) are still worth guarding while there is room for them.
  local count = vim.tbl_count(processed_ids)
  for id in pairs(state.processed_ids) do
    if count >= cap then
      break
    end
    if not processed_ids[id] then
      processed_ids[id] = true
      count = count + 1
    end
  end

  local data = {
    last_message_id = state.last_message_id,
    bot_id = state.bot_id,
    bot_username = state.bot_username,
    processed_ids = processed_ids,
    session = state.session,
    containers = containers,
  }

  local ok, encoded = pcall(json.encode, data)
  if not ok then
    log.error('[Discord] Failed to encode state')
    return false
  end

  local dir = vim.fn.fnamemodify(path, ':h')
  if vim.fn.isdirectory(dir) == 0 then
    vim.fn.mkdir(dir, 'p')
  end

  local file, err = io.open(path, 'w')
  if not file then
    log.error('[Discord] Failed to save state: ' .. (err or 'unknown'))
    return false
  end

  file:write(encoded)
  file:close()
  return true
end

--- Load the state table from disk.
--- @param state table
--- @param path string state file
--- @return boolean
function M.load(state, path)
  local file = io.open(path, 'r')
  if not file then
    return false
  end

  local content = file:read('*a')
  file:close()

  if not content or content == '' then
    return false
  end

  local ok, data = pcall(json.decode, content)
  if not ok or not data then
    return false
  end

  state.last_message_id = data.last_message_id

  -- `processed_ids` is a map (`id -> true`), so a loaded file carries no order
  -- information. The map is rebuilt first and the order list from its keys:
  -- the ids are all kept, and the cap re-applies on the next remember.
  state.processed_ids = {}
  state.processed_order = {}
  if type(data.processed_ids) == 'table' then
    for id in pairs(data.processed_ids) do
      if type(id) == 'string' and id ~= '' then
        state.processed_ids[id] = true
        table.insert(state.processed_order, id)
      end
    end
    M.trim_processed(state)
  end

  if data.session then
    state.session = data.session
  end

  -- Bot identity from the previous session. Old state files have neither key;
  -- the poll loop re-fetches the identity while it is missing.
  state.bot_id = nil
  if type(data.bot_id) == 'string' and data.bot_id ~= '' then
    state.bot_id = data.bot_id
  end
  state.bot_username = nil
  if type(data.bot_username) == 'string' and data.bot_username ~= '' then
    state.bot_username = data.bot_username
  end

  -- Containers: `channel_id` -> { chat_type, peer, session, cursor }.
  -- Old state files have no `containers` key, so the main container is derived
  -- from the legacy `last_message_id` on load. That keeps a single-channel
  -- setup resuming at exactly the same cursor as before.
  state.containers = {}
  if type(data.containers) == 'table' then
    for channel_id, ctr in pairs(data.containers) do
      if type(channel_id) == 'string' and type(ctr) == 'table' then
        state.containers[channel_id] = {
          chat_type = ctr.chat_type or 'group',
          peer = ctr.peer,
          name = ctr.name,
          session = ctr.session,
          last_message_id = ctr.last_message_id,
        }
      end
    end
  end

  local main = util.main_channel_id()
  if main and not state.containers[main] then
    state.containers[main] = {
      chat_type = 'group',
      last_message_id = state.last_message_id,
      session = state.session,
    }
  elseif main and state.containers[main] then
    -- The legacy field is the main container's cursor mirror: prefer the
    -- per-container value, fall back to the legacy one for old files.
    local ctr = state.containers[main]
    if not ctr.last_message_id then
      ctr.last_message_id = state.last_message_id
    end
    if not ctr.session then
      ctr.session = state.session
    end
  end

  log.debug('[Discord] State loaded')
  return true
end

return M

