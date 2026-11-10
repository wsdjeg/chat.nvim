local M = {}

local log = require('chat.log')
local bridge = require('chat.bridge')

-- 集成模块表
local integrations = {
  discord = require('chat.integrations.discord'),
  lark = require('chat.integrations.lark'),
  dingtalk = require('chat.integrations.dingtalk'),
  wecom = require('chat.integrations.wecom'),
  telegram = require('chat.integrations.telegram'),
  weixin = require('chat.integrations.weixin'),
  slack = require('chat.integrations.slack'),
}

-- Typing timers per integration name
local typing_timers = {} -- { [name] = uv_timer }

-- Sessions rendered per `/list` page. The numbering is global (page 2 starts
-- at 11), so a number always maps to the same session whatever page it was
-- read on, and `/session N` works for sessions never rendered on page 1.
local PAGE_SIZE = 10

---@class ChatIntegrationMessage
---@field content string message content
---@field session string session ID

-- Helper: build a human-readable session summary
local function format_session_summary(session_id)
  local sessions = require('chat.sessions')
  local data = sessions.get()[session_id]
  if not data then
    return session_id
  end

  -- Title: stored title > first user message > untitled
  local title = sessions.get_session_title(session_id) or ''
  if title == '' then
    local messages = data.messages or {}
    for _, msg in ipairs(messages) do
      if msg.role == 'user' then
        title = vim.split(msg.content or '', '\n')[1]
        break
      end
    end
  end
  if title == '' then
    title = '(untitled)'
  end
  if #title > 50 then
    title = vim.fn.strcharpart(title, 0, 47) .. '...'
  end

  local provider = data.provider or 'default'
  local model = data.model or 'default'
  local message_count = #(data.messages or {})
  local pin = sessions.get_session_pin(session_id)
  local pin_marker = pin and '📌 ' or ''

  return string.format(
    '%s%s\n  ID: %s\n  Provider: %s\n  Model: %s\n  Messages: %d',
    pin_marker,
    title,
    session_id,
    provider,
    model,
    message_count
  )
end

--- Session a message belongs to.
---
--- Delegated to the bridge facade so routing has exactly one source: a
--- platform that can address one chat (currently Lark) answers per chat, every
--- other platform answers with its platform-level session, unchanged.
--- @param name string platform name
--- @param message table
--- @return string|nil
local function resolve_session(name, message)
  return bridge.session_for(name, message and message.chat_id)
end

--- Send a reply back to the chat the message came from.
---
--- The session doubles as the routing hint: Lark's `send_message(content,
--- session)` resolves which chat to answer, the other platforms take the
--- single argument and ignore the second.
--- @param name string platform name
--- @param integration table
--- @param message table
--- @param text string
local function reply(name, integration, message, text)
  integration.send_message(text, resolve_session(name, message))
end

--- Bind a session to the chat the command came from.
---
--- Platforms that can address one chat bind that chat only; the platform-level
--- setter stays in use everywhere else.
--- @param name string platform name
--- @param message table
--- @param session string|nil
local function bind_session(name, message, session)
  if message and message.chat_id and bridge.supports_chat(name) then
    bridge.bind_chat(name, message.chat_id, session)
    return
  end
  if session then
    bridge.bind(name, session)
  else
    local caps = bridge.caps(name)
    if caps then
      caps.set_session(nil)
    end
  end
end

--- Slot key of the `/list` numbering a message is reading.
---
--- A single integration can serve several chats at once (one Lark bot in two
--- groups), so the published list is kept per chat: two people running
--- `/list` must not overwrite each other's `/session <n>` numbering.
--- @param message table
--- @return string
local function list_slot_key(message)
  return (message and message.chat_id) or 'default'
end

--- Session ids the last `/list` of this chat published.
--- @param integration table
--- @param message table
--- @return string[]|nil
local function session_slot(integration, message)
  local slots = integration._session_lists
  return slots and slots[list_slot_key(message)]
end

--- Publish the numbering `/session <number>` binds by.
--- @param integration table
--- @param message table
--- @param ids string[]
local function store_session_slot(integration, message, ids)
  integration._session_lists = integration._session_lists or {}
  integration._session_lists[list_slot_key(message)] = ids
end

-- Helper: parse and execute /session command
local function handle_session_command(name, integration, message)
  local arg = message.content:match('^/session%s+(.+)$')

  if not arg then
    -- /session without args: bind to current window session
    local windows = require('chat.windows')
    if not windows.current_session() then
      reply(name, integration, message, 'No window session.')
    else
      local sid = windows.current_session()
      bind_session(name, message, sid)
      reply(
        name,
        integration,
        message,
        'Session bound:\n  ' .. format_session_summary(sid)
      )
    end
    return
  end

  -- Try to parse as number
  local num = tonumber(arg)
  if num then
    -- Bind by index. The list is the last `/list` of *this* chat, so the
    -- number means the same session for the person who read it.
    local session_list = session_slot(integration, message)
    if session_list and session_list[num] then
      local session_id = session_list[num]
      bind_session(name, message, session_id)
      reply(
        name,
        integration,
        message,
        string.format(
          -- `#11` echoes the number the list printed (`11. title`) without
          -- repeating markdown list syntax inside a plain confirmation line.
          'Session bound: #%d\n  %s',
          num,
          format_session_summary(session_id)
        )
      )
    else
      reply(
        name,
        integration,
        message,
        'Invalid session number. Use /list to see available sessions.'
      )
    end
  else
    -- Bind by session_id
    local sessions = require('chat.sessions')
    if sessions.exists(arg) then
      bind_session(name, message, arg)
      reply(
        name,
        integration,
        message,
        'Session bound:\n  ' .. format_session_summary(arg)
      )
    else
      reply(name, integration, message, 'Session not found: ' .. arg)
    end
  end
end

--- Parse `/list` arguments into a search pattern and a page number.
---
--- `-p N` is a flag instead of a bare number because session ids are
--- date-shaped strings full of digits: `/list 2` would be ambiguous between
--- "page 2" and "search for 2".
--- @param rest string|nil everything after `/list`
--- @return string|nil pattern
--- @return integer page
local function parse_list_args(rest)
  local page = 1
  local text = vim.trim(rest or '')
  local stripped = text:gsub('%-p%s*(%d+)', function(n)
    page = tonumber(n) or 1
    return ' '
  end)
  text = vim.trim(stripped)
  if text == '' then
    text = nil
  end
  return text, math.max(page, 1)
end

--- Rebuild the `/list` command for a page, so the footer is copy-pasteable.
--- @param pattern string|nil
--- @param page integer
--- @return string
local function list_command(pattern, page)
  if pattern then
    return string.format('/list %s -p %d', pattern, page)
  end
  return string.format('/list -p %d', page)
end

-- Helper: list sessions with optional filter and page
local function handle_list_command(name, integration, message)
  log.debug('[Integration] handle_list_command called')
  local pattern, page = parse_list_args(message.content:match('^/list%s*(.*)$'))
  local sessions = require('chat.sessions')
  local all_sessions = sessions.get()
  local current = resolve_session(name, message)

  log.debug(
    string.format(
      '[Integration] pattern: %s, page: %d, current: %s, sessions count: %d',
      pattern or 'nil',
      page,
      current or 'nil',
      vim.tbl_count(all_sessions)
    )
  )

  -- Sort sessions: pinned first, then by last message time (newest first)
  local sorted = {}
  for id, session in pairs(all_sessions) do
    -- Determine last activity time:
    -- 1. Last message's created timestamp
    -- 2. last_user_message_time field
    local last_time = 0
    if session.messages and #session.messages > 0 then
      local last_msg = session.messages[#session.messages]
      last_time = last_msg.created or session.last_user_message_time or 0
    elseif session.last_user_message_time then
      last_time = session.last_user_message_time
    end
    -- A session without messages keeps last_time = 0; the id comparison at
    -- the end of the sort makes such sessions still order deterministically.
    local pin = sessions.get_session_pin(id) or false
    table.insert(sorted, {
      id = id,
      session = session,
      pin = pin,
      last_time = last_time,
    })
  end
  table.sort(sorted, function(a, b)
    if a.pin ~= b.pin then
      return a.pin  -- pinned first
    end
    -- Same pin status: sort by last_time descending (newest first)
    if a.last_time ~= b.last_time then
      return a.last_time > b.last_time
    end
    -- Fallback: sort by id descending
    return a.id > b.id
  end)
  -- Filter by pattern if provided
  local needle = pattern and pattern:lower() or nil
  local filtered = {}
  for _, item in ipairs(sorted) do
    if not needle then
      table.insert(filtered, item)
    else
      -- Get title for search
      local title = sessions.get_session_title(item.id) or ''
      local first_msg = ''
      if item.session.messages and #item.session.messages > 0 then
        first_msg = item.session.messages[1].content or ''
      end

      -- Match against id, title, provider, model, and first message
      local search_str = string.format(
        '%s %s %s %s %s',
        item.id,
        title,
        item.session.provider or '',
        item.session.model or '',
        first_msg
      )
      -- Plain find, not `string.match`: a title may contain `+`, `(`, `%` or
      -- any other pattern character, and matching it as a Lua pattern either
      -- raises "invalid pattern" or silently matches something else.
      if search_str:lower():find(needle, 1, true) then
        table.insert(filtered, item)
      end
    end
  end

  -- Publish the whole filtered list, not only the rendered page: numbering is
  -- global, so `12` stays valid while page 1 is on screen.
  local ids = {}
  for _, item in ipairs(filtered) do
    table.insert(ids, item.id)
  end
  store_session_slot(integration, message, ids)

  -- Build output as a markdown ordered list.
  --
  -- The numbers are written literally (`11.`), not regenerated per page: a
  -- renderer that honours the start value keeps the global numbering, so page
  -- 2 still reads 11, 12, ... instead of restarting at 1. The blank lines
  -- matter — without them markdown folds the trailing `Total:` line into the
  -- last list item.
  local lines = pattern
      and { string.format('Sessions matching "%s":', pattern) }
    or { 'Available sessions:' }

  if #filtered == 0 then
    table.insert(lines, pattern and 'No matches found' or 'No sessions available')
  else
    local total_pages = math.ceil(#filtered / PAGE_SIZE)
    if page > total_pages then
      reply(
        name,
        integration,
        message,
        string.format(
          'No page %d: %d session(s) fit in %d page(s).',
          page,
          #filtered,
          total_pages
        )
      )
      return
    end

    table.insert(lines, '')
    local first = (page - 1) * PAGE_SIZE + 1
    local last = math.min(first + PAGE_SIZE - 1, #filtered)
    for index = first, last do
      local item = filtered[index]
      local marker = (item.id == current) and ' ✓' or ''
      local pin_marker = item.pin and '📌 ' or ''

      -- Get title: prefer session title, fallback to first message
      local title = sessions.get_session_title(item.id) or ''
      if title == '' and item.session.messages and #item.session.messages > 0 then
        local first_msg = item.session.messages[1].content or ''
        title = vim.split(first_msg, '\n')[1]
      end
      if title == '' then
        title = '(untitled)'
      end
      -- Truncate if too long
      if #title > 40 then
        title = vim.fn.strcharpart(title, 0, 37) .. '...'
      end

      table.insert(
        lines,
        string.format('%d. %s%s%s', index, pin_marker, title, marker)
      )
    end

    table.insert(lines, '')
    table.insert(lines, string.format('Total: %d session(s)', #filtered))

    local nav = {}
    if page > 1 then
      table.insert(nav, 'prev: ' .. list_command(pattern, page - 1))
    end
    if page < total_pages then
      table.insert(nav, 'next: ' .. list_command(pattern, page + 1))
    end
    local footer = string.format('Page %d/%d', page, total_pages)
    if #nav > 0 then
      footer = footer .. ' · ' .. table.concat(nav, ' · ')
    end
    table.insert(lines, footer)
    table.insert(lines, '')
  end

  local message_content = table.concat(lines, '\n')
  log.debug(
    string.format(
      '[Integration] Sending list message (%d bytes)',
      #message_content
    )
  )
  reply(name, integration, message, message_content)
end

-- Stop existing typing timer for an integration
local function stop_typing_timer(name)
  local timer = typing_timers[name]
  if timer then
    timer:stop()
    timer:close()
    typing_timers[name] = nil
    log.debug(string.format('[%s] Typing timer stopped', name))
  end
end

-- Start a typing timer that sends typing every 8 seconds while session is in progress
local function start_typing_timer(integration, name, session)
  -- Stop any existing timer for this integration
  stop_typing_timer(name)

  local sessions = require('chat.sessions')

  -- Discord 特殊处理：发送 typing 指示器
  if integration.send_typing then
    integration.send_typing(true)
  end

  -- Only start timer if integration supports send_typing
  if not integration.send_typing then
    return
  end

  local timer = assert(vim.uv.new_timer())
  typing_timers[name] = timer

  timer:start(8000, 8000, function()
    -- Check if session is still in progress
    if sessions.is_in_progress(session) then
      vim.schedule(function()
        integration.send_typing(true)
        log.debug(string.format('[%s] Typing indicator sent', name))
      end)
    else
      -- Session finished, stop timer
      vim.schedule(function()
        stop_typing_timer(name)
      end)
    end
  end)

  log.debug(string.format('[%s] Typing timer started for session %s', name, session))
end

-- 通用的消息处理函数
local function handle_message(integration, name, callback)
  return function(message)
    log.debug(string.format('[%s] %s', name, message.content))

    -- 处理命令
    if message.content:match('^/session%s*') then
      handle_session_command(name, integration, message)
      return
    elseif
      message.content:match('^/list%s*') or message.content == '/list'
    then
      handle_list_command(name, integration, message)
      return
    elseif message.content == '/clear' then
      local sessions = require('chat.sessions')
      local session = resolve_session(name, message)
      if session and not sessions.is_in_progress(session) then
        sessions.clear(session)
        reply(name, integration, message, 'Session messages cleared!')
      end
      return
    elseif message.content == '/status' then
      local sessions = require('chat.sessions')
      local session = resolve_session(name, message)
      if session then
        local provider = sessions.get_session_provider(session) or 'default'
        local model = sessions.get_session_model(session) or 'default'
        local cwd = sessions.getcwd(session) or vim.fn.getcwd()
        local in_progress = sessions.is_in_progress(session)
        local status = string.format(
          'Session: %s\nProvider: %s\nModel: %s\nCWD: %s\nStatus: %s',
          session,
          provider,
          model,
          cwd,
          in_progress and 'Processing' or 'Idle'
        )
        reply(name, integration, message, status)
      else
        reply(
          name,
          integration,
          message,
          'No active session. Use /session to bind a session.'
        )
      end
      return
    end

    -- 正常消息
    local session = resolve_session(name, message)
    if session then
      -- Start typing timer (sends initial typing + repeats every 8s)
      start_typing_timer(integration, name, session)

      callback({
        session = session,
        content = message.content,
      })
    end
  end
end

---@param callback fun(message:ChatIntegrationMessage)
function M.on_message(callback)
  for name, integration in pairs(integrations) do
    integration.connect(handle_message(integration, name, callback))
  end
end

---@param session string session ID
---@param content string message content
function M.on_response(session, content)
  if not content or type(content) ~= 'string' or content:match('^%s*$') then
    return
  end

  -- Single source of truth: a session is bridged to whatever `bridge.list`
  -- returns, so a reply for a per-chat binding is delivered while a session
  -- that only *used* to be bound is not.
  for _, name in ipairs(bridge.list(session)) do
    local integration = integrations[name]
    if integration then
      if session == bridge.session(name) then
        -- Platform-level binding: address the configured chat, unchanged.
        integration.send_message(content)
      else
        -- Bound to a specific chat: the reply is addressed back to that chat.
        integration.send_message(content, session)
      end
    end
  end
end

--- Bridge a platform to a session (`:Chat bridge <platform>`).
---
--- One return contract for both callers (`:Chat bridge` and `PUT
--- /session/:id/bridge`), so the two entry points report the same thing:
---   `true`  bound
---   `false` unknown platform (the caller may list `list_platforms()`)
---   `nil`   nothing to bind (no session supplied)
--- @param platform string platform name
--- @param session string|nil
--- @return boolean|nil
function M.set_session(platform, session)
  local integration = integrations[platform]
  if not integration then
    return false
  end
  if not session then
    return nil
  end
  return bridge.bind(platform, session) == true
end

function M.unbridge(name)
  local windows = require('chat.windows')
  local current_session = windows.current_session()
  if not current_session then
    return false
  end

  if name then
    local integration = integrations[name]
    if not integration then
      return false   -- integration doesn't exist
    end
    -- Both levels are cleared, so a per-chat binding cannot survive the call
    -- that reported the session as unbridged.
    if bridge.unbind(name, current_session) == 0 then
      return nil     -- exists but not bound to current session
    end
    stop_typing_timer(name)
    integration.disconnect()
    return true
  end

  -- Unbind every platform bridged to the current session.
  local unbound = 0
  for _, platform in ipairs(bridge.list(current_session)) do
    local integration = integrations[platform]
    if integration then
      unbound = unbound + bridge.unbind(platform, current_session)
      stop_typing_timer(platform)
      integration.disconnect()
    end
  end
  return unbound > 0
end

--- Unbridge integrations by session_id (for HTTP API use)
--- @param session_id string session ID
--- @param name? string optional integration name, nil to unbridge all
--- @return boolean|nil true if unbridged, false if integration not found, nil if not bound
function M.unbridge_session(session_id, name)
  if name then
    local integration = integrations[name]
    if not integration then
      return false
    end
    if bridge.unbind(name, session_id) == 0 then
      return nil
    end
    stop_typing_timer(name)
    integration.disconnect()
    return true
  end

  local unbound = 0
  for _, platform in ipairs(bridge.list(session_id)) do
    local integration = integrations[platform]
    if integration then
      unbound = unbound + bridge.unbind(platform, session_id)
      stop_typing_timer(platform)
      integration.disconnect()
    end
  end
  return unbound > 0
end

--- List all available integration platform names
--- @return string[] sorted list of platform names
function M.list_platforms()
  local names = {}
  for name in pairs(integrations) do
    table.insert(names, name)
  end
  table.sort(names)
  return names
end

--- Integration module behind a platform name.
--- @param name string
--- @return table|nil
function M.platform(name)
  return integrations[name]
end

function M.on_session_deleted(session)
  for _, platform in ipairs(bridge.list(session)) do
    local integration = integrations[platform]
    if integration then
      bridge.unbind(platform, session)
      stop_typing_timer(platform)
      integration.disconnect()
    end
  end
end

--- Platforms a session is bridged to, including per-chat bindings.
--- @param session string session ID
--- @return string[]
function M.get_integrations(session)
  return bridge.list(session)
end

return M

