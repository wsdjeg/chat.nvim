-- lua/chat/integrations/lark/poll.lua
-- Inbound side: bot identity, message filtering, per-container fetch and the
-- polling loop.
--
-- Every container is read with one sequential request per tick (`done()` fires
-- exactly once per fetch), so a slow chat can not starve the others and the
-- rate limit is never raced.
local log = require('chat.log')
local job = require('job')
local curl = require('chat.curl')
local auth = require('chat.integrations.lark.auth')
local util = require('chat.integrations.lark.util')

local json = vim.json
local uv = vim.uv

local M = {}

--- @param ctx table shared instance context
--- @return table poll API
function M.new(ctx)
  local state = ctx.state
  local API_BASE = util.API_BASE

  -- Chain owner id. Bumped by disconnect(), so a request that settles
  -- afterwards can tell it no longer belongs to the chain that started it.
  local poll_generation = 0

  local function save_state()
    return ctx.save_state()
  end

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

    local changed = state.bot_id ~= bot.open_id
      or state.bot_name ~= bot.app_name
    state.bot_id = bot.open_id
    -- `app_name` is the display name a mention carries when the open_id lookup
    -- is not usable yet; see is_mention_bot().
    state.bot_name = bot.app_name or bot.name or state.bot_name
    log.info(
      '[Lark] Bot ID: ' .. state.bot_id .. ' (' .. tostring(state.bot_name) .. ')'
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
        '[Lark] API error [' .. result.code .. ']: '
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

    local ctr = ctx.container.ensure_container(chat_id)
    local has_new = false
    local latest_time = ctx.container.container_cursor(chat_id) or '0'

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
      ctx.acl.record_sender(msg)

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
        content = ctx.acl.strip_leading_mentions(content)
      end

      if content == '' then
        goto continue
      end

      local sender_id = msg.sender and msg.sender.id or nil

      -- p2p has its own default-deny policy: `acl.mode = allow_all` would
      -- otherwise let anyone in the tenant open a DM with the bot.
      if ctr.chat_type == 'p2p' then
        local peer = ctr.peer or sender_id
        if not ctx.acl.is_p2p_allowed(peer) then
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

      local sender_is_admin = ctx.acl.is_admin(sender_id)

      -- ACL: admins always pass, so they can recover a whitelist that
      -- locked them out of management commands.
      if not sender_is_admin and not ctx.acl.is_allowed(sender_id) then
        log.debug(
          '[Lark] Skip message (sender not allowed): ' .. (sender_id or '?')
        )
        goto continue
      end

      -- In-chat ACL management: must run before the shared handler so
      -- `/allow` never reaches the LLM as a normal prompt.
      local acl_command = ctx.acl.parse_acl_command(content)
      if acl_command then
        ctx.acl.handle_acl_command(msg, acl_command, chat_id)
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
      ctx.container.set_container_cursor(chat_id, latest_time)
      log.debug('[Lark] Updated cursor for ' .. chat_id .. ': ' .. latest_time)
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
  --- stopped poller would still answer, run `/allow`, advance cursors and write
  --- the state file.
  --- @param generation integer chain that started the fetch
  --- @return boolean
  local function is_current_chain(generation)
    return state.is_running and generation == poll_generation
  end

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
  --- @param generation? integer chain the fetch belongs to (default: current)
  local function fetch_container(chat_id, done, generation)
    generation = generation or poll_generation
    local cursor = ctx.container.container_cursor(chat_id)

    ensure_token(function(token, err)
      -- Token resolution is asynchronous: disconnect() may have run while it
      -- was in flight, and starting a request now would keep a stopped poller
      -- reading containers.
      if not is_current_chain(generation) then
        done()
        return
      end

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
          if is_current_chain(generation) then
            local ok, err2 =
              pcall(handle_messages, chat_id, table.concat(response_chunks))
            if not ok then
              log.error('[Lark] Message handling failed: ' .. tostring(err2))
            end
          else
            log.debug('[Lark] Drop response (' .. chat_id .. '): poll stopped')
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
      local main = util.main_chat_id()
      if not main then
        log.error('[Lark] chat_id not configured')
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
        log.debug('[Lark] Poll chain stopped: poller no longer running')
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

  --------------------------------------------------
  -- Connect
  --------------------------------------------------
  local function connect(callback)
    local lark_cfg = util.lark_config()
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

    ctx.state_io.load()

    -- The cached cursors describe where the *previous* run stopped. Replaying
    -- them on start would fetch and answer everything sent while the plugin was
    -- down, so every container resumes from "now" instead.
    ctx.state_io.reset_cursors_to_now()
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
      ctx.p2p.provision_p2p()
    end

    -- Resolve email / mobile ACL entries before the first poll: until the map
    -- is settled those entries match nothing, so an email-configured admin
    -- would be locked out during the lookup window. open_id-only configs cost
    -- zero requests and this callback fires immediately.
    ctx.acl.resolve_acl(function()
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
    save_state()
    log.info('[Lark] Polling stopped')
  end

  return {
    apply_bot_info = apply_bot_info,
    get_bot_info = get_bot_info,
    is_mention_bot = is_mention_bot,
    handle_messages = handle_messages,
    fetch_container = fetch_container,
    poll_tick = poll_tick,
    connect = connect,
    disconnect = disconnect,
  }
end

return M

