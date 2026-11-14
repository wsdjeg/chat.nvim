-- lua/chat/integrations/telegram/acl.lua
-- Access control plus the in-chat `/allow`, `/deny` and `/acl` commands.
--
-- Three modes, same vocabulary as the other integrations:
--   allow_all  (default) - anyone in the chat may talk to the bot
--   whitelist            - only listed user ids
--   blacklist            - everyone except listed user ids
--
-- Identity story, and where it differs from Lark: Telegram's `from.id` is a
-- stable integer and is what the Bot API hands us on every message, so there is
-- no lookup step -- nothing has to be resolved at connect time. A `@username`
-- is accepted in config as a convenience, but it is NOT authoritative: usernames
-- are user-chosen and can be changed or squatted, so a username match is only
-- used as a fallback and never for p2p admission. Numeric ids always win.
local log = require('chat.log')
local util = require('chat.integrations.telegram.util')

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
  -- Entry matching
  --------------------------------------------------

  --- Lowercased username without the leading `@`, or nil.
  --- @param value string|nil
  --- @return string|nil
  local function username_of(value)
    if type(value) ~= 'string' then
      return nil
    end
    return (value:gsub('^@', ''):lower())
  end

  --- Does one configured entry match a sender?
  ---
  --- A numeric entry is compared against `sender.id` and is authoritative. An
  --- `@username` entry is only consulted when the sender's numeric id did not
  --- match anything: it is a config convenience, not an identity proof.
  --- @param entry string|number
  --- @param sender table { id = string|nil, username = string|nil }
  --- @return boolean
  local function entry_matches(entry, sender)
    if not sender then
      return false
    end

    local key = util.id_to_string(entry)
    if not key then
      return false
    end

    if key:match('^@') or key:match('^[%a_]+$') then
      local wanted = username_of(key)
      local actual = username_of(sender.username)
      return wanted ~= nil and wanted == actual
    end

    return sender.id ~= nil and sender.id == key
  end

  --- Does any entry of a config list match the sender?
  --- @param list string[]|number[]|nil
  --- @param sender table
  --- @return boolean
  local function list_matches(list, sender)
    for _, entry in ipairs(list or {}) do
      if entry_matches(entry, sender) then
        return true
      end
    end
    return false
  end

  --------------------------------------------------
  -- Effective ACL
  --------------------------------------------------

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
      admins = vim.tbl_map(tostring, cfg.admins or {}),
      whitelist = util.merge_ids(cfg.whitelist, state.acl.whitelist),
      blacklist = util.merge_ids(cfg.blacklist, state.acl.blacklist),
    }
  end

  --- Is this sender one of the configured admins?
  --- @param sender table|string|nil { id, username } or a bare user id
  --- @return boolean
  local function is_admin(sender)
    local who = sender
    if type(sender) ~= 'table' then
      who = { id = util.id_to_string(sender) }
    end
    if not who or not who.id then
      return false
    end
    return list_matches(acl_config().admins, who)
  end

  --- Is this sender allowed to talk to the bot?
  ---
  --- Admins always pass, so they can still recover a whitelist that locked
  --- them out of the management commands.
  ---
  --- Runtime entries (issued from the chat, persisted in the state file) win
  --- over the configured mode: an admin can `/deny` (or `/allow`) a user even
  --- while the mode is `allow_all`.
  --- @param sender table|string|nil { id, username } or a bare user id
  --- @return boolean
  local function is_allowed(sender)
    local who = sender
    if type(sender) ~= 'table' then
      who = { id = util.id_to_string(sender) }
    end
    if not who or not who.id then
      return false
    end

    if is_admin(who) then
      return true
    end

    if state.acl.blacklist[who.id] then
      return false
    end
    if state.acl.whitelist[who.id] then
      return true
    end

    local mode = acl_mode()
    if mode == 'whitelist' then
      return list_matches(acl_config().whitelist, who)
    elseif mode == 'blacklist' then
      return not list_matches(acl_config().blacklist, who)
    end

    -- allow_all: unchanged behaviour for existing setups.
    return true
  end

  --- May this user talk to the bot in a 1:1 (private) chat?
  ---
  --- Resolution order, first match wins:
  ---
  ---   1. `integrations.telegram.p2p.enable = false` — the off switch
  ---   2. `integrations.telegram.p2p.allow` when set — authoritative, so a typo
  ---      in one entry can not silently widen access
  ---   3. a configured restriction (`acl.mode` = whitelist / blacklist), applied
  ---      through the same rules as a chat
  ---   4. default: allowed.
  ---
  --- The default is "allowed" on purpose: this integration always answered
  --- private chats, and a DM only exists after somebody opened the conversation
  --- with the bot. `allow_all` is *not* the reason — that mode is a statement
  --- about the bound chat, and it is checked above only when it is a real
  --- restriction (whitelist / blacklist).
  ---
  --- Only numeric ids count in an explicit allow list. A username entry would
  --- let anyone who takes that name later walk into the private chat.
  --- @param sender table|string|nil
  --- @return boolean
  local function is_p2p_allowed(sender)
    local who = sender
    if type(sender) ~= 'table' then
      who = { id = util.id_to_string(sender) }
    end
    if not who or not who.id then
      return false
    end

    if p2p_config().enable == false then
      return false
    end

    local allow = p2p_config().allow
    if type(allow) == 'table' and #allow > 0 then
      for _, entry in ipairs(allow) do
        local key = util.id_to_string(entry)
        -- Skip username entries: an explicit allow list must be id-based.
        if key and not key:match('^@') and key == who.id then
          return true
        end
      end
      -- An explicit list is the whole policy: no silent fallback, otherwise a
      -- typo in one entry would quietly widen access to every admin.
      return false
    end

    -- A whitelist / blacklist is a statement about who may talk to the bot at
    -- all, so it governs private chats too.
    local mode = acl_mode()
    if mode == 'whitelist' or mode == 'blacklist' then
      return is_allowed(who)
    end

    return true
  end

  --------------------------------------------------
  -- Runtime grants / denies
  --------------------------------------------------

  --- Grant access: add to the runtime whitelist, drop from the blacklist.
  --- @param user_id string
  --- @return boolean true when the ACL actually changed
  local function acl_allow(user_id)
    local id = util.id_to_string(user_id)
    if not id then
      return false
    end

    local changed = false
    if state.acl.blacklist[id] then
      state.acl.blacklist[id] = nil
      changed = true
    end
    if not state.acl.whitelist[id] then
      state.acl.whitelist[id] = true
      changed = true
    end

    if changed then
      save_state()
      log.info('[Telegram] ACL allow: ' .. id)
    end
    return changed
  end

  --- Revoke access: add to the runtime blacklist, drop from the whitelist.
  --- @param user_id string
  --- @return boolean true when the ACL actually changed
  local function acl_deny(user_id)
    local id = util.id_to_string(user_id)
    if not id then
      return false
    end

    local changed = false
    if state.acl.whitelist[id] then
      state.acl.whitelist[id] = nil
      changed = true
    end
    if not state.acl.blacklist[id] then
      state.acl.blacklist[id] = true
      changed = true
    end

    if changed then
      save_state()
      log.info('[Telegram] ACL deny: ' .. id)
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
      'Commands: /allow (reply to a user), /deny (reply to a user), /acl',
    }, '\n')
  end

  --------------------------------------------------
  -- Recent senders
  --------------------------------------------------

  --- Recently seen speakers, newest first. Backs the Neovim picker so user ids
  --- can be picked instead of copied out of the Telegram client.
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

  --- Cache a speaker's id in the state file, pruning the oldest entries.
  --- @param from table Telegram `from` object
  --- @param when_ms number|nil
  local function record_sender(from, when_ms)
    if not from or from.is_bot then
      return
    end
    local id = util.id_to_string(from.id)
    if not id then
      return
    end

    local name = from.first_name
      or from.username
      or (state.recent_senders[id] and state.recent_senders[id].name)

    state.recent_senders[id] = {
      last_seen = when_ms or (os.time() * 1000),
      name = name,
    }

    local count = 0
    for _ in pairs(state.recent_senders) do
      count = count + 1
    end
    if count <= util.MAX_RECENT_SENDERS then
      return
    end

    local entries = {}
    for sender_id, info in pairs(state.recent_senders) do
      table.insert(entries, { id = sender_id, last_seen = info.last_seen or 0 })
    end
    table.sort(entries, function(a, b)
      return a.last_seen > b.last_seen
    end)
    for i = util.MAX_RECENT_SENDERS + 1, #entries do
      state.recent_senders[entries[i].id] = nil
    end
  end

  --------------------------------------------------
  -- In-chat commands
  --------------------------------------------------

  --- Parse an ACL management command out of a message body.
  ---
  --- Lua patterns have no alternation (`|` is a literal), so each command is
  --- probed with a plain prefix check instead of one combined pattern.
  --- @param content string
  --- @return table|nil { command = 'allow'|'deny'|'acl', arg = string }
  local function parse_acl_command(content)
    local text = vim.trim(content or '')

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

  --- Identify the user an `/allow` / `/deny` command targets.
  ---
  --- Telegram gives no reliable way to turn an `@username` in text into an id
  --- (there is no entity for it, and usernames are user-chosen). So the target
  --- has to be a reply to that user's message (the reply carries `from.id`,
  --- which is authoritative), or a raw numeric id.
  --- @param arg string
  --- @param msg table raw Telegram message
  --- @return string|nil user_id
  --- @return string|nil error
  local function resolve_target(arg, msg)
    local reply_from = msg
      and msg.reply_to_message
      and msg.reply_to_message.from
    if reply_from and reply_from.id then
      return util.id_to_string(reply_from.id)
    end

    local raw = vim.trim(arg or '')
    if raw:match('^%-?%d+$') then
      return raw
    end

    if raw:match('^@') or raw:match('^%a') then
      return nil,
        'Reply to that user\'s message with the command, or pass the numeric '
          .. 'user id: an @username can be changed by anyone and cannot be '
          .. 'trusted.'
    end

    return nil, 'Usage: reply to a user\'s message with /allow or /deny.'
  end

  --- Execute an ACL management command. Non-admins are dropped silently: a
  --- "permission denied" reply would only spam the group.
  --- @param msg table raw Telegram message
  --- @param parsed table { command = ..., arg = ... }
  --- @param chat_id string container the command came from
  local function handle_acl_command(msg, parsed, chat_id)
    local from = msg.from or {}
    local sender = {
      id = util.id_to_string(from.id),
      username = from.username,
    }

    if not is_admin(sender) then
      log.warn(
        string.format(
          '[Telegram] Ignore ACL command from non-admin: %s',
          sender.id or 'unknown'
        )
      )
      return
    end

    --- ACL replies follow the chat the command came from: a `/allow` typed in
    --- a private chat must not be announced in the group.
    local function reply(text)
      ctx.M.send_message(text, ctx.container.chat_session(chat_id))
    end

    if parsed.command == 'acl' then
      reply(acl_status())
      return
    end

    local target, err = resolve_target(parsed.arg, msg)
    if not target then
      reply(err)
      return
    end

    if target == state.bot_id and state.bot_id then
      reply('Refusing to change ACL for the bot itself.')
      return
    end

    local changed = parsed.command == 'allow' and acl_allow(target)
      or acl_deny(target)

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
    entry_matches = entry_matches,
    acl_mode = acl_mode,
    get_acl = get_acl,
    is_allowed = is_allowed,
    is_admin = is_admin,
    is_p2p_allowed = is_p2p_allowed,
    acl_allow = acl_allow,
    acl_deny = acl_deny,
    acl_status = acl_status,
    get_recent_senders = get_recent_senders,
    record_sender = record_sender,
    parse_acl_command = parse_acl_command,
    resolve_target = resolve_target,
    handle_acl_command = handle_acl_command,
  }
end

return M

