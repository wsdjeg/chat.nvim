-- lua/chat/integrations/lark/state.lua
-- The state table plus its file round-trip.
--
-- `new()` hands out the table an integration *instance* owns: reloading
-- `chat.integrations.lark` (which the specs do on every setUp) therefore starts
-- from a blank state instead of inheriting the previous run's cursors and
-- in-flight flags.
local log = require('chat.log')
local util = require('chat.integrations.lark.util')

local json = vim.json

local M = {}

--- Fresh state table.
--- @return table
function M.new()
  return {
    timer = nil,
    last_message_id = nil,
    last_message_time = nil,
    callback = nil,
    is_running = false,
    is_fetching = false,
    processed_ids = {},
    max_processed_cache = 100,
    poll_interval = 3000,
    session = nil,
    -- Bot identity, learned from /bot/v3/info and persisted in the state file.
    -- Group messages are only accepted when they @mention the bot, so this id
    -- is load-bearing: while it is unknown every group mention looks like
    -- "addressed to somebody else".
    bot_id = nil,
    bot_name = nil,
    -- In-flight /bot/v3/info request, so a failed lookup is retried on the next
    -- poll instead of leaving the identity unknown for the whole session.
    bot_info_jobid = nil,
    -- ACL runtime entries, persisted in the state file. Config lists are
    -- merged on top of these (see acl.get_acl()).
    acl = {
      whitelist = {}, -- open_id -> true
      blacklist = {}, -- open_id -> true
    },
    -- configured text -> open_id, resolved once per config change.
    -- Successful and failed resolutions live in different fields: see
    -- acl.get_identities() / acl.resolve_acl().
    identities = {}, -- email / mobile / entry text -> open_id
    identities_hash = nil, -- checksum of the entries it was resolved from
    acl_resolving = false,
    -- open_id -> { last_seen = ms, name = string|nil }
    recent_senders = {},
    -- chat_id (`oc_xxx`) -> { chat_type, peer, session, last_seen_time }
    --
    -- A group and a p2p chat are both *containers*: the messages endpoint takes
    -- `container_id_type=chat&container_id=oc_...` for either. The `chat_id`
    -- config entry stays the main container, so `current_session()` /
    -- `set_session()` keep their platform-level meaning.
    containers = {},
  }
end

--- Persist the state table.
--- @param state table
--- @param path string state file
--- @return boolean
function M.save(state, path)
  -- Only serialize the fields a container actually owns. `last_message_time`
  -- in the record is the same value as the legacy top-level field for the
  -- main container, but keeping it here makes the per-container cursor the
  -- single source of truth after a reload.
  local containers = {}
  for chat_id, ctr in pairs(state.containers) do
    containers[chat_id] = {
      chat_type = ctr.chat_type,
      peer = ctr.peer,
      session = ctr.session,
      last_seen_time = ctr.last_seen_time,
    }
  end

  local data = {
    last_message_id = state.last_message_id,
    last_message_time = state.last_message_time,
    processed_ids = {},
    session = state.session,
    acl = {
      whitelist = util.sorted_keys(state.acl.whitelist),
      blacklist = util.sorted_keys(state.acl.blacklist),
    },
    -- 'nova@example.com' -> 'ou_xxx', plus the checksum of the config entries
    -- it was resolved from, so a config edit re-resolves and an unchanged
    -- config costs zero requests.
    identities = state.identities,
    identities_hash = state.identities_hash,
    recent_senders = state.recent_senders,
    -- Bot identity: group messages are only accepted when they @mention the
    -- bot, so losing this across a restart means dropping every group message
    -- until /bot/v3/info answers again.
    bot_id = state.bot_id,
    bot_name = state.bot_name,
    containers = containers,
  }

  local count = 0
  for id, _ in pairs(state.processed_ids) do
    count = count + 1
    if count <= state.max_processed_cache then
      data.processed_ids[id] = true
    end
  end

  local ok, encoded = pcall(json.encode, data)
  if not ok then
    log.error('[Lark] Failed to encode state')
    return false
  end

  local dir = vim.fn.fnamemodify(path, ':h')
  if vim.fn.isdirectory(dir) == 0 then
    vim.fn.mkdir(dir, 'p')
  end

  local file, err = io.open(path, 'w')
  if not file then
    log.error('[Lark] Failed to save state: ' .. (err or 'unknown'))
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
  state.last_message_time = data.last_message_time
  if data.processed_ids then
    state.processed_ids = data.processed_ids
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
  state.bot_name = nil
  if type(data.bot_name) == 'string' and data.bot_name ~= '' then
    state.bot_name = data.bot_name
  end

  -- Old state files have no `acl` / `recent_senders` keys: nil guards keep
  -- them loading unchanged.
  state.acl.whitelist = {}
  state.acl.blacklist = {}
  if data.acl then
    for _, id in ipairs(data.acl.whitelist or {}) do
      state.acl.whitelist[id] = true
    end
    for _, id in ipairs(data.acl.blacklist or {}) do
      state.acl.blacklist[id] = true
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

  -- Identity resolution cache: 'nova@example.com' -> 'ou_xxx' plus the
  -- checksum of the entries it came from. Old state files have neither key,
  -- so nil guards keep them loading unchanged.
  state.identities = {}
  if type(data.identities) == 'table' then
    for text, open_id in pairs(data.identities) do
      if type(text) == 'string' and type(open_id) == 'string' then
        state.identities[text] = open_id
      end
    end
  end
  state.identities_hash = type(data.identities_hash) == 'string'
    and data.identities_hash
    or nil

  -- Containers: `chat_id` -> { chat_type, peer, session, last_seen_time }.
  -- Old state files have no `containers` key, so the main container is
  -- derived from the legacy `last_message_time` on load. That keeps a
  -- single-chat setup resuming at exactly the same cursor as before.
  state.containers = {}
  if type(data.containers) == 'table' then
    for chat_id, ctr in pairs(data.containers) do
      if type(chat_id) == 'string' and type(ctr) == 'table' then
        state.containers[chat_id] = {
          chat_type = ctr.chat_type or 'group',
          peer = ctr.peer,
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
      last_seen_time = state.last_message_time,
      session = state.session,
    }
  elseif main and state.containers[main] then
    -- The legacy field is the main container's cursor mirror: prefer the
    -- per-container value, fall back to the legacy one for old files.
    local ctr = state.containers[main]
    if not ctr.last_seen_time then
      ctr.last_seen_time = state.last_message_time
    end
    if not ctr.session then
      ctr.session = state.session
    end
  end

  log.debug('[Lark] State loaded')
  return true
end

--- Move every container cursor to "now" (milliseconds).
---
--- The state file records where the previous session stopped, not a queue to
--- replay: a restart with an hours-old cursor makes the first tick fetch
--- everything written while the plugin was down and answer it in one burst.
--- Starting at "now" means only messages sent after the plugin started are
--- considered; leftover ids from the previous session stay in `processed_ids`,
--- so the boundary between the two is still guarded.
--- @param state table
--- @return string cursor written to every container
function M.reset_cursors_to_now(state)
  local now = tostring(os.time() * 1000)
  state.last_message_time = now
  for _, ctr in pairs(state.containers) do
    ctr.last_seen_time = now
  end
  return now
end

return M

