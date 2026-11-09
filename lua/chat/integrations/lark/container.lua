-- lua/chat/integrations/lark/container.lua
-- Containers (group and p2p chats) plus the sessions bound to them.
--
-- A group and a p2p conversation are both *containers*: the messages endpoint
-- takes `container_id_type=chat&container_id=oc_...` for either. What differs
-- is which cursor is used, whether an @mention is required, and where a reply
-- goes (p2p: the peer's open_id) -- those live in poll.lua / send.lua.
--
-- Built per integration instance (`new(ctx)`) so reloading
-- `chat.integrations.lark` starts from fresh state; nothing is shared between
-- two instances.
local log = require('chat.log')
local util = require('chat.integrations.lark.util')

local M = {}

--- @param ctx table shared instance context { state, save_state, M }
--- @return table container API
function M.new(ctx)
  local state = ctx.state

  local function save_state()
    return ctx.save_state()
  end

  local function main_chat_id()
    return util.main_chat_id()
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

    local id =
      require('chat.sessions').new_with_id(container_session_id(chat_id))
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

  --------------------------------------------------
  -- Session management (platform level: meaning unchanged)
  --------------------------------------------------
  local function current_session()
    return state.session
  end

  --- Bind the platform session.
  ---
  --- `current_session()` stays the single value that `unbridge`, the HTTP routes
  --- and the window title rely on; the main container binding is kept in sync so
  --- replies and per-chat lookups agree.
  --- @param session string|nil
  local function set_session(session)
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
  local function get_binding(chat_id)
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
  local function set_binding(chat_id, session)
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
  local function get_bound_sessions()
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
  local function get_chat_bindings(session)
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
  local bridge = {
    --- Platform-level session.
    session = function()
      return state.session
    end,

    --- Platform-level setter: keeps the main container in sync, unchanged.
    set_session = function(session)
      set_session(session)
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
      return set_binding(chat_id, session)
    end,

    --- Chat ids bound to a session.
    chats = function(session)
      return get_chat_bindings(session)
    end,
  }

  --------------------------------------------------
  -- Containers
  --------------------------------------------------
  --- All known containers, sorted by id for stable output (picker list).
  --- @return table[] { chat_id, chat_type, peer, session, last_seen_time }
  local function get_containers()
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
  local function add_container(chat_id, opts)
    if not chat_id then
      return false
    end
    ensure_container(chat_id, opts)
    save_state()
    return true
  end

  return {
    ensure_container = ensure_container,
    container_cursor = container_cursor,
    set_container_cursor = set_container_cursor,
    session_to_chat = session_to_chat,
    container_session_id = container_session_id,
    session_is_stale = session_is_stale,
    ensure_container_session = ensure_container_session,
    chat_session = chat_session,
    current_session = current_session,
    set_session = set_session,
    get_binding = get_binding,
    set_binding = set_binding,
    get_bound_sessions = get_bound_sessions,
    get_chat_bindings = get_chat_bindings,
    bridge = bridge,
    get_containers = get_containers,
    add_container = add_container,
  }
end

return M

