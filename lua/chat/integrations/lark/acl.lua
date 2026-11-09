-- lua/chat/integrations/lark/acl.lua
-- Access control (Phase 1 of ideas/lark-acl-bindings.md) plus the in-chat
-- `/allow`, `/deny`, `/acl` commands.
--
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
local log = require('chat.log')
local identity = require('chat.integrations.lark.identity')
local util = require('chat.integrations.lark.util')

local M = {}

--- @param ctx table shared instance context
--- @return table acl API
function M.new(ctx)
  local state = ctx.state

  local function save_state()
    return ctx.save_state()
  end

  local function acl_config()
    return util.acl_config()
  end

  local function p2p_config()
    return util.p2p_config()
  end

  --------------------------------------------------
  -- Identity helpers
  --------------------------------------------------

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

  --- Map of resolved ACL identities (`'nova@example.com' -> 'ou_xxx'`).
  --- @return table
  local function get_identities()
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
  local function resolve_acl(callback)
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
  local function acl_mode()
    return acl_config().mode or 'allow_all'
  end

  --- Full effective ACL: config lists merged with runtime grants/denies.
  --- @return table { mode = string, admins = string[], whitelist = string[], blacklist = string[] }
  local function get_acl()
    local cfg = acl_config()
    return {
      mode = acl_mode(),
      admins = cfg.admins or {},
      whitelist = util.merge_ids(cfg.whitelist, state.acl.whitelist),
      blacklist = util.merge_ids(cfg.blacklist, state.acl.blacklist),
    }
  end

  --- Is this open_id one of the configured admins?
  ---
  --- `admins` accepts open_id, email or mobile number, so the comparison always
  --- goes through open_id space. Unresolved entries fail closed: they never
  --- grant admin rights.
  --- @param open_id string|nil
  --- @return boolean
  local function is_admin(open_id)
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
  local function is_allowed(open_id)
    if not open_id then
      return false
    end

    if is_admin(open_id) then
      return true
    end

    if state.acl.blacklist[open_id] then
      return false
    end
    if state.acl.whitelist[open_id] then
      return true
    end

    local mode = acl_mode()
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
  local function is_p2p_allowed(open_id)
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

    if is_admin(open_id) then
      return true
    end

    for _, entry in ipairs(acl_config().whitelist or {}) do
      if to_open_id(entry) == open_id then
        return true
      end
    end

    return state.acl.whitelist[open_id] == true
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
  local function get_p2p_provision_list()
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

  --------------------------------------------------
  -- Runtime grants / denies
  --------------------------------------------------

  --- Grant access: add to the runtime whitelist, drop from the blacklist.
  --- @param open_id string
  --- @return boolean true when the ACL actually changed
  local function acl_allow(open_id)
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
  local function acl_deny(open_id)
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
  local function acl_status()
    local acl = get_acl()
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
      string.format(
        'Blacklist (%d): %s',
        #acl.blacklist,
        fmt(acl.blacklist)
      ),
      'Commands: /allow @user, /deny @user, /acl',
    }, '\n')
  end

  --------------------------------------------------
  -- Recent senders
  --------------------------------------------------

  --- Recently seen speakers, newest first. Backs a future picker so open_ids
  --- can be picked instead of copied from the open platform console.
  --- @return table[] { id = string, name = string|nil, last_seen = number }
  local function get_recent_senders()
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
    if count <= util.MAX_RECENT_SENDERS then
      return
    end

    local entries = {}
    for id, info in pairs(state.recent_senders) do
      table.insert(entries, { id = id, last_seen = info.last_seen or 0 })
    end
    table.sort(entries, function(a, b)
      return a.last_seen > b.last_seen
    end)
    for i = util.MAX_RECENT_SENDERS + 1, #entries do
      state.recent_senders[entries[i].id] = nil
    end
  end

  --------------------------------------------------
  -- Message text helpers (shared with poll.lua)
  --------------------------------------------------

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
      ctx.M.send_message(text, ctx.container.chat_session(chat_id))
    end

    if not is_admin(sender_id) then
      log.warn(
        string.format(
          '[Lark] Ignore ACK command from non-admin: %s',
          sender_id or 'unknown'
        )
      )
      return
    end

    if parsed.command == 'acl' then
      reply(acl_status())
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
      changed = acl_allow(target)
      if changed then
        -- A newly allowed user can DM the bot, but the poller only reads
        -- conversations whose `oc_` id it already knows. Opening that
        -- conversation here means there is something to poll before the
        -- user types anything (see provision_p2p).
        ctx.M.provision_p2p({ target })
      end
    else
      changed = acl_deny(target)
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

  return {
    to_open_id = to_open_id,
    get_identities = get_identities,
    resolve_acl = resolve_acl,
    acl_mode = acl_mode,
    get_acl = get_acl,
    is_allowed = is_allowed,
    is_admin = is_admin,
    is_p2p_allowed = is_p2p_allowed,
    get_p2p_provision_list = get_p2p_provision_list,
    acl_allow = acl_allow,
    acl_deny = acl_deny,
    acl_status = acl_status,
    get_recent_senders = get_recent_senders,
    record_sender = record_sender,
    strip_leading_mentions = strip_leading_mentions,
    parse_acl_command = parse_acl_command,
    resolve_open_id = resolve_open_id,
    handle_acl_command = handle_acl_command,
  }
end

return M

