-- lua/chat/integrations/telegram/poll.lua
-- Inbound side: bot identity, message filtering and the getUpdates loop.
--
-- Telegram differs from Lark in a way that simplifies this module a lot:
-- getUpdates is ONE global stream of updates for the whole bot, not one
-- request per conversation. So there is a single cursor (`offset`) and a
-- single in-flight request; the per-chat containers exist only to decide
-- routing and whether an @mention is required.
local log = require('chat.log')
local job = require('job')
local curl = require('chat.curl')
local state_module = require('chat.integrations.telegram.state')
local util = require('chat.integrations.telegram.util')

local json = vim.json
local uv = vim.uv

local M = {}

--- @param ctx table shared instance context
--- @return table poll API
function M.new(ctx)
  local state = ctx.state

  -- Chain owner id. Bumped by disconnect(), so a request that settles
  -- afterwards can tell it no longer belongs to the chain that started it.
  local poll_generation = 0

  local function save_state()
    return ctx.save_state()
  end

  --------------------------------------------------
  -- Bot identity
  --------------------------------------------------

  --- Apply a decoded getMe body to the state.
  --- @param body string raw response body
  --- @return boolean true when the identity was learned
  local function apply_bot_info(body)
    if not body or body == '' then
      return false
    end

    local ok, result = pcall(json.decode, body)
    if not ok or type(result) ~= 'table' then
      return false
    end

    if result.ok == false then
      log.warn(
        '[Telegram] getMe failed: ' .. tostring(result.description or 'unknown')
      )
      return false
    end

    local bot = result.result
    if type(bot) ~= 'table' then
      return false
    end

    local changed = state.bot_id ~= util.id_to_string(bot.id)
      or state.bot_username ~= bot.username
    state.bot_id = util.id_to_string(bot.id)
    state.bot_username = bot.username
    log.info(
      '[Telegram] Bot ID: '
        .. tostring(state.bot_id)
        .. ' (@'
        .. tostring(state.bot_username)
        .. ')'
    )

    -- Persist so the next session starts with a known identity instead of
    -- re-fetching (and, if the request fails, dropping every group mention).
    if changed then
      save_state()
    end
    return true
  end

  --- Fetch the bot identity once.
  ---
  --- Cheap (one GET) and therefore retried by the poll loop while it is still
  --- unknown: until `state.bot_username` is set, group mentions can not be
  --- detected, and silently dropping every group message is far worse than one
  --- extra request per tick.
  local function get_bot_info()
    -- Only one lookup in flight: the poll loop may call this on every tick.
    if state.bot_info_jobid then
      log.debug('[Telegram] Skip bot info: request already in flight')
      return
    end

    local bot_token = util.bot_token()
    if not bot_token then
      log.error('[Telegram] Skip bot info: bot_token not configured')
      return
    end

    local cmd = curl.build_request({
      url = util.api_url('getMe', bot_token),
      method = 'GET',
      compressed = true,
      -- Keep curl diagnostics: with plain `-s` a transport failure writes
      -- nothing anywhere and the reason is lost.
      show_error = true,
    })

    local chunks = {}
    local settled = false

    local function finish(code, signal)
      if settled then
        return
      end
      settled = true
      state.bot_info_jobid = nil

      if not apply_bot_info(table.concat(chunks, '')) then
        log.warn(
          '[Telegram] Bot info unavailable (curl exit code '
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

        if settled then
          return
        end

        local ok, result = pcall(json.decode, table.concat(chunks, ''))
        if ok and type(result) == 'table' and type(result.result) == 'table' then
          settled = true
          state.bot_info_jobid = nil
          apply_bot_info(table.concat(chunks, ''))
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
      log.warn('[Telegram] Failed to start getMe request; will retry')
      state.bot_info_jobid = nil
      return
    end

    state.bot_info_jobid = jobid
  end

  --------------------------------------------------
  -- Message text
  --------------------------------------------------

  --- Text handed to the shared handler for one message.
  ---
  --- `text` is the plain-text body; media messages carry `caption` instead.
  --- Anything else is a reference to an attachment, so passing it through
  --- would feed the model nothing useful. Each unsupported kind becomes a short
  --- marker: the message still shows up, and the model can say what it did not
  --- receive.
  --- @param msg table Telegram message
  --- @return string
  local function message_text(msg)
    if type(msg.text) == 'string' and msg.text ~= '' then
      return msg.text
    end
    if type(msg.caption) == 'string' and msg.caption ~= '' then
      return msg.caption
    end

    for kind, marker in pairs({
      photo = '[photo]',
      sticker = '[sticker]',
      audio = '[audio]',
      voice = '[voice]',
      video = '[video]',
      document = '[document]',
      animation = '[animation]',
      location = '[location]',
      contact = '[contact]',
      poll = '[poll]',
	    }) do
      if msg[kind] then
        return marker
      end
    end

    return ''
  end

  --- Remove `@bot_username` from a message body.
  ---
  --- `@bot /list` must reduce to `/list`, because the shared handler anchors
  --- its commands with `^/list`. A username is matched case-insensitively
  --- (`@ChatNvim_Bot` and `@chatnvim_bot` are the same bot).
  --- @param content string
  --- @return string
  local function strip_mention(content)
    local username = state.bot_username
    if not username or content == '' then
      return (content:gsub('^%s+', ''))
    end

    -- Lua patterns are case sensitive and there is no case-insensitive
    -- replacement, so the text is scanned instead: every `@` is compared
    -- against the username with a lowercased slice.
    local out = {}
    local index = 1
    local lowered = content:lower()
    local needle = ('@' .. username):lower()

    while true do
      local start = content:find('@', index, true)
      if not start then
        table.insert(out, content:sub(index))
        break
      end

      table.insert(out, content:sub(index, start - 1))

      local stop = start + #needle - 1
      if lowered:sub(start, stop) == needle then
        index = stop + 1
      else
        table.insert(out, content:sub(start, start))
        index = start + 1
      end
    end

    return (table.concat(out):gsub('^%s+', ''):gsub('%s+$', ''))
  end

  --- Is this message addressed to the bot?
  ---
  --- A group message counts only when it @mentions the bot or replies to one
  --- of its messages. Private chats have nobody to mention, so they always
  --- count (handled by the caller).
  --- @param msg table Telegram message
  --- @return boolean
  local function is_mention_bot(msg)
    local username = state.bot_username
    local bot_id = state.bot_id

    -- Reply to one of the bot's own messages: the strongest signal available
    -- and independent of the text.
    local replied = msg.reply_to_message and msg.reply_to_message.from
    if replied then
      if bot_id and util.id_to_string(replied.id) == bot_id then
        return true
      end
      -- Username is unique across users and bots, so a match is proof enough.
      -- `is_bot` is not required: an update may carry only the username.
      if username and replied.username == username then
        return true
      end
    end

    -- An explicit `mention` entity is resolved by Telegram itself, so it does
    -- not depend on how the username was typed.
    if type(msg.entities) == 'table' and username then
      for _, entity in ipairs(msg.entities) do
        if type(entity) == 'table' and entity.type == 'mention' then
          local from = entity.offset + 1
          local text = msg.text or msg.caption or ''
          local mention = text:sub(from, from + entity.length - 1)
          if ('@' .. username):lower() == mention:lower() then
            return true
          end
        end
      end
    end

    -- Fallback while the identity is still unknown (or the client sent plain
    -- text without entities): a literal `@username` in the body.
    if username then
      local body = msg.text or msg.caption
      if body then
        return body:lower():find('@' .. username:lower(), 1, true) ~= nil
      end
    end
    return false
  end

  --------------------------------------------------
  -- Message handling (one getUpdates response)
  --------------------------------------------------

  --- Process one update. Separated from the loop so every early exit is a
  --- plain `return` instead of a `goto`.
  --- @param update table
  --- @return boolean has_new
  local function handle_update(update)
    if type(update) ~= 'table' then
      return false
    end

    -- Skip already processed updates. `remember_processed` records the id in
    -- insertion order and trims the cache, so eviction keeps the *newest* ids
    -- instead of an arbitrary `pairs()` selection.
    if not state_module.remember_processed(state, update.update_id) then
      return false
    end

    local msg = update.message
    if type(msg) ~= 'table' then
      return true
    end

    -- Bot (and channel) messages: replying to them would start a loop.
    if msg.from and msg.from.is_bot then
      return true
    end
    if not msg.from then
      return true
    end

    local chat = msg.chat or {}
    local chat_id = util.id_to_string(chat.id)
    if not chat_id then
      return true
    end

    -- Cache the speaker before any filtering: the picker wants to list
    -- everyone who showed up in the chat, not only those allowed to talk.
    ctx.acl.record_sender(msg.from)

    local chat_type = chat.type or 'group'
    local is_private = chat_type == 'private'

    -- Register the container: routing needs to know whether this chat is a
    -- group (mention required) or a private chat (answer everything), and a
    -- private chat records the peer so two peers are never mixed up.
    local ctr = ctx.container.ensure_container(chat_id, {
      chat_type = is_private and 'private' or 'group',
      peer = is_private and util.id_to_string(msg.from.id) or nil,
      title = chat.title,
    })

    -- Groups require an @mention; a private chat has nobody to mention.
    if not is_private and not is_mention_bot(msg) then
      log.debug('[Telegram] Skip message (not mention/reply): ' .. chat_id)
      return true
    end

    local content = message_text(msg)
    if is_private or (state.bot_username and content ~= '') then
      -- A private message has no mention key to strip, but stripping is
      -- harmless there and keeps `@bot /list` working in both kinds of chat.
      content = strip_mention(content)
    end

    if content == '' then
      return true
    end

    local sender = {
      id = util.id_to_string(msg.from.id),
      username = msg.from.username,
    }

    -- Private chats have their own default-deny policy: `acl.mode =
    -- allow_all` would otherwise let anyone who finds the bot open a DM.
    -- The explicitly configured main chat is exempt: it is trusted by
    -- definition, and otherwise a user whose `chat_id` *is* their private
    -- chat would lock themselves out.
    if is_private and chat_id ~= util.main_chat_id() then
      if not ctx.acl.is_p2p_allowed(sender) then
        log.debug(
          '[Telegram] Skip private message (peer not allowed): '
            .. tostring(sender.id)
        )
        return true
      end
      -- The registered peer is the authoritative 1:1 identity; a message
      -- from somebody else inside that container is not trustworthy.
      if ctr.peer and sender.id and ctr.peer ~= sender.id then
        log.warn(
          '[Telegram] private sender mismatch ('
            .. tostring(sender.id)
            .. ' != '
            .. ctr.peer
            .. '), ignoring message'
        )
        return true
      end
    end

    local sender_is_admin = ctx.acl.is_admin(sender)

    -- ACL: admins always pass, so they can recover a whitelist that locked
    -- them out of management commands.
    if not sender_is_admin and not ctx.acl.is_allowed(sender) then
      log.debug(
        '[Telegram] Skip message (sender not allowed): '
          .. (sender.id or '?')
      )
      return true
    end

    -- In-chat ACL management: must run before the shared handler so `/allow`
    -- never reaches the LLM as a normal prompt.
    local acl_command = ctx.acl.parse_acl_command(content)
    if acl_command then
      ctx.acl.handle_acl_command(msg, acl_command, chat_id)
      return true
    end

    -- Call callback with the message
    if state.callback then
      vim.schedule(function()
        state.callback({
          author = msg.from.first_name
            or msg.from.username
            or sender.id
            or 'Unknown',
          content = content,
          message_id = msg.message_id,
          -- Source fields: the shared layer routes the reply back to the chat
          -- the message came from.
          chat_id = chat_id,
          chat_type = is_private and 'private' or 'group',
        })
      end)
    end

    return true
  end

  --- Process the raw body of a getUpdates response.
  ---
  --- Split out of the job callback so every early exit (empty body, API
  --- error, decode failure) is a plain `return`.
  --- @param response string raw response body
  --- @return boolean has_new
  local function handle_updates(response)
    if response == nil or response == '' then
      log.debug('[Telegram] Empty response body')
      return false
    end

    local ok, result = pcall(json.decode, response)
    if not ok or type(result) ~= 'table' then
      log.error('[Telegram] JSON decode failed: ' .. response)
      return false
    end

    if result.ok == false then
      log.error(
        '[Telegram] API error: ' .. tostring(result.description or 'unknown')
      )
      return false
    end

    local updates = result.result
    if type(updates) ~= 'table' or #updates == 0 then
      return false
    end

    -- getUpdates returns updates in ascending order, so answering them in
    -- order keeps a conversation coherent.
    local highest = state.last_update_id
    local has_new = false
    for _, update in ipairs(updates) do
      local id = tonumber(update and update.update_id)
      if id and (not highest or id > highest) then
        highest = id
      end
      if handle_update(update) then
        has_new = true
      end
    end

    -- Advance the cursor: the next request asks for what comes after it.
    if highest and highest ~= state.last_update_id then
      state.last_update_id = highest
      save_state()
      log.debug('[Telegram] Cursor advanced to ' .. tostring(highest))
    end

    if has_new then
      save_state()
    end
    return has_new
  end

  --------------------------------------------------
  -- Fetch updates
  --------------------------------------------------

  --- Whether a fetch still belongs to the running poll chain.
  ---
  --- `disconnect()` bumps the generation, so a request started before it
  --- settles as "detached": its body must not be turned into messages, or a
  --- stopped poller would still answer, run `/allow` and write the state file.
  --- @param generation integer chain that started the fetch
  --- @return boolean
  local function is_current_chain(generation)
    return state.is_running and generation == poll_generation
  end

  --- Fetch pending updates, then hand control back.
  ---
  --- `done()` runs exactly once per call, whichever way the request settles.
  --- @param done fun()
  --- @param generation? integer chain the fetch belongs to (default: current)
  local function fetch_updates(done, generation)
    generation = generation or poll_generation

    local bot_token = util.bot_token()
    if not bot_token then
      log.error('[Telegram] Skip fetch: bot_token not configured')
      done()
      return
    end

    local params = {
      -- Long polling: the request returns as soon as a message arrives, which
      -- keeps replies snappy without a short tick interval, and the
      -- `is_fetching` guard already prevents overlap.
      timeout = 10,
      allowed_updates = { 'message' },
    }
    if state.last_update_id then
      params.offset = state.last_update_id + 1
    end

    -- The request settles on whichever comes first: the exit callback or the
    -- watchdog. `settled` makes `done()` fire once even when a timed-out job
    -- still reports its exit afterwards. The budget is well above the long
    -- poll timeout, so it only catches genuinely stuck transports.
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

    timeout:start(20000, 0, function()
      log.warn('[Telegram] Request timeout (getUpdates)')
      settle()
    end)

    local response_chunks = {}

    -- A body is processed as soon as it decodes, not only on exit: a long poll
    -- that keeps the connection open would otherwise delay every delivered
    -- message until the request ends. `handled` keeps the exit callback from
    -- processing the same body twice.
    local handled = false
    local function consume()
      if handled then
        return
      end

      local body = table.concat(response_chunks, '')
      if body == '' then
        return
      end

      local ok, result = pcall(json.decode, body)
      if not ok or type(result) ~= 'table' then
        return
      end

      handled = true
      if not is_current_chain(generation) then
        log.debug('[Telegram] Drop response: poll stopped')
        return
      end

      local ok2, err = pcall(handle_updates, body)
      if not ok2 then
        log.error('[Telegram] Update handling failed: ' .. tostring(err))
      end
    end

    local cmd = curl.build_request({
      url = util.api_url('getUpdates', bot_token),
      method = 'POST',
      compressed = true,
      headers = {
        'Content-Type: application/json',
      },
      body = json.encode(params),
    })

    local jobid = job.start(cmd, {
      raw = true,
      on_stdout = function(_, data)
        for _, chunk in ipairs(data) do
          table.insert(response_chunks, chunk)
        end
        consume()
      end,
      on_exit = function()
        -- Fallback for a body that only became complete at exit (split
        -- chunks), and for transports that report exit before stdout.
        consume()
        settle()
      end,
    })

    -- A job that could not be spawned never fires a callback: end the round
    -- here, otherwise the poll chain would stop forever.
    if not jobid or jobid <= 0 then
      log.error('[Telegram] Failed to start getUpdates request')
      settle()
    end
  end

  --------------------------------------------------
  -- Poll tick
  --------------------------------------------------
  local function poll_tick()
    -- Identity first: without `state.bot_username` every group mention looks
    -- like "addressed to somebody else" and gets dropped. Retrying here keeps
    -- the cost at one cheap GET per tick until it succeeds.
    if not state.bot_username then
      get_bot_info()
    end

    if state.is_fetching then
      log.debug('[Telegram] poll_tick: skipped (already fetching)')
      return
    end

    state.is_fetching = true

    local generation = poll_generation
    fetch_updates(function()
      -- Re-checked inside the callback: a `done()` that arrives after
      -- disconnect() must not leave the flag set for a dead poller.
      state.is_fetching = false
      log.debug(
        '[Telegram] Poll round finished (generation '
          .. tostring(generation)
          .. ')'
      )
    end, generation)
  end

  --------------------------------------------------
  -- Connect
  --------------------------------------------------
  local function connect(callback)
    local bot_token = util.bot_token()
    if not bot_token then
      log.error('[Telegram] bot_token not configured')
      return
    end

    if not util.main_chat_id() then
      log.error('[Telegram] chat_id not configured')
      return
    end

    if state.is_running then
      return
    end

    state.callback = callback
    state.is_running = true

    ctx.state_io.load()

    -- Unlike Lark the pending updates are NOT discarded: getUpdates only
    -- returns updates the bot has not consumed yet, so anything still queued
    -- really was never answered. Replying to it is the correct behaviour and
    -- matches how the integration behaved before this refactor.

    local main = util.main_chat_id()
    if main then
      ctx.container.ensure_container(main)
    end
    save_state()

    get_bot_info()
    log.info('[Telegram] Starting polling...')

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

    log.info('[Telegram] Polling started')
  end

  --------------------------------------------------
  -- Disconnect
  --------------------------------------------------
  local function disconnect()
    -- Invalidate the running chain before anything else: an in-flight fetch
    -- that settles from here on is detached, so it neither processes messages
    -- nor advances the cursor.
    poll_generation = poll_generation + 1

    if state.timer then
      state.timer:stop()
      -- Stop alone leaves the handle allocated: connect() creates a fresh timer
      -- on every start, so skipping close() leaks one uv handle per
      -- connect/disconnect cycle for the whole lifetime of the process.
      if not state.timer:is_closing() then
        state.timer:close()
      end
      state.timer = nil
    end

    state.is_running = false
    state.is_fetching = false
    state.callback = nil
    state.bot_info_jobid = nil
    save_state()
    log.info('[Telegram] Polling stopped')
  end

  return {
    apply_bot_info = apply_bot_info,
    get_bot_info = get_bot_info,
    message_text = message_text,
    strip_mention = strip_mention,
    is_mention_bot = is_mention_bot,
    handle_update = handle_update,
    handle_updates = handle_updates,
    fetch_updates = fetch_updates,
    poll_tick = poll_tick,
    connect = connect,
    disconnect = disconnect,
  }
end

return M

