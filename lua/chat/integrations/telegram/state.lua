-- lua/chat/integrations/telegram/state.lua
-- The state table plus its file round-trip.
--
-- `new()` hands out the table an integration *instance* owns: reloading
-- `chat.integrations.telegram` (which the specs do on every setUp) therefore
-- starts from a blank state instead of inheriting the previous run's offset and
-- in-flight flags.
--
-- Deduplication (`processed_ids`) is kept as a map plus an insertion-ordered
-- list of the same ids. The list is what makes eviction meaningful: the cap
-- keeps the *newest* updates, and both the in-memory table and the state file
-- stay bounded for the whole lifetime of the process.
local log = require('chat.log')
local util = require('chat.integrations.telegram.util')

local json = vim.json

local M = {}

--- Fresh state table.
--- @return table
function M.new()
  return {
    timer = nil,
    -- getUpdates cursor: the highest update_id already seen. One value for
    -- every chat, because the Bot API offsets are global, not per chat.
    --
    -- Unlike Lark there is no per-container cursor to keep, and the backlog
    -- is *not* discarded on start: Telegram only returns updates the bot has
    -- not consumed yet, so anything pending really was never answered.
    last_update_id = nil,
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
    -- Bot identity, learned from getMe and persisted in the state file.
    -- Group messages are only accepted when they @mention the bot, so this is
    -- load-bearing: while it is unknown every group mention looks like
    -- "addressed to somebody else".
    bot_id = nil,
    bot_username = nil,
    -- In-flight getMe request, so a failed lookup is retried on the next poll
    -- instead of leaving the identity unknown for the whole session.
    bot_info_jobid = nil,
    -- ACL runtime entries, persisted in the state file. Config lists are
    -- merged on top of these (see acl.get_acl()).
    acl = {
      whitelist = {}, -- user id -> true
      blacklist = {}, -- user id -> true
    },
    -- user id -> { last_seen = ms, name = string|nil }
    recent_senders = {},
    -- chat_id -> { chat_type, peer, title, session, last_seen_time }
    --
    -- A group and a private chat are both *containers*: replies are addressed
    -- with a chat_id for either, and each container owns its own session. The
    -- `chat_id` config entry stays the main container, so `current_session()` /
    -- `set_session()` keep their platform-level meaning.
    containers = {},
  }
end

--------------------------------------------------
-- Dedup cache
--------------------------------------------------

--- Drop the oldest ids until the cache fits its cap.
---
--- Trimming happens in memory, not only on save: a long-running Neovim would
--- otherwise accumulate one entry per update ever seen and only bound the
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

--- Record an update id as processed.
---
--- Accepts numbers (the Bot API delivers `update_id` as an integer) and
--- strings, and stores one canonical string key so a state file written by
--- either encoding loads the same way.
--- @param state table
--- @param id number|string|nil update id
--- @return boolean true when the id was new
function M.remember_processed(state, id)
  local key = util.id_to_string(id)
  if not key then
    return false
  end
  if state.processed_ids[key] then
    return false
  end

  state.processed_ids[key] = true
  table.insert(state.processed_order, key)
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
  for chat_id, ctr in pairs(state.containers) do
    containers[chat_id] = {
      chat_type = ctr.chat_type,
      peer = ctr.peer,
      title = ctr.title,
      session = ctr.session,
      last_seen_time = ctr.last_seen_time,
    }
  end

  -- Walk the order list, not `processed_ids`: `pairs()` returns an arbitrary
  -- selection, so a "first N" cap threw away recent ids as often as old ones
  -- and let already-answered updates through after a restart.
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
    last_update_id = state.last_update_id,
    processed_ids = processed_ids,
    session = state.session,
    acl = {
      whitelist = util.sorted_keys(state.acl.whitelist),
      blacklist = util.sorted_keys(state.acl.blacklist),
    },
    recent_senders = state.recent_senders,
    -- Bot identity: group messages are only accepted when they @mention the
    -- bot, so losing this across a restart means dropping every group message
    -- until getMe answers again.
    bot_id = state.bot_id,
    bot_username = state.bot_username,
    containers = containers,
  }

  local ok, encoded = pcall(json.encode, data)
  if not ok then
    log.error('[Telegram] Failed to encode state')
    return false
  end

  local dir = vim.fn.fnamemodify(path, ':h')
  if vim.fn.isdirectory(dir) == 0 then
    vim.fn.mkdir(dir, 'p')
  end

  local file, err = io.open(path, 'w')
  if not file then
    log.error('[Telegram] Failed to save state: ' .. (err or 'unknown'))
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
  if not ok or type(data) ~= 'table' then
    return false
  end

  -- The cursor is written as a JSON number; an older state file may carry the
  -- string form. Both are read back as a number because getUpdates wants
  -- `offset = cursor + 1`.
  state.last_update_id = nil
  if data.last_update_id ~= nil then
    local cursor = tonumber(data.last_update_id)
    if cursor then
      state.last_update_id = cursor
    end
  end

  -- `processed_ids` is a map (`id -> true`), so a loaded file carries no order
  -- information. The map is rebuilt first and the order list from its keys:
  -- the ids are all kept, and the cap re-applies on the next remember.
  state.processed_ids = {}
  state.processed_order = {}
  if type(data.processed_ids) == 'table' then
    for id in pairs(data.processed_ids) do
      local key = util.id_to_string(id)
      if key and not state.processed_ids[key] then
        state.processed_ids[key] = true
        table.insert(state.processed_order, key)
      end
    end
    M.trim_processed(state)
  end

  if data.session then
    state.session = data.session
  end

  -- Bot identity from the previous session. Old state files have neither
  -- key; the poll loop re-fetches the identity while it is missing.
  state.bot_id = nil
  if type(data.bot_id) == 'string' and data.bot_id ~= '' then
    state.bot_id = data.bot_id
  end
  state.bot_username = nil
  if type(data.bot_username) == 'string' and data.bot_username ~= '' then
    state.bot_username = data.bot_username
  end

  -- Old state files have no `acl` / `recent_senders` keys: nil guards keep
  -- them loading unchanged.
  state.acl.whitelist = {}
  state.acl.blacklist = {}
  if data.acl then
    for _, id in ipairs(data.acl.whitelist or {}) do
      local key = util.id_to_string(id)
      if key then
        state.acl.whitelist[key] = true
      end
    end
    for _, id in ipairs(data.acl.blacklist or {}) do
      local key = util.id_to_string(id)
      if key then
        state.acl.blacklist[key] = true
      end
    end
  end

  state.recent_senders = {}
  if type(data.recent_senders) == 'table' then
    for id, info in pairs(data.recent_senders) do
      if type(info) == 'table' then
        state.recent_senders[id] = {
          last_seen = info.last_seen,
          name = info.name,
        }
      end
    end
  end

  -- Containers: `chat_id` -> { chat_type, peer, title, session, last_seen_time }.
  -- Old state files have no `containers` key, so the main container is derived
  -- from the config on load. That keeps a single-chat setup behaving exactly
  -- as before.
  state.containers = {}
  if type(data.containers) == 'table' then
    for chat_id, ctr in pairs(data.containers) do
      local key = util.id_to_string(chat_id)
      if key and type(ctr) == 'table' then
        state.containers[key] = {
          chat_type = ctr.chat_type or 'group',
          peer = util.id_to_string(ctr.peer),
          title = ctr.title,
          session = ctr.session,
          last_seen_time = ctr.last_seen_time,
        }
      end
    end
  end

  local main = util.main_chat_id()
  if main and not state.containers[main] then
    state.containers[main] = {
      chat_type = 'group',
      session = state.session,
    }
  elseif main and state.containers[main] then
    local ctr = state.containers[main]
    if not ctr.session then
      ctr.session = state.session
    end
  end

  log.debug('[Telegram] State loaded')
  return true
end

return M

