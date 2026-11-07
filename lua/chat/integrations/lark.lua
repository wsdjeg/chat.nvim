local M = {}

local config = require('chat.config')
local log = require('chat.log')
local job = require('job')
local curl = require('chat.curl')
local auth = require('chat.lark.auth')
local identity = require('chat.lark.identity')
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
  bot_id = nil,
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

--------------------------------------------------
-- Save state to file
--------------------------------------------------
local function save_state()
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

  log.debug('[Lark] State loaded')
  return true
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
-- once at connect time (see chat.lark.identity) and cached in
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
--- chat.lark.identity).
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
local function handle_acl_command(msg, parsed)
  local sender_id = msg.sender and msg.sender.id or nil

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
    M.send_message(M.acl_status())
    return
  end

  local target = resolve_open_id(parsed.arg, msg.mentions)
  if not target then
    M.send_message(
      'Usage: /allow @user or /deny @user (mention the user in the command)'
    )
    return
  end

  if target == state.bot_id then
    M.send_message('Refusing to change ACL for the bot itself.')
    return
  end

  local changed
  if parsed.command == 'allow' then
    changed = M.acl_allow(target)
  else
    changed = M.acl_deny(target)
  end

  M.send_message(
    string.format(
      '%s %s\n\n%s',
      parsed.command == 'allow' and 'Allowed:' or 'Denied:',
      target,
      changed and 'ACL updated.' or 'Already in that state.'
    )
  )
end

--------------------------------------------------
-- Token: delegated to chat.lark.auth (shared with the bitable tool)
--------------------------------------------------
local function ensure_token(callback)
  auth.ensure_token(callback)
end

--------------------------------------------------
-- Get bot info
--------------------------------------------------
local function get_bot_info()
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
    })
    job.start(cmd, {
      on_stdout = function(_, lines)
        local output = table.concat(lines, '\n')
        if output and output ~= '' then
          local ok, result = pcall(json.decode, output)
          if ok and result and result.bot then
            state.bot_id = result.bot.open_id
            log.info('[Lark] Bot ID: ' .. state.bot_id)
          end
        end
      end,
    })
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
  if not bot_id or not msg then
    return false
  end

  local mentions = msg.mentions
  if not mentions then
    return false
  end

  for _, m in ipairs(mentions) do
    if m.id == bot_id then
      return true
    end
  end

  return false
end

--------------------------------------------------
-- Fetch messages (FIXED)
--------------------------------------------------
local function fetch_messages()
  -- log.debug('[Lark] fetch_messages: called')

  if state.is_fetching then
    log.debug('[Lark] fetch_messages: skipped (already fetching)')
    return
  end

  local chat_id = config.config.integrations
    and config.config.integrations.lark
    and config.config.integrations.lark.chat_id

  if not chat_id then
    log.error('[Lark] chat_id not configured')
    return
  end

  state.is_fetching = true
  -- log.debug('[Lark] fetch_messages: starting request')

  ensure_token(function(token, err)
    -- No token means no request: bail out instead of building 'Bearer .. nil'.
    if not token then
      state.is_fetching = false
      log.error('[Lark] Skip fetch: ' .. (err or 'no tenant_access_token'))
      return
    end
    -- Updated endpoint with container_id_type and container_id
    local endpoint = API_BASE
      .. '/im/v1/messages?container_id_type=chat&container_id='
      .. chat_id
      .. '&sort_type=ByCreateTimeDesc'
      .. '&page_size=50'

    if state.last_message_time then
      -- Convert milliseconds to seconds (Lark API expects seconds)
      local start_time_seconds =
        math.floor(tonumber(state.last_message_time) / 1000)

      -- Ensure start_time is not in the future
      local current_time_seconds = os.time()
      if start_time_seconds > current_time_seconds then
        log.warn(
          '[Lark] start_time is in the future, resetting to current time'
        )
        start_time_seconds = current_time_seconds
      end

      endpoint = endpoint .. '&start_time=' .. start_time_seconds
      -- log.debug('[Lark] Fetching messages after: ' .. start_time_seconds)
    end

    local timeout = uv.new_timer()
    timeout:start(5000, 0, function()
      if state.is_fetching then
        log.warn('[Lark] Request timeout')
        state.is_fetching = false
      end
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
        timeout:stop()
        if not timeout:is_closing() then
          timeout:close()
        end
        state.is_fetching = false
        local response = table.concat(response_chunks)
        if response == {} then
          log.debug('[Lark] fetch_messages: empty response chunks')
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
            '[Lark] API error ['
              .. result.code
              .. ']: '
              .. (result.msg or 'unknown')
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

        local has_new = false
        local latest_time = state.last_message_time or '0'

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
              -- log.debug('[Lark] Updated latest_time to: ' .. latest_time)
            end
          end

          -- Skip bot messages (messages from this app itself)
          if msg.sender and msg.sender.sender_type == 'app' then
            goto continue
          end

          -- Cache the speaker before any filtering: the picker wants to list
          -- everyone who showed up in the chat, not only those allowed to talk.
          record_sender(msg)

          -- Check if should respond
          local is_mention = is_mention_bot(msg, state.bot_id)

          -- Only respond if mentioned or replied
          if not is_mention then
            log.debug(
              -- '[Lark] Skip message (not mention):\n' .. vim.inspect(msg)
              '[Lark] Skip message (not mention/reply): ' .. msg.message_id
            )
            goto continue
          end

          local content = msg.body and msg.body.content or ''
          if msg.msg_type == 'text' then
            local ok2, text_data = pcall(json.decode, content)
            if ok2 and text_data and text_data.text then
              content = text_data.text
            end
          end

          if content == '' then
            goto continue
          end

          local sender_id = msg.sender and msg.sender.id or nil
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
            handle_acl_command(msg, acl_command)
            goto continue
          end

          -- Call callback with the message
          if state.callback then
            vim.schedule(function()
              state.callback({
                author = msg.sender and msg.sender.id or 'Unknown',
                content = content,
                message_id = msg.message_id,
              })
            end)
          end

          ::continue::
        end

        -- Save state if there are new messages
        if has_new then
          state.last_message_time = latest_time
          log.debug('[Lark] Updated last_message_time to: ' .. latest_time)
          save_state()
        end
      end,
    })
  end)
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

  local function start_polling()
    get_bot_info()
    log.info('[Lark] Starting polling...')

    state.timer = uv.new_timer()
    state.timer:start(
      0,
      state.poll_interval,
      vim.schedule_wrap(function()
        if state.is_running then
          fetch_messages()
        end
      end)
    )

    log.info('[Lark] Polling started')
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
local message_queue = {}
local send_message_jobid = -1

local function send_message(content)
  local chat_id = config.config.integrations
    and config.config.integrations.lark
    and config.config.integrations.lark.chat_id

  if not chat_id then
    log.error('[Lark] chat_id not configured')
    return
  end

  if send_message_jobid > 0 then
    return
  end

  ensure_token(function(token, err)
    -- Token failure: no request is made. The queue has to be drained here,
    -- otherwise `send_message_jobid` stays -1 and every queued chunk below
    -- would wait for an on_exit that never fires.
    if not token then
      send_message_jobid = -1
      log.error('[Lark] Skip send: ' .. (err or 'no tenant_access_token'))
      if #message_queue > 0 then
        send_message(table.remove(message_queue, 1))
      end
      return
    end
    -- Use interactive card (schema 2.0) with markdown element,
    -- so markdown in AI replies is rendered by Lark clients.
    local body = json.encode({
      receive_id = chat_id,
      msg_type = 'interactive',
      content = json.encode({
        schema = '2.0',
        body = {
          elements = {
            {
              tag = 'markdown',
              content = content,
            },
          },
        },
      }),
    })
    local cmd = curl.build_request({
      url = API_BASE .. '/im/v1/messages?receive_id_type=chat_id',
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
        if #message_queue > 0 then
          send_message(table.remove(message_queue, 1))
        end
      end,
    })

    job.send(send_message_jobid, body)
    job.send(send_message_jobid, nil)
  end)
end

function M.send_message(content)
  local max_length = 30720 -- Lark message limit

  local chunks = chunker.chunk(content, max_length)
  for _, chunk in ipairs(chunks) do
    table.insert(message_queue, chunk)
  end

  if #message_queue > 0 then
    send_message(table.remove(message_queue, 1))
  end
end

--------------------------------------------------
-- Session management
--------------------------------------------------
function M.current_session()
  return state.session
end

function M.set_session(session)
  state.session = session
  save_state()
end

--------------------------------------------------
-- Cleanup
--------------------------------------------------
function M.cleanup()
  M.disconnect()
end

return M

