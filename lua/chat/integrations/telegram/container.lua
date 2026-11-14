-- lua/chat/integrations/telegram/container.lua
-- Containers (group / channel / private chats) plus the sessions bound to them.
--
-- A Telegram chat is a container in exactly the Lark sense: replies are
-- addressed with `chat_id` for either kind, but what differs is whether an
-- @mention is required (groups: yes, private: no), where the reply goes (same
-- `chat_id` in both cases) and whether the workspace is isolated.
--
-- Built per integration instance (`new(ctx)`) so reloading
-- `chat.integrations.telegram` starts from fresh state; nothing is shared
-- between two instances.
local log = require('chat.log')
local util = require('chat.integrations.telegram.util')

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
  --- Unlike Lark there is no cursor to seed: `getUpdates` is one global
  --- stream, so a chat that shows up for the first time simply becomes known
  --- and is polled by the same request as every other chat.
  --- @param chat_id string
  --- @param opts? table { chat_type = 'group'|'private', peer = string, title = string }
  --- @return table
  local function ensure_container(chat_id, opts)
    local key = util.id_to_string(chat_id)
    if not key then
      return nil
    end

    local ctr = state.containers[key]
    if not ctr then
      ctr = { chat_type = 'group' }
      state.containers[key] = ctr
    end
    if opts then
      if opts.chat_type then
        ctr.chat_type = opts.chat_type
      end
      if opts.peer then
        ctr.peer = util.id_to_string(opts.peer)
      end
      if opts.title then
        ctr.title = opts.title
      end
    end
    return ctr
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
    return 'telegram-' .. util.workspace_dir_name(chat_id)
  end

  --- Isolated workspace directory for a container, or nil for "inherit".
  ---
  --- A private chat is one person talking to the bot privately, so two users
  --- must never share a working directory: they would see each other's files
  --- and git checkout, and one user's edits would land in another's tree.
  --- Every private chat therefore gets `<cwd_root>/telegram-<chat_id>`.
  ---
  --- Groups keep the default (the Neovim cwd): a group is deliberately a shared
  --- workspace, and moving it elsewhere would change existing behaviour.
  ---
  --- Returns nil when no root is configured (no `p2p.cwd_root` and no
  --- `allowed_path`), because a workspace outside `allowed_path` would make
  --- every file tool refuse the directory -- worse than no isolation at all.
  --- @param chat_id string
  --- @param ctr table
  --- @return string|nil
  local function container_cwd(chat_id, ctr)
    if (ctr and ctr.chat_type) ~= 'private' then
      return nil
    end
    local root = util.p2p_cwd_root()
    if not root then
      return nil
    end
    return root .. '/telegram-' .. util.workspace_dir_name(chat_id)
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
  --- Only ids this integration derives (`telegram-…`) qualify. A binding set
  --- by hand to an unrelated session belongs to the user, not to this module.
  --- @param session string|nil
  --- @return boolean
  local function session_is_stale(session)
    if type(session) ~= 'string' or session == '' then
      return false
    end
    if session:sub(1, 9) ~= 'telegram-' then
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
    log.warn('[Telegram] Dropped stale binding: ' .. session)
  end

  --- Make sure a container owns a session.
  ---
  --- The main container keeps using the platform session (`state.session`), so
  --- `current_session()` / `set_session()` and everything built on them keep
  --- their meaning. Every other container must own one instead: the shared
  --- layer resolves a message's session through `get_binding()`, and an unbound
  --- container falls back to `current_session()` — a private message would then
  --- be answered inside the group's session, and the reply would be delivered
  --- to the configured group instead of the user.
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

    local cwd = container_cwd(chat_id, ctr)
    if cwd and vim.fn.isdirectory(cwd) == 0 then
      -- The workspace has to exist before tools run in it: `read_file` /
      -- `find_files` reject a missing directory, and git commands fail there
      -- too. One mkdir per chat, done while the session is created.
      pcall(vim.fn.mkdir, cwd, 'p')
      if vim.fn.isdirectory(cwd) == 0 then
        log.warn('[Telegram] Could not create workspace ' .. cwd)
        cwd = nil
      end
    end

    local id = require('chat.sessions').new_with_id(
      container_session_id(chat_id),
      cwd
    )
    if not id then
      log.error('[Telegram] Failed to create a session for ' .. chat_id)
      return nil
    end

    ctr.session = id
    save_state()
    log.info('[Telegram] Bound session ' .. id .. ' to ' .. chat_id)
    return id
  end

  --- Look up an existing container without creating one.
  ---
  --- Routing needs to know the peer a private chat was registered with *before*
  --- it re-registers the chat: `ensure_container()` overwrites `peer` with the
  --- current sender, so comparing after that would compare a value with itself.
  --- @param chat_id string
  --- @return table|nil
  local function get_container(chat_id)
    local key = util.id_to_string(chat_id)
    if not key then
      return nil
    end
    return state.containers[key]
  end

  --- Session a chat should talk in, falling back to the platform session.
  ---
  --- Binding happens here (on read) rather than while messages are being
  --- processed: a reply for a chat that never owned a session is impossible to
  --- route afterwards, so the binding must not depend on how far
  --- `handle_message` got before a filter dropped the message.
  --- @param chat_id string|nil
  --- @return string|nil
  local function chat_session(chat_id)
    local key = util.id_to_string(chat_id)
    if not key then
      return state.session
    end
    local ctr = state.containers[key]
    if ctr then
      return ensure_container_session(key, ctr)
    end
    if key == main_chat_id() then
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
      if ctr then
        ctr.session = session
      end
    end
    save_state()
  end

  --------------------------------------------------
  -- Bindings
  --------------------------------------------------
  -- Optional methods: the shared layer calls them only when they exist.

  --- Session bound to a chat, creating one on first use.
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
    local ctr = chat_id and ensure_container(chat_id) or nil
    if not ctr then
      return false
    end
    ctr.session = session
    if util.id_to_string(chat_id) == main_chat_id() then
      state.session = session
    end
    save_state()
    return true
  end

  --- Every session reachable through a binding, main one included.
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
  --- @param session string|nil
  --- @return string[]
  local function get_chat_bindings(session)
    local list = {}
    if not session or session_is_stale(session) then
      return list
    end
    local main = main_chat_id()
    if state.session == session and main then
      table.insert(list, main)
    end
    for chat_id, ctr in pairs(state.containers) do
      if ctr.session == session and chat_id ~= main then
        table.insert(list, chat_id)
      end
    end
    table.sort(list)
    return list
  end

  --- Bridge capabilities consumed by `chat.bridge`.
  local bridge = {
    session = function()
      return state.session
    end,

    set_session = function(session)
      set_session(session)
    end,

    session_for_chat = function(chat_id)
      if not chat_id then
        return nil
      end
      return chat_session(chat_id)
    end,

    bind_chat = function(chat_id, session)
      if not chat_id then
        return false
      end
      return set_binding(chat_id, session)
    end,

    chats = function(session)
      return get_chat_bindings(session)
    end,

    sessions = function()
      return get_bound_sessions()
    end,
  }

  --------------------------------------------------
  -- Containers
  --------------------------------------------------
  --- All known containers, sorted by id for stable output (picker list).
  --- @return table[] { chat_id, chat_type, peer, title, session, last_seen_time }
  local function get_containers()
    local list = {}
    for chat_id, ctr in pairs(state.containers) do
      table.insert(list, {
        chat_id = chat_id,
        chat_type = ctr.chat_type or 'group',
        peer = ctr.peer,
        title = ctr.title,
        session = ctr.session,
        last_seen_time = ctr.last_seen_time,
      })
    end
    table.sort(list, function(a, b)
      return a.chat_id < b.chat_id
    end)
    return list
  end

  --- Register a container so replies can be routed to it.
  ---
  --- Unlike Lark this is not what makes polling happen (getUpdates is one
  --- global stream), it only records the chat type / peer so routing and the
  --- @mention rule know what kind of chat it is.
  --- @param chat_id string
  --- @param opts? table { chat_type = 'group'|'private', peer = string, title = string }
  --- @return boolean
  local function add_container(chat_id, opts)
    if not util.id_to_string(chat_id) then
      return false
    end
    ensure_container(chat_id, opts)
    save_state()
    return true
  end

  return {
    ensure_container = ensure_container,
    get_container = get_container,
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

