local M = {}

local config = require('chat.config')
local log = require('chat.log')
local job = require('job')
local curl = require('chat.curl')
local auth = require('chat.integrations.lark.auth')
local identity = require('chat.integrations.lark.identity')
local chunker = require('chat.utils.chunker')

local json = vim.json
local uv = vim.uv

--------------------------------------------------
-- constants
--------------------------------------------------
local STATE_FILE = config.config.storage_dir .. 'integration/lark.json'
local API_BASE = 'https://open.feishu.cn/open-apis'

-- Upper bound for the "recent speakers" cache kept in the state file. The
-- cache is meant for a future Neovim picker (allow / deny without copying
-- open_ids from the open platform console), so a handful is plenty.
local MAX_RECENT_SENDERS = 30

--------------------------------------------------
-- state
--------------------------------------------------
local state = {
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
  -- merged on top of these (see M.get_acl()).
  acl = {
    whitelist = {}, -- open_id -> true
    blacklist = {}, -- open_id -> true
  },
  -- configured text -> open_id, resolved once per config change.
  -- Successful and failed resolutions live in different fields: see
  -- M.get_identities() / M.resolve_acl().
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

--------------------------------------------------
-- helpers
--------------------------------------------------
local function sorted_keys(map)
  local list = {}
  for k in pairs(map) do
    table.insert(list, k)
  end
  table.sort(list)
  return list
end

--- Merge a config list with a runtime map into one sorted, de-duplicated list.
local function merge_ids(config_list, state_map)
  local result = {}
  local seen = {}

  for _, id in ipairs(config_list or {}) do
    if not seen[id] then
      seen[id] = true
      table.insert(result, id)
    end
  end

  for id in pairs(state_map or {}) do
    if not seen[id] then
      seen[id] = true
      table.insert(result, id)
    end
  end

  table.sort(result)
  return result
end

local function lark_config()
  return (config.config.integrations and config.config.integrations.lark) or {}
end

local function acl_config()
  return lark_config().acl or {}
end

local function p2p_config()
  return lark_config().p2p or {}
end

--- The configured main container (`chat_id`).
---
--- Kept as a plain config read: `current_session()` / `set_session()` are
--- platform-level APIs, and the shared layer depends on them. The main
--- container is the one those APIs address.
--- @return string|nil
local function main_chat_id()
  return lark_config().chat_id
end

--- Container record for a chat, created on first use.
---
--- A group and a p2p chat are the same kind of object to the messages
--- endpoint (`container_id_type=chat&container_id=oc_...`), so one table
--- covers both. Old state files have no `containers` key: the main one is
--- derived from config on demand, which keeps single-chat behaviour identical.
--- @param chat_id string
--- @param opts? table { chat_type = 'group'|'p2p', peer = string }
--- @return table
local function ensure_container(chat_id, opts)
  local ctr = state.containers[chat_id]
  if not ctr then
    ctr = { chat_type = 'group' }
    state.containers[chat_id] = ctr
  end
  if opts then
    if opts.chat_type then
      ctr.chat_type = opts.chat_type
    end
    if opts.peer then
      ctr.peer = opts.peer
    end
  end
  return ctr
end

--- Per-container message cursor (milliseconds).
---
--- The main container mirrors the legacy `last_message_time` field so a state
--- file written by an older version keeps working, and so `:Chat bridge lark`
--- style single-chat setups resume exactly where they left off.
--- @param chat_id string
--- @return string|nil
local function container_cursor(chat_id)
  local ctr = state.containers[chat_id]
  if ctr and ctr.last_seen_time then
    return ctr.last_seen_time
  end
  if chat_id == main_chat_id() then
    return state.last_message_time
  end
  return nil
end

--- Advance a container cursor, keeping the legacy field in sync for the main
--- container.
--- @param chat_id string
--- @param ms string|number
local function set_container_cursor(chat_id, ms)
  local ctr = ensure_container(chat_id)
  ctr.last_seen_time = ms
  if chat_id == main_chat_id() then
    state.last_message_time = ms
  end
end

--- Chat a session replies to.
---
--- The main container wins when several chats share one session, so a
--- platform-level `set_session()` (and the HTTP API that relies on it) keeps
--- addressing the configured `chat_id`.
--- @param session string|nil
--- @return string|nil
local function session_to_chat(session)
  if not session then
    return nil
  end
  local main = main_chat_id()
  local main_ctr = main and state.containers[main]
  if main_ctr and main_ctr.session == session then
    return main
  end
  for chat_id, ctr in pairs(state.containers) do
    if chat_id ~= main and ctr.session == session then
      return chat_id
    end
  end
  return nil
end

--------------------------------------------------
-- Save state to file
--------------------------------------------------
local function save_state()
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
      whitelist = sorted_keys(state.acl.whitelist),
      blacklist = sorted_keys(state.acl.blacklist),
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

  local dir = vim.fn.fnamemodify(STATE_FILE, ':h')
  if vim.fn.isdirectory(dir) == 0 then
    vim.fn.mkdir(dir, 'p')
  end

  local file, err = io.open(STATE_FILE, 'w')
  if not file then
    log.error('[Lark] Failed to save state: ' .. (err or 'unknown'))
    return false
  end

  file:write(encoded)
  file:close()
  return true
end

--------------------------------------------------
-- Load state from file
--------------------------------------------------
local function load_state()
  local file = io.open(STATE_FILE, 'r')
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

  local main = main_chat_id()
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

--------------------------------------------------
-- Startup cursor reset
--------------------------------------------------
--- Move every container cursor to "now" (milliseconds).
---
--- The state file records where the previous session stopped, not a queue to
--- replay: a restart with an hours-old cursor makes the first tick fetch
--- everything written while the plugin was down and answer it in one burst.
--- Starting at "now" means only messages sent after the plugin started are
--- considered; leftover ids from the previous session stay in `processed_ids`,
--- so the boundary between the two is still guarded.
--- @return string cursor written to every container
local function reset_cursors_to_now()
  local now = tostring(os.time() * 1000)
  state.last_message_time = now
  for _, ctr in pairs(state.containers) do
    ctr.last_seen_time = now
  end
  return now
end

--------------------------------------------------
-- ACL (Phase 1 of ideas/lark-acl-bindings.md)
--------------------------------------------------
-- Three modes:
--   allow_all  (default) - anyone in the chat may talk to the bot
--   whitelist            - only listed open_ids
--   blacklist            - everyone except listed open_ids
--
-- open_id (`ou_xxx`) can not be forged, unlike a display name, so it is the
-- only identity used here. Runtime grants/denies issued from the chat are
-- persisted in the state file; config lists are merged on top of them.
--
-- Config entries may be written as open_id, email or mobile number. Every
-- comparison therefore has to happen in open_id space: entries are resolved
-- once at connect time (see chat.integrations.lark.identity) and cached in
-- state.identities.

--- Checksum of every configured ACL entry, so a config edit invalidates the
--- resolution cache without re-resolving on every poll.
--- @return string
local function acl_entries_hash()
  local cfg = acl_config()
  local entries = {}
  vim.list_extend(entries, cfg.admins or {})
  vim.list_extend(entries, cfg.whitelist or {})
  vim.list_extend(entries, cfg.blacklist or {})
  -- Sorted so the same set always yields the same checksum regardless of
  -- the order lists were written in.
  table.sort(entries)
  return tostring(#entries) .. '|' .. table.concat(entries, '\n')
end

--- All configured ACL entries, de-duplicated.
--- @return string[]
local function acl_entries()
  local cfg = acl_config()
  local seen, out = {}, {}
  -- `pairs`, not `ipairs`: a config without `admins` makes the list sparse
  -- ({[2]=whitelist, [3]=blacklist}), and ipairs stops at the first nil —
  -- which silently skipped every whitelist / blacklist entry.
  local lists = { cfg.admins, cfg.whitelist, cfg.blacklist }
  for _, list in pairs(lists) do
    for _, entry in ipairs(list or {}) do
      if type(entry) == 'string' and entry ~= '' and not seen[entry] then
        seen[entry] = true
        table.insert(out, entry)
      end
    end
  end
  return out
end

--- Normalize one configured entry into open_id space.
---
--- Returns the entry itself when it is already an open_id: that form is
--- usable without any lookup, so it keeps working even if the contact API is
--- unavailable. Email / mobile entries return their resolved open_id, or nil
--- when they were never resolved.
--- @param entry string
--- @return string|nil
local function to_open_id(entry)
  if type(entry) ~= 'string' then
    return nil
  end
  if entry:match('^ou_') then
    return entry
  end
  return state.identities[entry]
end

--- Map of resolved ACL identities (`'nova@example.com' -> 'ou_xxx'`).
--- @return table
function M.get_identities()
  local copy = {}
  for text, open_id in pairs(state.identities) do
    copy[text] = open_id
  end
  return copy
end

--- Resolve every configured ACL entry into open_id space.
---
--- Runs once per connect, and again only when the configured entries changed
--- since the cache was written. open_id entries cost zero requests; email /
--- mobile entries go through `contact/v3/users/batch_get_id` (see
--- chat.integrations.lark.identity).
---
--- Failure policy follows ideas/lark-acl-bindings.md 3.2.7: an unresolved
--- entry is simply absent from state.identities, so it never matches. That
--- fails closed for `admins` / `whitelist` and fails open for `blacklist`.
---
--- @param callback? fun() Called once the cache is settled (may be immediate)
function M.resolve_acl(callback)
  callback = callback or function() end

  local entries = acl_entries()
  local hash = acl_entries_hash()

  -- Unchanged config: the persisted cache is still valid, zero requests.
  if hash == state.identities_hash then
    log.debug('[Lark] ACL identities unchanged, reusing cache')
    callback()
    return
  end

  if state.acl_resolving then
    -- connect() was called while a resolution was still in flight.
    callback()
    return
  end

  state.acl_resolving = true

  identity.resolve(entries, function(result)
    state.acl_resolving = false

    state.identities = {}
    for text, open_id in pairs(result) do
      -- `failed` (table) and `error` (string) are metadata, not identities.
      -- The explicit key check matters: `error` is a string too, so a plain
      -- type test would store it as a bogus identity.
      if text == 'failed' or text == 'error' then
        goto continue
      end
      -- Anything that did not resolve is left out on purpose: no match, no
      -- access.
      if type(open_id) == 'string' then
        state.identities[text] = open_id
      end
      ::continue::
    end

    local failed = result.failed or {}
    if result.error then
      log.error('[Lark] ACL identity resolution failed: ' .. result.error)
    end
    if #failed > 0 then
      log.warn(
        '[Lark] Unresolved ACL entries are ignored: '
          .. table.concat(failed, ', ')
      )
    end

    -- Stamp the checksum only when the lookups had a fair chance to run.
    -- A total failure (no network / missing permission) must be retried on
    -- the next connect instead of being cached forever.
    if result.error then
      state.identities_hash = nil
    else
      state.identities_hash = hash
    end

    save_state()
    callback()
  end)
end

--- Effective ACL mode from config.
--- @return string 'allow_all' | 'whitelist' | 'blacklist'
function M.acl_mode()
  return acl_config().mode or 'allow_all'
end

--- Full effective ACL: config lists merged with runtime grants/denies.
--- @return table { mode = string, admins = string[], whitelist = string[], blacklist = string[] }
function M.get_acl()
  local cfg = acl_config()
  return {
    mode = M.acl_mode(),
    admins = cfg.admins or {},
    whitelist = merge_ids(cfg.whitelist, state.acl.whitelist),
    blacklist = merge_ids(cfg.blacklist, state.acl.blacklist),
  }
end

--- Is this open_id allowed to talk to the bot?
---
--- Admins always pass, so they can still recover a whitelist that locked
--- them out of the management commands.
---
--- Runtime entries (issued from the chat, persisted in the state file) win
--- over the configured mode: an admin can `/deny` (or `/allow`) a user even
--- while the mode is `allow_all`, which is what keeps the in-chat commands
--- useful without having to edit the config first.
--- @param open_id string|nil
--- @return boolean
function M.is_allowed(open_id)
  if not open_id then
    return false
  end

  if M.is_admin(open_id) then
    return true
  end

  if state.acl.blacklist[open_id] then
    return false
  end
  if state.acl.whitelist[open_id] then
    return true
  end

  local mode = M.acl_mode()
  local cfg = acl_config()

  if mode == 'whitelist' then
    -- Fail closed: an email / mobile that never resolved maps to nil and
    -- simply never matches.
    for _, entry in ipairs(cfg.whitelist or {}) do
      if to_open_id(entry) == open_id then
        return true
      end
    end
    return false
  elseif mode == 'blacklist' then
    -- Fail open: an unresolvable entry can not be identified in this message,
    -- so it does not block anyone (the failure is logged at connect time).
    for _, entry in ipairs(cfg.blacklist or {}) do
      if to_open_id(entry) == open_id then
        return false
      end
    end
    return true
  end

  -- allow_all: unchanged behaviour for existing setups.
  return true
end

--- Is this open_id one of the configured admins?
---
--- `admins` accepts open_id, email or mobile number, so the comparison always
--- goes through open_id space. Unresolved entries fail closed: they never
--- grant admin rights.
--- @param open_id string|nil
--- @return boolean
function M.is_admin(open_id)
  if not open_id then
    return false
  end

  for _, configured in ipairs(acl_config().admins or {}) do
    if to_open_id(configured) == open_id then
      return true
    end
  end
  return false
end

--- May this open_id talk to the bot in a 1:1 chat?
---
--- p2p needs its own policy, separate from `acl.mode`: `allow_all` is a
--- statement about the bound group, and reusing it here would let anyone in
--- the tenant open a DM with the bot. So p2p is **deny by default**:
---
---   1. `integrations.lark.p2p.allow` when set (open_id / email / mobile)
---   2. otherwise `acl.admins` ∪ `acl.whitelist` ∪ runtime whitelist
---   3. nothing matches → refused
---
--- @param open_id string|nil
--- @return boolean
function M.is_p2p_allowed(open_id)
  if not open_id then
    return false
  end

  local allow = p2p_config().allow
  if type(allow) == 'table' and #allow > 0 then
    for _, entry in ipairs(allow) do
      if to_open_id(entry) == open_id then
        return true
      end
    end
    -- An explicit list is the whole policy: no silent fallback, otherwise a
    -- typo in one entry would quietly widen access to every admin.
    return false
  end

  if M.is_admin(open_id) then
    return true
  end

  for _, entry in ipairs(acl_config().whitelist or {}) do
    if to_open_id(entry) == open_id then
      return true
    end
  end

  return state.acl.whitelist[open_id] == true
end

--- The p2p container that already belongs to an open_id, if any.
--- @param open_id string
--- @return string|nil chat_id
local function p2p_container_of(open_id)
  local found
  for chat_id, ctr in pairs(state.containers) do
    if ctr.chat_type == 'p2p' and ctr.peer == open_id then
      found = chat_id
      break
    end
  end
  return found
end

--- open_ids that should get a p2p container without being asked.
---
--- Deliberately narrower than `is_p2p_allowed()`: only the *curated* set is
--- provisioned, because provisioning opens a conversation and sends a
--- greeting.
---
---   1. `p2p.allow` when set — the admin named exactly these users
---   2. otherwise `acl.admins` — small and intentional
---
--- The wider fallback of `is_p2p_allowed()` (`acl.whitelist`) is **not**
--- provisioned on purpose: greeting a whole whitelist on connect would be
--- spam, and those users can still open the chat themselves.
---
--- Email / mobile entries are resolved through the identity cache, so an
--- unresolved entry is simply absent (fail closed, same as the access check).
--- @return string[]
function M.get_p2p_provision_list()
  local seen, out = {}, {}

  local function add(entry)
    local open_id = to_open_id(entry)
    if not open_id or seen[open_id] then
      return
    end
    seen[open_id] = true
    table.insert(out, open_id)
  end

  local allow = p2p_config().allow
  if type(allow) == 'table' and #allow > 0 then
    for _, entry in ipairs(allow) do
      add(entry)
    end
  else
    for _, entry in ipairs(acl_config().admins or {}) do
      add(entry)
    end
  end

  table.sort(out)
  return out
end

--- Durable session id owned by a container.
---
--- Derived from the chat id so the same conversation keeps the same session
--- even when the state file is lost. `sessions.new_with_id()` is idempotent:
--- an existing session is reused, never overwritten.
--- @param chat_id string
--- @return string
local function container_session_id(chat_id)
  return 'lark-' .. chat_id
end

--- Whether a binding's session no longer exists.
---
--- A binding can outlive its session: deleting a session removes it from
--- storage, and `on_session_deleted` clears the bindings the shared layer can
--- see -- but a state file written before that, or a session deleted while
--- this integration was disconnected, still points at an id that no longer
--- exists. Returning it means answering into a dead session: the reply is
--- written and never delivered, and the chat looks silently broken.
---
--- Only ids this integration derives (`lark-…`) qualify. A binding set by
--- hand to an unrelated session belongs to the user, not to this module.
--- @param session string|nil
--- @return boolean
local function session_is_stale(session)
  if type(session) ~= 'string' or session == '' then
    return false
  end
  if session:sub(1, 5) ~= 'lark-' then
    return false
  end
  if require('chat.sessions').exists(session) then
    return false
  end
  -- `exists()` only answers from the in-memory cache; a session written by a
  -- previous run is still legitimate until it is loaded.
  local cache_file = require('chat.sessions.storage').cache_dir
    .. session
    .. '.json'
  return vim.uv.fs_stat(cache_file) == nil
end

--- Drop a container binding whose session is gone.
--- @param ctr table
local function drop_stale_binding(ctr)
  local session = ctr and ctr.session
  if not session or not session_is_stale(session) then
    return
  end
  ctr.session = nil
  save_state()
  log.warn('[Lark] Dropped stale binding: ' .. session)
end

--- Make sure a container owns a session.
---
--- The main container keeps using the platform session (`state.session`), so
--- `current_session()` / `set_session()` and everything built on them keep
--- their meaning. Every other container must own one instead: the shared
--- layer resolves a message's session through `get_binding()`, and an unbound
--- container falls back to `current_session()` — a p2p message would then be
--- answered inside the group's session, and the reply would be delivered to
--- the configured group instead of the peer.
--- @param chat_id string
--- @param ctr table
--- @return string|nil
local function ensure_container_session(chat_id, ctr)
  drop_stale_binding(ctr)
  if ctr.session then
    return ctr.session
  end
  if chat_id == main_chat_id() then
    return state.session
  end

  local id = require('chat.sessions').new_with_id(container_session_id(chat_id))
  if not id then
    log.error('[Lark] Failed to create a session for ' .. chat_id)
    return nil
  end

  ctr.session = id
  save_state()
  log.info('[Lark] Bound session ' .. id .. ' to ' .. chat_id)
  return id
end

--- Session a chat should talk in, falling back to the platform session.
---
--- Binding happens here (on read) rather than while messages are being
--- processed: a reply for a chat that never owned a session is impossible to
--- route afterwards, so the binding must not depend on how far
--- `handle_messages` got before a filter dropped the message.
--- @param chat_id string|nil
--- @return string|nil
local function chat_session(chat_id)
  if not chat_id then
    return state.session
  end
  local ctr = state.containers[chat_id]
  if ctr then
    return ensure_container_session(chat_id, ctr)
  end
  if chat_id == main_chat_id() then
    return state.session
  end
  return nil
end

--- Grant access: add to the runtime whitelist, drop from the blacklist.
--- @param open_id string
--- @return boolean true when the ACL actually changed
function M.acl_allow(open_id)
  if not open_id then
    return false
  end

  local changed = false
  if state.acl.blacklist[open_id] then
    state.acl.blacklist[open_id] = nil
    changed = true
  end
  if not state.acl.whitelist[open_id] then
    state.acl.whitelist[open_id] = true
    changed = true
  end

  if changed then
    save_state()
    log.info('[Lark] ACL allow: ' .. open_id)
  end
  return changed
end

--- Revoke access: add to the runtime blacklist, drop from the whitelist.
--- @param open_id string
--- @return boolean true when the ACL actually changed
function M.acl_deny(open_id)
  if not open_id then
    return false
  end

  local changed = false
  if state.acl.whitelist[open_id] then
    state.acl.whitelist[open_id] = nil
    changed = true
  end
  if not state.acl.blacklist[open_id] then
    state.acl.blacklist[open_id] = true
    changed = true
  end

  if changed then
    save_state()
    log.info('[Lark] ACL deny: ' .. open_id)
  end
  return changed
end

--- Human readable ACL summary, used by the in-chat `/acl` command.
--- @return string
function M.acl_status()
  local acl = M.get_acl()
  local function fmt(list)
    if #list == 0 then
      return '-'
    end
    return table.concat(list, ', ')
  end

  return table.concat({
    'ACL mode: ' .. acl.mode,
    'Admins: ' .. fmt(acl.admins),
    string.format('Whitelist (%d): %s', #acl.whitelist, fmt(acl.whitelist)),
    string.format('Blacklist (%d): %s', #acl.blacklist, fmt(acl.blacklist)),
    'Commands: /allow @user, /deny @user, /acl',
  }, '\n')
end

--- Recently seen speakers, newest first. Backs a future picker so open_ids
--- can be picked instead of copied from the open platform console.
--- @return table[] { id = string, name = string|nil, last_seen = number }
function M.get_recent_senders()
  local list = {}
  for id, info in pairs(state.recent_senders) do
    table.insert(list, {
      id = id,
      name = info.name,
      last_seen = info.last_seen or 0,
    })
  end
  table.sort(list, function(a, b)
    return a.last_seen > b.last_seen
  end)
  return list
end

--- Cache a speaker's open_id in the state file, pruning the oldest entries.
--- @param msg table raw Lark message
local function record_sender(msg)
  local sender = msg.sender
  if not sender or not sender.id then
    return
  end
  -- Bot/app messages are not speakers worth granting access to.
  if sender.sender_type and sender.sender_type ~= 'user' then
    return
  end

  local previous = state.recent_senders[sender.id]
  state.recent_senders[sender.id] = {
    last_seen = tonumber(msg.create_time) or (os.time() * 1000),
    name = sender.name or (previous and previous.name),
  }

  local count = 0
  for _ in pairs(state.recent_senders) do
    count = count + 1
  end
  if count <= MAX_RECENT_SENDERS then
    return
  end

  local entries = {}
  for id, info in pairs(state.recent_senders) do
    table.insert(entries, { id = id, last_seen = info.last_seen or 0 })
  end
  table.sort(entries, function(a, b)
    return a.last_seen > b.last_seen
  end)
  for i = MAX_RECENT_SENDERS + 1, #entries do
    state.recent_senders[entries[i].id] = nil
  end
end

--- Strip the leading mention keys (`@_user_1 ...`) Lark puts in front of the
--- real text, so `@bot /allow @user` reduces to `/allow @user`.
--- @param text string
--- @return string
local function strip_leading_mentions(text)
  local rest = text or ''
  -- Mention keys look like `@_user_1`: `%w` alone stops at the underscore,
  -- so the character class has to include it explicitly.
  while true do
    local prefix = rest:match('^%s*@_[%w_]+%s*')
    if not prefix then
      break
    end
    rest = rest:sub(#prefix + 1)
  end
  return (rest:gsub('^%s+', ''))
end

--- Parse an ACL management command out of a message body.
---
--- Lua patterns have no alternation (`|` is a literal), so each command is
--- probed with a plain prefix check instead of one combined pattern.
--- @param content string
--- @return table|nil { command = 'allow'|'deny'|'acl', arg = string }
local function parse_acl_command(content)
  local text = strip_leading_mentions(content)

  for _, command in ipairs({ 'allow', 'deny', 'acl' }) do
    local prefix = '/' .. command
    if text:sub(1, #prefix) == prefix then
      local rest = text:sub(#prefix + 1)
      -- `/allowed` must not be read as `/allow`: require a space or the end.
      if rest == '' or rest:match('^%s') then
        return {
          command = command,
          arg = (rest:gsub('^%s+', ''):gsub('%s+$', '')),
        }
      end
    end
  end

  return nil
end

--- Resolve a command argument to an open_id.
--- Accepts a mention key from the message text (`@_user_2`), a raw open_id,
--- or a raw union_id.
--- @param arg string
--- @param mentions table|nil the message's mentions array
--- @return string|nil
local function resolve_open_id(arg, mentions)
  local raw = (arg or ''):gsub('^@', ''):gsub('%s+$', '')
  if raw == '' then
    return nil
  end

  for _, mention in ipairs(mentions or {}) do
    if mention.key then
      local key = mention.key:gsub('^@', '')
      if key == raw then
        return mention.id
      end
    end
  end

  if raw:match('^ou_') or raw:match('^on_') then
    return raw
  end

  return nil
end

--- Execute an ACL management command. Non-admins are dropped silently: a
--- "permission denied" reply would only spam the group.
--- @param msg table raw Lark message
--- @param parsed table { command = ..., arg = ... }
--- @param chat_id string|nil container the command came from
local function handle_acl_command(msg, parsed, chat_id)
  local sender_id = msg.sender and msg.sender.id or nil

  --- ACL replies follow the chat the command came from: a `/allow` typed in
  --- a p2p chat must not be announced in the group. A nil session keeps the
  --- old single-channel behaviour (the configured chat).
  local function reply(text)
    M.send_message(text, chat_session(chat_id))
  end

  if not M.is_admin(sender_id) then
    log.warn(
      string.format(
        '[Lark] Ignore ACK command from non-admin: %s',
        sender_id or 'unknown'
      )
    )
    return
  end

  if parsed.command == 'acl' then
    reply(M.acl_status())
    return
  end

  local target = resolve_open_id(parsed.arg, msg.mentions)
  if not target then
    reply(
      'Usage: /allow @user or /deny @user (mention the user in the command)'
    )
    return
  end

  if target == state.bot_id then
    reply('Refusing to change ACL for the bot itself.')
    return
  end

  local changed
  if parsed.command == 'allow' then
    changed = M.acl_allow(target)
    if changed then
      -- A newly allowed user can DM the bot, but the poller only reads
      -- conversations whose `oc_` id it already knows. Opening that
      -- conversation here means there is something to poll before the
      -- user types anything (see provision_p2p).
      M.provision_p2p({ target })
    end
  else
    changed = M.acl_deny(target)
  end

  reply(
    string.format(
      '%s %s\n\n%s',
      parsed.command == 'allow' and 'Allowed:' or 'Denied:',
      target,
      changed and 'ACL updated.' or 'Already in that state.'
    )
  )
end

--------------------------------------------------
-- Token: delegated to chat.integrations.lark.auth (shared with the bitable tool)
--------------------------------------------------
local function ensure_token(callback)
  auth.ensure_token(callback)
end

--------------------------------------------------
-- Get bot info
--------------------------------------------------
--- Apply a decoded /bot/v3/info body to the state.
--- @param body string raw response body
--- @return boolean true when the identity was learned
local function apply_bot_info(body)
  if not body or body == '' then
    return false
  end

  local ok, result = pcall(json.decode, body)
  if not ok or type(result) ~= 'table' or type(result.bot) ~= 'table' then
    return false
  end

  local bot = result.bot
  if result.code and result.code ~= 0 then
    log.warn(
      '[Lark] /bot/v3/info returned code '
        .. tostring(result.code)
        .. ': '
        .. tostring(result.msg or 'no message')
    )
    return false
  end

  if type(bot.open_id) ~= 'string' or bot.open_id == '' then
    log.warn('[Lark] /bot/v3/info has no open_id')
    return false
  end

  local changed = state.bot_id ~= bot.open_id or state.bot_name ~= bot.app_name
  state.bot_id = bot.open_id
  -- `app_name` is the display name a mention carries when the open_id lookup
  -- is not usable yet; see is_mention_bot().
  state.bot_name = bot.app_name or bot.name or state.bot_name
  log.info('[Lark] Bot ID: ' .. state.bot_id .. ' (' .. tostring(state.bot_name) .. ')')

  -- Persist so the next session starts with a known identity instead of
  -- re-fetching (and, if the request fails, dropping every group message).
  if changed then
    save_state()
  end
  return true
end

--- Fetch the bot identity once.
---
--- Cheap (one GET) and therefore retried by the poll loop while it is still
--- unknown: until `state.bot_id` is set, group mentions can not be detected,
--- and silently dropping every group message is far worse than one extra
--- request per tick.
local function get_bot_info()
  -- Only one lookup in flight: the poll loop may call this on every tick.
  if state.bot_info_jobid then
    log.debug('[Lark] Skip bot info: request already in flight')
    return
  end

  ensure_token(function(token, err)
    -- auth.ensure_token passes (nil, err) when the token request fails;
    -- concatenating nil would crash inside the scheduled callback.
    if not token then
      log.error('[Lark] Skip bot info: ' .. (err or 'no tenant_access_token'))
      return
    end

    local cmd = curl.build_request({
      url = API_BASE .. '/bot/v3/info',
      method = 'GET',
      headers = {
        'Authorization: Bearer ' .. token,
      },
      compressed = true,
      -- Keep curl diagnostics: with plain `-s` a transport failure writes
      -- nothing anywhere and the reason is lost.
      show_error = true,
    })

    -- The body may arrive in several chunks; decoding a single chunk never
    -- works. Resolve as soon as a complete payload shows up, and fall back to
    -- the accumulated body on exit (same convention as chat/lark/auth.lua).
    local chunks = {}
    local done = false

    local function finish(code, signal)
      if done then
        return
      end
      done = true
      state.bot_info_jobid = nil

      local body = table.concat(chunks, '')
      if not apply_bot_info(body) then
        -- No identity yet: the next poll tick retries.
        log.warn(
          '[Lark] Bot info unavailable (curl exit code '
            .. tostring(code)
            .. ', signal '
            .. tostring(signal)
            .. '); group mentions stay undetectable until it succeeds'
        )
      end
    end

    local jobid = job.start(cmd, {
      raw = true,
      on_stdout = function(_, data)
        for _, chunk in ipairs(data) do
          chunks[#chunks + 1] = chunk
        end

        if done then
          return
        end

        local body = table.concat(chunks, '')
        local ok, result = pcall(json.decode, body)
        if ok and type(result) == 'table' and type(result.bot) == 'table' then
          done = true
          state.bot_info_jobid = nil
          apply_bot_info(body)
        end
      end,
      on_exit = function(_, code, signal)
        finish(code, signal)
      end,
    })

    -- A job that could not be spawned returns 0: neither callback would ever
    -- fire, so the in-flight flag must be cleared instead of blocking every
    -- later retry (0 is truthy in Lua).
    if not jobid or jobid <= 0 then
      log.warn('[Lark] Failed to start /bot/v3/info request; will retry')
      state.bot_info_jobid = nil
      return
    end

    state.bot_info_jobid = jobid
  end)
end

--------------------------------------------------
-- Check if message mentions bot
--------------------------------------------------

-- {
--   body = {
--     content = '{"text":"@_user_1 2"}'
--   },
--   chat_id = "oc_8270f8fe55cb85e92a15c1b6e357228b",
--   create_time = "1772994314949",
--   deleted = false,
--   mentions = { {
--       id = "ou_95904d939749487b272aaa73a91bb916",
--       id_type = "open_id",
--       key = "@_user_1",
--       name = "chat.nvim",
--       tenant_key = "1acdd6af5318d948"
--     } },
--   message_id = "om_x100b55efbe63a0a4ee6b8f2919d79a8",
--   msg_type = "text",
--   sender = {
--     id = "ou_543e6f73f6eba025fa7fc536d39204bb",
--     id_type = "open_id",
--     sender_type = "user",
--     tenant_key = "1acdd6af5318d948"
--   },
--   update_time = "1772994314988",
--   updated = true
-- }
local function is_mention_bot(msg, bot_id)
  if not msg or type(msg.mentions) ~= 'table' then
    return false
  end

  for _, m in ipairs(msg.mentions) do
    if type(m) ~= 'table' then
      goto continue
    end

    -- open_id is the only exact signal Lark gives us: it is resolved by the
    -- server, not typed by the sender.
    if bot_id and m.id == bot_id then
      return true
    end

    -- While /bot/v3/info has not answered (or failed), there is no open_id to
    -- compare against and the mention's display name is the only signal left.
    -- Used as a fallback only: a name match can not be forged by the sender,
    -- but it is weaker than an open_id, so it never overrides one.
    if not bot_id and state.bot_name and m.name == state.bot_name then
      log.debug('[Lark] Bot mentioned by name (identity still unknown)')
      return true
    end

    ::continue::
  end

  return false
end

--------------------------------------------------
-- Message handling (one container response)
--------------------------------------------------
--- Process the raw response of one container fetch.
---
--- Split out of the job callback so every early exit (empty body, API error,
--- decode failure) is a plain `return` instead of having to remember to
--- release the polling chain.
--- @param chat_id string container the response belongs to
--- @param response string raw response body
local function handle_messages(chat_id, response)
  if response == nil or response == '' then
    log.debug('[Lark] Empty response body (' .. chat_id .. ')')
    return
  end

  local ok, result = pcall(json.decode, response)
  if not ok then
    log.error('[Lark] JSON decode failed: ' .. response)
    return
  end

  if not result then
    log.error('[Lark] Empty response')
    return
  end

  -- Check for API errors
  if result.code and result.code ~= 0 then
    log.error(
      '[Lark] API error [' .. result.code .. ']: ' .. (result.msg or 'unknown')
    )
    return
  end

  -- Get messages from response
  local messages = {}
  if result.data and result.data.items then
    messages = result.data.items
  elseif result.items then
    messages = result.items
  else
    log.debug('[Lark] No messages in response')
    return
  end

  if #messages == 0 then
    return
  end

  local ctr = ensure_container(chat_id)
  local has_new = false
  local latest_time = container_cursor(chat_id) or '0'

  -- Process messages in chronological order (oldest first)
  for i = #messages, 1, -1 do
    local msg = messages[i]

    -- Skip already processed messages
    if state.processed_ids[msg.message_id] then
      goto continue
    end

    state.processed_ids[msg.message_id] = true
    has_new = true

    if msg.create_time then
      local create_time_ms = msg.create_time
      if not latest_time or create_time_ms > latest_time then
        latest_time = create_time_ms
      end
    end

    -- Skip bot messages (messages from this app itself)
    if msg.sender and msg.sender.sender_type == 'app' then
      goto continue
    end

    -- Cache the speaker before any filtering: the picker wants to list
    -- everyone who showed up in the chat, not only those allowed to talk.
    record_sender(msg)

    -- In a p2p chat there is nobody to @mention: the message is addressed to
    -- the bot by definition. Groups keep requiring the mention.
    local need_mention = ctr.chat_type ~= 'p2p'

    if need_mention and not is_mention_bot(msg, state.bot_id) then
      log.debug('[Lark] Skip message (not mention/reply): ' .. msg.message_id)
      goto continue
    end

    local content = msg.body and msg.body.content or ''
    if msg.msg_type == 'text' then
      local ok2, text_data = pcall(json.decode, content)
      if ok2 and text_data and text_data.text then
        content = text_data.text
      end
      -- Lark prefixes the real text with mention keys (`@_user_1`), so
      -- `@bot /list` arrives as `@_user_1 /list`. Strip the keys here,
      -- before the shared handler runs: its slash commands are anchored
      -- with `^/list`, and would never match otherwise. A p2p message has no
      -- keys and passes through unchanged.
      content = strip_leading_mentions(content)
    end

    if content == '' then
      goto continue
    end

    local sender_id = msg.sender and msg.sender.id or nil

    -- p2p has its own default-deny policy: `acl.mode = allow_all` would
    -- otherwise let anyone in the tenant open a DM with the bot.
    if ctr.chat_type == 'p2p' then
      local peer = ctr.peer or sender_id
      if not M.is_p2p_allowed(peer) then
        log.debug(
          '[Lark] Skip p2p message (peer not allowed): ' .. tostring(peer)
        )
        goto continue
      end
      -- The registered peer is the authoritative 1:1 identity; a message
      -- from somebody else inside that container is not trustworthy.
      if ctr.peer and sender_id and ctr.peer ~= sender_id then
        log.warn(
          '[Lark] p2p sender mismatch ('
            .. tostring(sender_id)
            .. ' != '
            .. ctr.peer
            .. '), ignoring message'
        )
        goto continue
      end
    end

    local sender_is_admin = M.is_admin(sender_id)

    -- ACL: admins always pass, so they can recover a whitelist that
    -- locked them out of management commands.
    if not sender_is_admin and not M.is_allowed(sender_id) then
      log.debug(
        '[Lark] Skip message (sender not allowed): ' .. (sender_id or '?')
      )
      goto continue
    end

    -- In-chat ACL management: must run before the shared handler so
    -- `/allow` never reaches the LLM as a normal prompt.
    local acl_command = parse_acl_command(content)
    if acl_command then
      handle_acl_command(msg, acl_command, chat_id)
      goto continue
    end

    -- Call callback with the message
    if state.callback then
      vim.schedule(function()
        state.callback({
          author = sender_id or 'Unknown',
          content = content,
          message_id = msg.message_id,
          -- Source fields: the shared layer routes the reply back to the
          -- chat the message came from. Pure additions, old integrations
          -- never see them.
          chat_id = chat_id,
          chat_type = ctr.chat_type or 'group',
        })
      end)
    end

    ::continue::
  end

  -- Save state if there are new messages
  if has_new then
    set_container_cursor(chat_id, latest_time)
    log.debug('[Lark] Updated cursor for ' .. chat_id .. ': ' .. latest_time)
    save_state()
  end
end

--------------------------------------------------
-- Fetch one container
--------------------------------------------------
--- Fetch the messages of a single container, then hand control back.
---
--- Group and p2p chats are addressed identically
--- (`container_id_type=chat&container_id=oc_...`); they differ only in which
--- cursor is used and whether an `@mention` is required (see handle_messages).
---
--- `done()` runs exactly once per call, whichever way the request settles, so
--- the polling tick can walk the container list without overlapping requests.
--- @param chat_id string
--- @param done fun()
local function fetch_container(chat_id, done)
  local cursor = container_cursor(chat_id)

  ensure_token(function(token, err)
    -- No token means no request: bail out instead of building 'Bearer .. nil'.
    if not token then
      log.error(
        '[Lark] Skip fetch ('
          .. chat_id
          .. '): '
          .. (err or 'no tenant_access_token')
      )
      done()
      return
    end

    local endpoint = API_BASE
      .. '/im/v1/messages?container_id_type=chat&container_id='
      .. chat_id
      .. '&sort_type=ByCreateTimeDesc'
      .. '&page_size=50'

    if cursor then
      -- Convert milliseconds to seconds (Lark API expects seconds)
      local start_time_seconds = math.floor(tonumber(cursor) / 1000)

      -- Ensure start_time is not in the future
      local current_time_seconds = os.time()
      if start_time_seconds > current_time_seconds then
        log.warn(
          '[Lark] start_time is in the future, resetting to current time'
        )
        start_time_seconds = current_time_seconds
      end

      endpoint = endpoint .. '&start_time=' .. start_time_seconds
    end

    -- The request settles on whichever comes first: the exit callback or the
    -- watchdog. `settled` makes `done()` fire once even when a timed-out job
    -- still reports its exit afterwards.
    local settled = false
    local timeout = uv.new_timer()
    local function settle()
      if settled then
        return
      end
      settled = true
      timeout:stop()
      if not timeout:is_closing() then
        timeout:close()
      end
      done()
    end

    timeout:start(5000, 0, function()
      log.warn('[Lark] Request timeout (' .. chat_id .. ')')
      settle()
    end)

    -- FIX: Accumulate response data
    local response_chunks = {}

    local cmd = curl.build_request({
      url = endpoint,
      method = 'GET',
      compressed = true,
      headers = {
        'Authorization: Bearer ' .. token,
      },
    })
    job.start(cmd, {
      raw = true,

      on_stdout = function(_, data)
        for _, chunk in ipairs(data) do
          table.insert(response_chunks, chunk)
        end
      end,
      on_exit = function()
        local ok, err2 =
          pcall(handle_messages, chat_id, table.concat(response_chunks))
        if not ok then
          log.error('[Lark] Message handling failed: ' .. tostring(err2))
        end
        settle()
      end,
    })
  end)
end

--------------------------------------------------
-- Poll tick: one request per container, strictly sequential
--------------------------------------------------
local function poll_tick()
  -- Identity first: without `state.bot_id` every group mention looks like
  -- "addressed to somebody else" and gets dropped. Retrying here keeps the
  -- cost at one cheap GET per tick until it succeeds.
  if not state.bot_id then
    get_bot_info()
  end

  if state.is_fetching then
    log.debug('[Lark] poll_tick: skipped (already fetching)')
    return
  end

  -- A state file from before the container abstraction has no entry yet: the
  -- configured main chat is then the only container, exactly as before.
  if vim.tbl_count(state.containers) == 0 then
    local main = main_chat_id()
    if not main then
      log.error('[Lark] chat_id not configured')
      return
    end
    ensure_container(main)
  end

  local ids = sorted_keys(state.containers)
  if #ids == 0 then
    return
  end

  state.is_fetching = true

  local index = 0
  local function next_container()
    index = index + 1
    if index > #ids then
      state.is_fetching = false
      return
    end
    -- Sequential on purpose: parallel requests would race on the rate limit
    -- and make the log unreadable.
    fetch_container(ids[index], next_container)
  end

  next_container()
end

--------------------------------------------------
-- Connect
--------------------------------------------------
function M.connect(callback)
  local lark_cfg = lark_config()
  if not lark_cfg.app_id or not lark_cfg.app_secret then
    log.error('[Lark] app_id or app_secret not configured')
    return
  end

  if not lark_cfg.chat_id then
    log.error('[Lark] chat_id not configured')
    return
  end

  if state.is_running then
    return
  end

  state.callback = callback
  state.is_running = true

  load_state()

  -- The cached cursors describe where the *previous* run stopped. Replaying
  -- them on start would fetch and answer everything sent while the plugin was
  -- down, so every container resumes from "now" instead.
  reset_cursors_to_now()
  save_state()

  local function start_polling()
    get_bot_info()
    log.info('[Lark] Starting polling...')

    state.timer = uv.new_timer()
    state.timer:start(
      0,
      state.poll_interval,
      vim.schedule_wrap(function()
        if state.is_running then
          poll_tick()
        end
      end)
    )

    log.info('[Lark] Polling started')

    -- Admins get their private chat opened without asking for it: a p2p
    -- container is only polled once its `oc_` id is known, and polling can
    -- never discover it. Runs after polling starts so the newly registered
    -- containers are picked up by the very next tick.
    M.provision_p2p()
  end

  -- Resolve email / mobile ACL entries before the first poll: until the map
  -- is settled those entries match nothing, so an email-configured admin
  -- would be locked out during the lookup window. open_id-only configs cost
  -- zero requests and this callback fires immediately.
  M.resolve_acl(function()
    if not state.is_running then
      -- disconnect() ran while the resolution was in flight.
      return
    end
    start_polling()
  end)
end

--------------------------------------------------
-- Disconnect
--------------------------------------------------
function M.disconnect()
  if state.timer then
    state.timer:stop()
    state.timer = nil
  end

  state.is_running = false
  state.is_fetching = false
  state.callback = nil
  save_state()
  log.info('[Lark] Polling stopped')
end

--------------------------------------------------
-- Send message
--------------------------------------------------
-- Queued chunks carry their own destination: two chats replying at the same
-- time must not leak chunks into each other.
local message_queue = {}
local send_message_jobid = -1

--- Delivery address for one container.
---
--- p2p replies go to the peer's open_id: an `oc_` id is only needed to *poll*
--- a conversation, while `receive_id_type=open_id` addresses the person
--- directly and survives container churn.
--- @param chat_id string|nil
--- @return table { id_type = string, receive_id = string|nil }
local function send_target(chat_id)
  local ctr = chat_id and state.containers[chat_id] or nil
  if ctr and ctr.chat_type == 'p2p' and ctr.peer then
    return { id_type = 'open_id', receive_id = ctr.peer }
  end
  return { id_type = 'chat_id', receive_id = chat_id }
end

local function dispatch_message()
  if send_message_jobid > 0 then
    return
  end

  local item = table.remove(message_queue, 1)
  if not item then
    return
  end

  local target = send_target(item.chat_id)
  if not target.receive_id then
    log.error('[Lark] Skip send: chat_id not configured')
    -- Without an address every chunk of this batch fails identically, so drop
    -- the queue instead of looping on it.
    message_queue = {}
    return
  end

  ensure_token(function(token, err)
    -- Token failure: no request is made. The queue has to be drained here,
    -- otherwise `send_message_jobid` stays -1 and every queued chunk below
    -- would wait for an on_exit that never fires.
    if not token then
      send_message_jobid = -1
      log.error('[Lark] Skip send: ' .. (err or 'no tenant_access_token'))
      dispatch_message()
      return
    end
    -- Use interactive card (schema 2.0) with markdown element,
    -- so markdown in AI replies is rendered by Lark clients.
    local body = json.encode({
      receive_id = target.receive_id,
      msg_type = 'interactive',
      content = json.encode({
        schema = '2.0',
        body = {
          elements = {
            {
              tag = 'markdown',
              content = item.content,
            },
          },
        },
      }),
    })
    local cmd = curl.build_request({
      url = API_BASE .. '/im/v1/messages?receive_id_type=' .. target.id_type,
      method = 'POST',
      headers = {
        'Authorization: Bearer ' .. token,
        'Content-Type: application/json',
      },
      stdin_body = true,
    })
    send_message_jobid = job.start(cmd, {
      on_stdout = function(_, data)
        for _, v in ipairs(data) do
          log.debug(v)
        end
      end,
      on_stderr = function(_, data)
        for _, v in ipairs(data) do
          log.debug(v)
        end
      end,
      on_exit = function()
        send_message_jobid = -1
        dispatch_message()
      end,
    })

    job.send(send_message_jobid, body)
    job.send(send_message_jobid, nil)
  end)
end

--- Send a reply.
---
--- The optional `session` is the second argument the shared layer passes once
--- an integration exposes bindings: replies then go back to the chat the
--- request came from. A single-argument call (all existing call sites, and the
--- in-chat `/status`, `/list` replies) addresses the main container.
--- @param content string
--- @param session? string
function M.send_message(content, session)
  local max_length = 30720 -- Lark message limit

  local chat_id = main_chat_id()
  if session then
    chat_id = session_to_chat(session) or chat_id
  end

  local chunks = chunker.chunk(content, max_length)
  for _, chunk in ipairs(chunks) do
    table.insert(message_queue, { content = chunk, chat_id = chat_id })
  end

  dispatch_message()
end

--------------------------------------------------
-- Session management (platform level: meaning unchanged)
--------------------------------------------------
function M.current_session()
  return state.session
end

--- Bind the platform session.
---
--- `current_session()` stays the single value that `unbridge`, the HTTP routes
--- and the window title rely on; the main container binding is kept in sync so
--- replies and per-chat lookups agree.
--- @param session string|nil
function M.set_session(session)
  state.session = session
  local main = main_chat_id()
  if main then
    local ctr = ensure_container(main)
    ctr.session = session
  end
  save_state()
end

--------------------------------------------------
-- Bindings (Phase 2 of ideas/lark-acl-bindings.md)
--------------------------------------------------
-- Optional methods: the shared layer calls them only when they exist, so the
-- other six integrations keep their exact current behaviour.

--- Session bound to a chat, creating one on first use.
---
--- The lookup is where the binding is established (see chat_session): the
--- shared layer asks this while resolving a message, so a chat that never
--- owned a session gets one before the reply is routed.
--- @param chat_id string|nil
--- @return string|nil
function M.get_binding(chat_id)
  if not chat_id then
    return nil
  end
  return chat_session(chat_id)
end

--- Bind one chat without touching the platform session.
--- Used by the in-chat `/session` command and by the Neovim picker.
--- @param chat_id string
--- @param session string|nil
--- @return boolean
function M.set_binding(chat_id, session)
  if not chat_id then
    return false
  end
  local ctr = ensure_container(chat_id)
  ctr.session = session
  if chat_id == main_chat_id() then
    state.session = session
  end
  save_state()
  return true
end

--- Every session reachable through a binding, main one included.
--- `on_response` matches against this list, so a reply for a per-chat binding
--- still finds its integration.
--- @return string[]
function M.get_bound_sessions()
  local list, seen = {}, {}
  local function add(session)
    -- A stale binding is not a live route: listing it would keep
    -- `on_response` writing replies into a session that no longer exists.
    if type(session) == 'string' and not seen[session] then
      if session_is_stale(session) then
        return
      end
      seen[session] = true
      table.insert(list, session)
    end
  end
  add(state.session)
  for _, ctr in pairs(state.containers) do
    add(ctr.session)
  end
  table.sort(list)
  return list
end

--- Chat ids whose binding points at a session.
---
--- Needed by `chat.bridge`: unbinding a session must clear the per-chat
--- bindings too, and that requires enumerating them.
--- @param session string|nil
--- @return string[]
function M.get_chat_bindings(session)
  local list = {}
  if not session or session_is_stale(session) then
    return list
  end
  if state.session == session and main_chat_id() then
    table.insert(list, main_chat_id())
  end
  for chat_id, ctr in pairs(state.containers) do
    if ctr.session == session and chat_id ~= main_chat_id() then
      table.insert(list, chat_id)
    end
  end
  table.sort(list)
  return list
end

--- Bridge capabilities consumed by `chat.bridge`.
---
--- Wiring only: the storage stays `state.session` + `containers[].session`,
--- this table just lets the shared layer ask the questions without knowing
--- which fields hold the answers.
M.bridge = {
  --- Platform-level session.
  session = function()
    return state.session
  end,

  --- Platform-level setter: keeps the main container in sync, unchanged.
  set_session = function(session)
    M.set_session(session)
  end,

  --- Session a chat talks in, creating one on first use.
  session_for_chat = function(chat_id)
    if not chat_id then
      return nil
    end
    return chat_session(chat_id)
  end,

  --- Bind one chat without touching the platform session.
  bind_chat = function(chat_id, session)
    if not chat_id then
      return false
    end
    return M.set_binding(chat_id, session)
  end,

  --- Chat ids bound to a session.
  chats = function(session)
    return M.get_chat_bindings(session)
  end,
}

--------------------------------------------------
-- Containers
--------------------------------------------------
--- All known containers, sorted by id for stable output (picker list).
--- @return table[] { chat_id, chat_type, peer, session, last_seen_time }
function M.get_containers()
  local list = {}
  for chat_id, ctr in pairs(state.containers) do
    table.insert(list, {
      chat_id = chat_id,
      chat_type = ctr.chat_type or 'group',
      peer = ctr.peer,
      session = ctr.session,
      last_seen_time = ctr.last_seen_time,
    })
  end
  table.sort(list, function(a, b)
    return a.chat_id < b.chat_id
  end)
  return list
end

--- Register a container so the poller starts reading it.
--- @param chat_id string
--- @param opts? table { chat_type = 'group'|'p2p', peer = string }
--- @return boolean
function M.add_container(chat_id, opts)
  if not chat_id then
    return false
  end
  ensure_container(chat_id, opts)
  save_state()
  return true
end

--- Open (or reuse) a 1:1 chat with an open_id.
---
--- A polling bot can not learn a p2p `oc_` id from an incoming message: it has
--- no cursor for a conversation it does not know about yet. So the conversation
--- is created from this side:
---
---   1. POST /im/v1/messages?receive_id_type=open_id  (a greeting)
---   2. GET  /im/v1/messages/{message_id}            → `chat_id`
---   3. register that chat_id as a p2p container
---
--- Step 1 doubles as the greeting the user sees, so nothing is sent twice. The
--- bot's own `sender_type == 'app'` greeting is skipped by the poll loop, so no
--- self-reply loop can start either.
--- @param open_id string
--- @param callback? fun(ok: boolean, result: string)
function M.create_p2p(open_id, callback)
  callback = callback or function() end

  if type(open_id) ~= 'string' or open_id == '' then
    callback(false, 'open_id is required')
    return
  end

  if not M.is_p2p_allowed(open_id) then
    callback(false, 'open_id is not allowed to use private chat')
    return
  end

  for chat_id, ctr in pairs(state.containers) do
    if ctr.chat_type == 'p2p' and ctr.peer == open_id then
      callback(true, chat_id)
      return
    end
  end

  local greeting = p2p_config().greeting
    or 'Hi, this is the chat.nvim bot. Reply here to talk to Neovim.'

  ensure_token(function(token, err)
    if not token then
      callback(false, err or 'no tenant_access_token')
      return
    end

    local body = json.encode({
      receive_id = open_id,
      msg_type = 'text',
      content = json.encode({ text = greeting }),
    })
    local send_cmd = curl.build_request({
      url = API_BASE .. '/im/v1/messages?receive_id_type=open_id',
      method = 'POST',
      headers = {
        'Authorization: Bearer ' .. token,
        'Content-Type: application/json',
      },
      stdin_body = true,
    })

    local chunks = {}
    local send_jobid = job.start(send_cmd, {
      on_stdout = function(_, data)
        for _, chunk in ipairs(data) do
          table.insert(chunks, chunk)
        end
      end,
      on_exit = function()
        local ok, result = pcall(json.decode, table.concat(chunks))
        if not ok or (result.code and result.code ~= 0) then
          callback(false, 'send failed: ' .. (ok and result.msg or 'bad json'))
          return
        end
        local message_id = result.data and result.data.message_id
        if not message_id then
          callback(false, 'message_id missing from the response')
          return
        end

        -- Read the created message back: its chat_id is the p2p container.
        local reveal_cmd = curl.build_request({
          url = API_BASE .. '/im/v1/messages/' .. message_id,
          method = 'GET',
          headers = { 'Authorization: Bearer ' .. token },
        })
        local reveal_chunks = {}
        job.start(reveal_cmd, {
          on_stdout = function(_, data)
            for _, chunk in ipairs(data) do
              table.insert(reveal_chunks, chunk)
            end
          end,
          on_exit = function()
            local ok2, res2 = pcall(json.decode, table.concat(reveal_chunks))
            if not ok2 or (res2.code and res2.code ~= 0) then
              callback(false, 'lookup failed: ' .. (ok2 and res2.msg or 'bad json'))
              return
            end
            local item = res2.data and res2.data.items and res2.data.items[1]
            local chat_id = item and item.chat_id
            if not chat_id then
              callback(false, 'chat_id missing from the message detail')
              return
            end
            ensure_container(chat_id, { chat_type = 'p2p', peer = open_id })
            save_state()
            log.info('[Lark] p2p chat ready: ' .. chat_id)
            callback(true, chat_id)
          end,
        })
      end,
    })

    job.send(send_jobid, body)
    job.send(send_jobid, nil)
  end)
end

--- Make sure every curated open_id owns a p2p container.
---
--- A p2p conversation is only polled once its `oc_` id is registered, and a
--- polling bot can not learn that id from an incoming message. So the chats
--- are opened proactively: an admin listed in `p2p.allow` (or, without that
--- list, `acl.admins`) gets a container on connect without lifting a finger.
---
--- Cheap and idempotent: a known container is a pure table lookup, and
--- `create_p2p` answers synchronously for it (no greeting is re-sent). Every
--- provisioned container also gets its own session immediately, so
--- `/session` style commands work before the first message arrives.
---
--- `p2p.auto_create = false` turns the whole thing off.
--- @param open_ids? string[] Defaults to `get_p2p_provision_list()`
--- @param callback? fun() Called once the list has been walked
function M.provision_p2p(open_ids, callback)
  callback = callback or function() end

  if p2p_config().auto_create == false then
    callback()
    return
  end

  if not state.is_running then
    -- Nothing to provision for: the poller is not reading anything, and
    -- `connect()` provisions on its own.
    callback()
    return
  end

  local list = open_ids or M.get_p2p_provision_list()
  if type(list) == 'string' then
    list = { list }
  end

  local index = 0
  local function next_open_id()
    index = index + 1
    if index > #list then
      callback()
      return
    end

    local open_id = list[index]
    if type(open_id) ~= 'string' or open_id == '' then
      next_open_id()
      return
    end

    -- Known peer: create_p2p would answer synchronously anyway, but a table
    -- lookup keeps the log free of a "already known" entry per connect.
    if p2p_container_of(open_id) then
      next_open_id()
      return
    end

    M.create_p2p(open_id, function(ok, result)
      if ok then
        local ctr = state.containers[result]
        if ctr then
          -- Bind the session now: a container that arrives with history but
          -- no session would otherwise borrow the platform session.
          ensure_container_session(result, ctr)
        end
        log.info(
          '[Lark] Provisioned p2p chat for ' .. open_id .. ': ' .. tostring(result)
        )
      else
        -- debug, not error: a user who never talked to the bot, or a missing
        -- `im:message:send_as_bot` scope, is a normal outcome and the next
        -- connect retries it.
        log.debug(
          '[Lark] p2p provisioning skipped ('
            .. open_id
            .. '): '
            .. tostring(result)
        )
      end
      next_open_id()
    end)
  end

  next_open_id()
end

--------------------------------------------------
-- Cleanup
--------------------------------------------------
function M.cleanup()
  M.disconnect()
end

return M

