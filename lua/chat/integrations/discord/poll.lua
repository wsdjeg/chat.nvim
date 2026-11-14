-- lua/chat/integrations/discord/poll.lua
-- Inbound side: bot identity, message filtering, per-container fetch and the
-- polling loop.
--
-- Every container is read with one sequential request per tick (`done()` fires
-- exactly once per fetch), so a slow channel can not starve the others and the
-- rate limit is never raced.
local log = require('chat.log')
local job = require('job')
local job_stop = job.stop
local state_module = require('chat.integrations.discord.state')
local util = require('chat.integrations.discord.util')
local http = require('chat.integrations.discord.http')

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
  -- Poll health tracking (state-change logging)
  --
  -- Healthy polling is silent. A failure logs once on entry, every
  -- FAILURE_HEARTBEAT polls while it persists, and once on recovery.
  --------------------------------------------------
  local function poll_failed(reason)
    state.fail_count = (state.fail_count or 0) + 1
    if state.fail_count == 1 then
      log.warn('[Discord] Polling failed: ' .. (reason or 'unknown error'))
    elseif state.fail_count % util.FAILURE_HEARTBEAT == 0 then
      log.warn(
        string.format(
          '[Discord] Polling still failing (%d attempts, last: %s)',
          state.fail_count,
          reason or 'unknown error'
        )
      )
    end
  end

  local function poll_ok()
    if (state.fail_count or 0) > 0 then
      log.info(
        string.format(
          '[Discord] Polling recovered after %d failed attempt(s)',
          state.fail_count
        )
      )
      state.fail_count = 0
    end
  end

  --------------------------------------------------
  -- Bot identity
  --------------------------------------------------

  --- Apply a decoded /users/@me payload to the state.
  --- @param data table|nil decoded user object
  --- @return boolean true when the identity was learned
  local function apply_bot_info(data)
    if type(data) ~= 'table' or type(data.id) ~= 'string' or data.id == '' then
      return false
    end

    local changed = state.bot_id ~= data.id
      or state.bot_username ~= data.username
    state.bot_id = data.id
    state.bot_username = data.username
    log.info(
      '[Discord] Bot ID: ' .. state.bot_id .. ' (' .. tostring(state.bot_username) .. ')'
    )

    -- Persist so the next session starts with a known identity instead of
    -- re-fetching (and, if the request fails, dropping every group message).
    if changed then
      save_state()
    end
    return true
  end

  --- Fetch the bot identity once.
  ---
  --- Retried by the poll loop while it is still unknown: until `state.bot_id`
  --- is set, group mentions can not be detected, and silently dropping every
  --- group message is far worse than one extra request per tick.
  --- @param callback? fun() fired once the attempt settles
  local function get_bot_info(callback)
    callback = callback or function() end

    -- Only one lookup in flight: the poll loop may call this on every tick.
    if state.bot_jobid then
      log.debug('[Discord] Skip bot info: request already in flight')
      callback()
      return
    end

    local jobid = http.request('GET', '/users/@me', nil, function(data, err)
      state.bot_jobid = nil
      if not apply_bot_info(data) then
        log.warn(
          '[Discord] Bot info unavailable ('
            .. (err or 'unexpected response')
            .. '); group mentions stay undetectable until it succeeds'
        )
      end
      callback()
    end)

    -- A job that could not be spawned returns 0: neither callback would ever
    -- fire, so the in-flight flag must be cleared instead of blocking every
    -- later retry (0 is truthy in Lua).
    if not jobid or jobid <= 0 then
      log.warn('[Discord] Failed to start /users/@me request; will retry')
      state.bot_jobid = nil
      callback()
      return
    end

    state.bot_jobid = jobid
  end

  --------------------------------------------------
  -- Message filtering
  --------------------------------------------------

  --- Whether a guild message is addressed to the bot.
  ---
  --- Mentions and replies are the two ways a guild member can address the bot
  --- explicitly; a bare message is not for it.
  --- @param msg table message object
  --- @return boolean
  local function is_for_bot(msg)
    for _, m in ipairs(msg.mentions or {}) do
      if type(m) == 'table' and m.id == state.bot_id then
        return true
      end
    end

    local ref = msg.referenced_message
    if type(ref) == 'table' and type(ref.author) == 'table' then
      if ref.author.id == state.bot_id then
        return true
      end
    end

    return false
  end

  --- Text handed to the shared handler for one message.
  ---
  --- Discord delivers plain text in `content`; attachments and embeds carry no
  --- readable part, so they become a short marker instead of a JSON blob the
  --- model can neither read nor fetch.
  --- @param msg table message object
  --- @return string
  local function message_text(msg)
    local content = type(msg.content) == 'string' and msg.content or ''

    -- `<@123>` / `<@!123>` mention markers carry no readable text; strip them
    -- before the shared handler runs, whose slash commands are anchored with
    -- `^/list` and would never match `@bot /list` otherwise.
    content = content:gsub('<@!?%d+>', ''):gsub('^%s+', ''):gsub('%s+$', '')

    if content ~= '' then
      return content
    end

    local attachments = msg.attachments
    if type(attachments) == 'table' and #attachments > 0 then
      local names = {}
      for _, a in ipairs(attachments) do
        if type(a) == 'table' and type(a.filename) == 'string' then
          table.insert(names, a.filename)
        end
      end
      if #names > 0 then
        return '[attachment: ' .. table.concat(names, ', ') .. ']'
      end
      return '[attachment]'
    end

    return ''
  end

  --------------------------------------------------
  -- Message handling (one container response)
  --------------------------------------------------

  --- Process the raw response of one container fetch.
  ---
  --- Split out of the job callback so every early exit (empty body, API error,
  --- unexpected shape) is a plain `return` instead of having to remember to
  --- release the polling chain.
  --- @param channel_id string container the response belongs to
  --- @param messages table|nil decoded response
  --- @param err string|nil transport failure reason
  local function handle_messages(channel_id, messages, err)
    if messages == nil then
      poll_failed(err or 'request failed')
      return
    end

    -- API error object (e.g. 401/429/403) instead of a message array
    if type(messages) ~= 'table' or (messages.message and not messages[1]) then
      local reason = 'unexpected response'
      if type(messages) == 'table' and messages.message then
        reason = 'API error: ' .. tostring(messages.message)
      end
      poll_failed(reason)
      return
    end

    poll_ok()

    if #messages == 0 then
      return
    end

    local ctr = ctx.container.ensure_container(channel_id)
    local has_new = false

    -- Reverse to process in chronological order
    for i = #messages, 1, -1 do
      local msg = messages[i]

      -- Skip already processed. `remember_processed` records the id in
      -- insertion order and trims the cache, so eviction keeps the *newest*
      -- ids instead of an arbitrary `pairs()` selection.
      if not state_module.remember_processed(state, msg.id) then
        goto continue
      end
      has_new = true

      -- Advance the cursor for every seen message, bot echoes included: the
      -- cursor marks how far this channel has been read, not who was answered.
      ctx.container.advance_cursor(channel_id, msg.id)

      -- Skip bot messages (this bot's own replies, and any other bot)
      if type(msg.author) ~= 'table' or msg.author.bot then
        goto continue
      end

      -- Cache the speaker before any filtering: a picker wants to list
      -- everyone who showed up in the channel, not only those allowed to talk.
      ctx.acl.record_sender(msg)

      local is_p2p = ctr.chat_type == 'p2p'

      -- In a DM there is nobody to @mention: the message is addressed to the
      -- bot by definition. Guild channels keep requiring the mention or a
      -- reply, plus slash commands.
      local content = message_text(msg)
      if content == '' then
        goto continue
      end
      if not is_p2p and not is_for_bot(msg) and not content:match('^/') then
        log.debug('[Discord] Skip message (not mention/reply): ' .. tostring(msg.id))
        goto continue
      end

      -- ACL commands carry their target as a mention (`/allow <@456>`), and
      -- `message_text()` removes every marker (it exists to clean the text
      -- handed to the model). So the command is parsed from a second string
      -- that only drops the *leading* bot mention.
      local acl_text = ctx.acl.strip_leading_mentions(
        type(msg.content) == 'string' and msg.content or ''
      )

      local sender_id = type(msg.author) == 'table' and msg.author.id or nil

      -- DM admission. A DM arrives only after the conversation was opened, but
      -- the peer allow list (when configured) is authoritative, and the
      -- registered peer is the only trustworthy identity in that container.
      if is_p2p then
        local peer = ctr.peer or sender_id
        if not ctx.acl.is_p2p_allowed(peer) then
          log.debug(
            '[Discord] Skip p2p message (peer not allowed): ' .. tostring(peer)
          )
          goto continue
        end
        if ctr.peer and sender_id and ctr.peer ~= sender_id then
          log.warn(
            '[Discord] p2p sender mismatch ('
              .. tostring(sender_id)
              .. ' != '
              .. tostring(ctr.peer)
              .. '), ignoring message'
          )
          goto continue
        end
      end

      -- ACL: admins always pass, so they can recover a whitelist that
      -- locked them out of management commands.
      if not ctx.acl.is_admin(sender_id) and not ctx.acl.is_allowed(sender_id) then
        log.debug(
          '[Discord] Skip message (sender not allowed): ' .. tostring(sender_id)
        )
        goto continue
      end

      -- In-chat ACL management: must run before the shared handler so
      -- `/allow` never reaches the LLM as a normal prompt.
      local acl_command = ctx.acl.parse_acl_command(acl_text)
      if acl_command then
        ctx.acl.handle_acl_command(msg, acl_command, channel_id)
        goto continue
      end

      -- Call callback with the message
      if state.callback then
        -- Remember where the message came from before handing it over: the
        -- shared layer starts a typing timer immediately and calls
        -- `send_typing(true)` without a routing hint, so this is the only place
        -- that can tell the indicator which channel is being answered.
        state.last_active_channel = channel_id
        vim.schedule(function()
          state.callback({
            author = (type(msg.author) == 'table' and msg.author.username)
              or 'Unknown',
            content = content,
            channel_id = msg.channel_id or channel_id,
            message_id = msg.id,
            reply = msg.referenced_message ~= nil,
            -- Source fields: the shared layer routes the reply back to the
            -- channel the message came from. Pure additions, old integrations
            -- never see them.
            chat_id = channel_id,
            chat_type = ctr.chat_type or 'group',
          })
        end)
      end

      ::continue::
    end

    if has_new then
      save_state()
    end
  end

  --------------------------------------------------
  -- Fetch one container
  --------------------------------------------------

  --- Whether a fetch still belongs to the running poll chain.
  ---
  --- `disconnect()` bumps the generation, so a request started before it
  --- settles as "detached": its body must not be turned into messages, or a
  --- stopped poller would still answer, run commands, advance cursors and write
  --- the state file.
  --- @param generation integer chain that started the fetch
  --- @return boolean
  local function is_current_chain(generation)
    return state.is_running and generation == poll_generation
  end

  --- Fetch the messages of a single container, then hand control back.
  ---
  --- Guild channels and DMs are addressed identically
  --- (`/channels/{id}/messages`); they differ only in whether an @mention is
  --- required and whether the sender is admitted (see handle_messages).
  ---
  --- `done()` runs exactly once per call, whichever way the request settles, so
  --- the polling tick can walk the container list without overlapping requests.
  --- @param channel_id string
  --- @param done fun()
  --- @param generation? integer chain the fetch belongs to (default: current)
  local function fetch_container(channel_id, done, generation)
    generation = generation or poll_generation

    if not util.token() then
      log.error('[Discord] Skip fetch: token not configured')
      done()
      return
    end

    -- Re-checked after the (synchronous) token read: disconnect() may have run
    -- between two containers of the same chain.
    if not is_current_chain(generation) then
      done()
      return
    end

    local endpoint = '/channels/' .. channel_id .. '/messages?limit=10'
    local cursor = ctx.container.container_cursor(channel_id)
    if cursor then
      endpoint = endpoint .. '&after=' .. cursor
    end

    -- Safety net only: curl itself fails fast (connect 5s / total 10s). If this
    -- fires, the job callback was lost -- kill the job so a hung curl cannot
    -- linger forever.
    local jobid
    local settled = false
    local watchdog_fired = false
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

    timeout:start(util.WATCHDOG_TIMEOUT, 0, function()
      watchdog_fired = true
      log.warn(
        '[Discord] Watchdog fired ('
          .. channel_id
          .. '), killing job and releasing lock'
      )
      if jobid and jobid > 0 then
        job_stop(jobid, 15) -- SIGTERM: the killed job still emits on_exit
      end
      settle()
    end)

    jobid = http.request('GET', endpoint, nil, function(messages, err)
      if not watchdog_fired then
        timeout:stop()
        if not timeout:is_closing() then
          timeout:close()
        end
      end

      if is_current_chain(generation) then
        local ok, err2 = pcall(handle_messages, channel_id, messages, err)
        if not ok then
          log.error('[Discord] Message handling failed: ' .. tostring(err2))
        end
      else
        log.debug('[Discord] Drop response (' .. channel_id .. '): poll stopped')
      end
      settle()
    end)

    -- A job that could not be spawned returns 0: no callback ever fires, so the
    -- chain has to be released here.
    if not jobid or jobid <= 0 then
      log.warn('[Discord] Failed to start fetch for ' .. channel_id)
      settle()
    end
  end

  --------------------------------------------------
  -- Poll tick: one request per container, strictly sequential
  --------------------------------------------------
  local function poll_tick()
    -- Identity first: without `state.bot_id` every group mention looks like
    -- "addressed to somebody else" and gets dropped.
    if not state.bot_id then
      get_bot_info()
    end

    if state.is_fetching then
      log.debug('[Discord] poll_tick: skipped (already fetching)')
      return
    end

    -- A state file from before the container abstraction has no entry yet: the
    -- configured main channel is then the only container, exactly as before.
    if vim.tbl_count(state.containers) == 0 then
      local main = util.main_channel_id()
      if not main then
        log.error('[Discord] Channel ID not configured')
        return
      end
      ctx.container.ensure_container(main)
    end

    local ids = util.sorted_keys(state.containers)
    if #ids == 0 then
      return
    end

    state.is_fetching = true

    local generation = poll_generation
    local index = 0
    local function next_container()
      -- Every step re-checks the chain: a `done()` that arrives after
      -- disconnect() must end the round instead of fetching the containers
      -- that are still queued.
      if not is_current_chain(generation) then
        state.is_fetching = false
        log.debug('[Discord] Poll chain stopped: poller no longer running')
        return
      end

      index = index + 1
      if index > #ids then
        state.is_fetching = false
        return
      end
      -- Sequential on purpose: parallel requests would race on the rate limit
      -- and make the log unreadable.
      fetch_container(ids[index], next_container, generation)
    end

    next_container()
  end

  --- One poll tick plus the periodic DM refresh.
  ---
  --- A DM channel only exists once the conversation was opened, so new peers
  --- can only be learned by re-listing. Refreshing every
  --- `util.DM_REFRESH_TICKS` ticks keeps the cost at one request per ~36s.
  local function tick()
    if not state.is_running then
      return
    end

    poll_tick()

    state.dm_ticks = (state.dm_ticks or 0) + 1
    if state.dm_ticks >= util.DM_REFRESH_TICKS then
      state.dm_ticks = 0
      ctx.discover.discover_dm_channels()
    end
  end

  --------------------------------------------------
  -- Connect
  --------------------------------------------------
  local function connect(callback)
    if not util.token() then
      log.error('[Discord] Token not configured')
      return
    end

    if not util.main_channel_id() then
      log.error('[Discord] Channel ID not configured')
      return
    end

    if state.is_running then
      return
    end

    state.callback = callback
    state.is_running = true

    ctx.state_io.load()

    local function start_polling()
      log.info('[Discord] Starting polling...')

      -- Config-named containers first, so the very first tick has something to
      -- read even when discovery is unavailable.
      ctx.discover.register_config_containers()

      -- Guild channels are stable: one listing per connect is enough.
      ctx.discover.discover_guild_channels()

      -- Identity before any DM listing. Two reasons, both load-bearing:
      --   1. `/users/@me/channels` shares its prefix with `/users/@me`, so the
      --      one-tick identity lookup must not race it.
      --   2. A DM peer is identified by skipping the bot among `recipients`,
      --      which is impossible while `state.bot_id` is still unknown.
      get_bot_info(function()
        if not state.is_running then
          return
        end
        ctx.discover.discover_dm_channels()
      end)

      state.timer = uv.new_timer()
      state.timer:start(
        0,
        state.poll_interval,
        vim.schedule_wrap(function()
          tick()
        end)
      )

      log.info('[Discord] Polling started')
    end

    start_polling()
  end

  --------------------------------------------------
  -- Disconnect
  --------------------------------------------------
  local function disconnect()
    -- Invalidate the running chain before anything else: an in-flight fetch
    -- that settles from here on is detached, so it neither processes messages
    -- nor continues to the next container.
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
    state.dm_jobid = nil
    save_state()
    log.info('[Discord] Polling stopped')
  end

  return {
    apply_bot_info = apply_bot_info,
    get_bot_info = get_bot_info,
    is_for_bot = is_for_bot,
    message_text = message_text,
    handle_messages = handle_messages,
    fetch_container = fetch_container,
    poll_tick = poll_tick,
    tick = tick,
    connect = connect,
    disconnect = disconnect,
  }
end

return M

