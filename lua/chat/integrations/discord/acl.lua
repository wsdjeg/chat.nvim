-- lua/chat/integrations/discord/acl.lua
-- Access control plus the in-chat `/allow`, `/deny`, `/acl` commands.
--
-- Three modes:
--   allow_all  (default) - anyone in the channel may talk to the bot
--   whitelist            - only listed user ids
--   blacklist            - everyone except listed user ids
--
-- Discord user ids are snowflakes: unguessable and un-forgeable, unlike a
-- display name, so they are the only identity used here. Unlike Lark there is
-- one id space, so no email / mobile resolution is needed: every comparison is
-- a plain string check and costs zero requests.
--
-- Runtime grants/denies issued from a chat are persisted in the state file;
-- config lists are merged on top of them.
--
-- DM admission has its own policy (`is_p2p_allowed`), because a DM is one
-- person talking to the bot privately and `acl.mode` describes the shared
-- channels: reusing it directly would let `allow_all` admit every DM the bot
-- can see.
local log = require('chat.log')
local util = require('chat.integrations.discord.util')

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
      admins = cfg.admins or {},
      whitelist = util.merge_ids(cfg.whitelist, state.acl.whitelist),
      blacklist = util.merge_ids(cfg.blacklist, state.acl.blacklist),
    }
  end

  --- Is this user id one of the configured admins?
  --- @param user_id string|nil
  --- @return boolean
  local function is_admin(user_id)
    if type(user_id) ~= 'string' or user_id == '' then
      return false
    end

    for _, configured in ipairs(acl_config().admins or {}) do
      if configured == user_id then
        return true
      end
    end
    return false
  end

  --- Is this user id allowed to talk to the bot in a channel?
  ---
  --- Admins always pass, so they can still recover a whitelist that locked
  --- them out of the management commands.
  ---
  --- Runtime entries (issued from the chat, persisted in the state file) win
  --- over the configured mode: an admin can `/deny` (or `/allow`) a user even
  --- while the mode is `allow_all`, which is what keeps the in-chat commands
  --- useful without having to edit the config first.
  --- @param user_id string|nil
  --- @return boolean
  local function is_allowed(user_id)
    if type(user_id) ~= 'string' or user_id == '' then
      return false
    end

    if is_admin(user_id) then
      return true
    end

    if state.acl.blacklist[user_id] then
      return false
    end
    if state.acl.whitelist[user_id] then
      return true
    end

    local mode = acl_mode()

    if mode == 'whitelist' then
      for _, entry in ipairs(acl_config().whitelist or {}) do
        if entry == user_id then
          return true
        end
      end
      return false
    elseif mode == 'blacklist' then
      for _, entry in ipairs(acl_config().blacklist or {}) do
        if entry == user_id then
          return false
        end
      end
      return true
    end

    -- allow_all: unchanged behaviour for existing setups.
    return true
  end

  --- May this user id talk to the bot in a 1:1 (DM) chat?
  ---
  --- Resolution order, first match wins:
  ---
  ---   1. `integrations.discord.p2p.allow` when set -- authoritative, so a
  ---      typo in one entry can not silently widen access
  ---   2. a configured restriction (`acl.mode` = whitelist / blacklist) applied
  ---      through the same rules as a channel
  ---   3. `acl.admins`
  ---   4. default: allowed, which is the historical Discord behaviour (a DM
  ---      channel only exists after the peer opened the conversation myself)
  ---
  --- @param user_id string|nil
  --- @return boolean
  local function is_p2p_allowed(user_id)
    if not util.p2p_enabled() then
      return false
    end
    if type(user_id) ~= 'string' or user_id == '' then
      return false
    end

    local allow = util.p2p_allow()
    if allow then
      for _, entry in ipairs(allow) do
        if entry == user_id then
          return true
        end
      end
      return false
    end

    -- A whitelist / blacklist is a statement about who may talk to the bot at
    -- all, so it also governs DMs. `allow_all` deliberately does not: turning
    -- every open DM channel into a served conversation would be spam.
    local mode = acl_mode()
    if mode == 'whitelist' or mode == 'blacklist' then
      return is_allowed(user_id)
    end

    if is_admin(user_id) then
      return true
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
    if type(user_id) ~= 'string' or user_id == '' then
      return false
    end

    local changed = false
    if state.acl.blacklist[user_id] then
      state.acl.blacklist[user_id] = nil
      changed = true
    end
    if not state.acl.whitelist[user_id] then
      state.acl.whitelist[user_id] = true
      changed = true
    end

    if changed then
      save_state()
      log.info('[Discord] ACL allow: ' .. user_id)
    end
    return changed
  end

  --- Revoke access: add to the runtime blacklist, drop from the whitelist.
  --- @param user_id string
  --- @return boolean true when the ACL actually changed
  local function acl_deny(user_id)
    if type(user_id) ~= 'string' or user_id == '' then
      return false
    end

    local changed = false
    if state.acl.whitelist[user_id] then
      state.acl.whitelist[user_id] = nil
      changed = true
    end
    if not state.acl.blacklist[user_id] then
      state.acl.blacklist[user_id] = true
      changed = true
    end

    if changed then
      save_state()
      log.info('[Discord] ACL deny: ' .. user_id)
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

  --- Recently seen speakers, newest first.
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

  --- Cache a speaker in the state file, pruning the oldest entries.
  ---
  --- Bot messages are not speakers worth granting access to, so they are
  --- skipped: the cache is for humans the bot already answered.
  --- @param msg table raw Discord message
  local function record_sender(msg)
    local author = msg and msg.author
    if type(author) ~= 'table' or type(author.id) ~= 'string' then
      return
    end
    if author.bot then
      return
    end

    local previous = state.recent_senders[author.id]
    state.recent_senders[author.id] = {
      -- Discord message ids are snowflakes too; the timestamp encoded in them
      -- is more precise than os.time() but needs math the cache does not use.
      -- Wall clock is enough to keep the list ordered.
      last_seen = os.time() * 1000,
      name = author.username or (previous and previous.name),
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
  -- Message text helpers
  --------------------------------------------------

  --- Strip the leading mention markers Discord puts in front of the real
  --- text, so `<@123> /allow <@456>` reduces to `/allow <@456>`.
  ---
  --- Only the *leading* ones are removed: a mention in the argument of
  --- `/allow` is the target and has to survive.
  --- @param text string
  --- @return string
  local function strip_leading_mentions(text)
    local rest = text or ''
    while true do
      local prefix = rest:match('^%s*<@!?%d+>%s*')
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

  --- Resolve a command argument to a user id.
  ---
  --- Accepts a mention marker (`<@123>` / `<@!123>`), a bare `@123`, or a raw
  --- snowflake. The message's `mentions` array is consulted first: that is the
  --- id Discord itself attributes the mention to, so a hand-typed marker can
  --- not be used to name somebody else.
  --- @param arg string
  --- @param mentions table|nil the message's mentions array
  --- @return string|nil
  local function resolve_user_id(arg, mentions)
    local raw = (arg or ''):gsub('^%s+', ''):gsub('%s+$', '')
    if raw == '' then
      return nil
    end

    for _, mention in ipairs(mentions or {}) do
      if type(mention) == 'table' and type(mention.id) == 'string' then
        local marker = '<@' .. mention.id .. '>'
        local marker_nick = '<@!' .. mention.id .. '>'
        if raw == marker or raw == marker_nick then
          return mention.id
        end
      end
    end

    local id = raw:gsub('^<@!?', ''):gsub('>$', ''):gsub('^@', '')
    if id:match('^%d+$') then
      return id
    end

    return nil
  end

  --- Execute an ACL management command. Non-admins are dropped silently: a
  --- "permission denied" reply would only spam the channel.
  --- @param msg table raw Discord message
  --- @param parsed table { command = ..., arg = ... }
  --- @param channel_id string|nil container the command came from
  local function handle_acl_command(msg, parsed, channel_id)
    local sender_id = type(msg.author) == 'table' and msg.author.id or nil

    --- ACL replies follow the channel the command came from: a `/allow` typed
    --- in a DM must not be announced in a guild channel. A nil session keeps
    --- the single-channel behaviour (the configured main channel).
    local function reply(text)
      ctx.M.send_message(text, ctx.container.chat_session(channel_id))
    end

    if not is_admin(sender_id) then
      log.warn(
        string.format(
          '[Discord] Ignore ACL command from non-admin: %s',
          sender_id or 'unknown'
        )
      )
      return
    end

    if parsed.command == 'acl' then
      reply(acl_status())
      return
    end

    local target = resolve_user_id(parsed.arg, msg.mentions)
    if not target then
      reply('Usage: /allow @user or /deny @user (mention the user in the command)')
      return
    end

    if target == state.bot_id then
      reply('Refusing to change ACL for the bot itself.')
      return
    end

    local changed
    if parsed.command == 'allow' then
      changed = acl_allow(target)
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
    acl_mode = acl_mode,
    get_acl = get_acl,
    is_admin = is_admin,
    is_allowed = is_allowed,
    is_p2p_allowed = is_p2p_allowed,
    acl_allow = acl_allow,
    acl_deny = acl_deny,
    acl_status = acl_status,
    get_recent_senders = get_recent_senders,
    record_sender = record_sender,
    strip_leading_mentions = strip_leading_mentions,
    parse_acl_command = parse_acl_command,
    resolve_user_id = resolve_user_id,
    handle_acl_command = handle_acl_command,
  }
end

return M

