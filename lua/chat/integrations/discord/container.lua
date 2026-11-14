-- lua/chat/integrations/discord/container.lua
-- Containers (guild channels and DM channels) plus the sessions bound to them.
--
-- A guild channel and a DM channel are both *containers*: the messages endpoint
-- takes `/channels/{id}/messages` for either. What differs is whether an
-- @mention is required, whether the sender must be admitted, and where a reply
-- goes -- those live in poll.lua / send.lua.
--
-- Built per integration instance (`new(ctx)`) so reloading
-- `chat.integrations.discord` starts from fresh state; nothing is shared
-- between two instances.
local log = require('chat.log')
local util = require('chat.integrations.discord.util')

local M = {}

--- @param ctx table shared instance context { state, save_state, M }
--- @return table container API
function M.new(ctx)
  local state = ctx.state

  local function save_state()
    return ctx.save_state()
  end

  local function main_channel_id()
    return util.main_channel_id()
  end

  --- Container record for a channel, created on first use.
  ---
  --- Old state files have no `containers` key: the main one is derived from
  --- config on demand, which keeps single-channel behaviour identical.
  --- @param channel_id string
  --- @param opts? table { chat_type = 'group'|'p2p', peer = string, name = string }
  --- @return table
  local function ensure_container(channel_id, opts)
    local ctr = state.containers[channel_id]
    if not ctr then
      ctr = {
        chat_type = 'group',
        -- No cursor: the first fetch then returns the most recent messages
        -- (limit applied by the caller) and every one of them counts as new.
        -- Unlike Lark there is no time-based start_time to seed, and Discord's
        -- `after` cursor is authoritative, so "no cursor" is the honest value.
        last_message_id = nil,
      }
      state.containers[channel_id] = ctr
      if channel_id == main_channel_id() then
        -- The legacy field mirrors the main container's cursor.
        ctr.last_message_id = state.last_message_id
      end
    end
    if opts then
      if opts.chat_type then
        ctr.chat_type = opts.chat_type
      end
      if opts.peer then
        ctr.peer = opts.peer
      end
      if opts.name then
        ctr.name = opts.name
      end
    end
    return ctr
  end

  --- Per-container message cursor (snowflake id).
  ---
  --- The main container mirrors the legacy `last_message_id` field so a state
  --- file written by an older single-channel build keeps working, and so
  --- `:Chat bridge discord` style setups resume exactly where they left off.
  --- @param channel_id string
  --- @return string|nil
  local function container_cursor(channel_id)
    local ctr = state.containers[channel_id]
    if ctr and ctr.last_message_id then
      return ctr.last_message_id
    end
    if channel_id == main_channel_id() then
      return state.last_message_id
    end
    return nil
  end

  --- Advance a container cursor, keeping the legacy field in sync for the main
  --- container.
  ---
  --- Snowflake ids are ordered numerically as strings only while they have the
  --- same length; Discord ids are all 17-19 digits today, but the comparison
  --- below is length-safe anyway so a shorter id can never win by accident.
  --- @param channel_id string
  --- @param message_id string
  local function advance_cursor(channel_id, message_id)
    if type(message_id) ~= 'string' or message_id == '' then
      return
    end
    local ctr = ensure_container(channel_id)
    local current = ctr.last_message_id
    if current and #current >= #message_id then
      if #current > #message_id or current >= message_id then
        return
      end
    end
    ctr.last_message_id = message_id
    if channel_id == main_channel_id() then
      state.last_message_id = message_id
    end
  end

  --- Chat a session replies to.
  ---
  --- The main container wins when several channels share one session, so a
  --- platform-level `set_session()` (and the HTTP API that relies on it) keeps
  --- addressing the configured `channel_id`.
  --- @param session string|nil
  --- @return string|nil
  local function session_to_chat(session)
    if not session then
      return nil
    end
    local main = main_channel_id()
    local main_ctr = main and state.containers[main]
    if main_ctr and main_ctr.session == session then
      return main
    end
    for channel_id, ctr in pairs(state.containers) do
      if channel_id ~= main and ctr.session == session then
        return channel_id
      end
    end
    return nil
  end

  --- Durable session id owned by a container.
  ---
  --- Derived from the channel id so the same conversation keeps the same
  --- session even when the state file is lost. `sessions.new_with_id()` is
  --- idempotent: an existing session is reused, never overwritten.
  --- @param channel_id string
  --- @return string
  local function container_session_id(channel_id)
    return 'discord-' .. channel_id
  end

  --- Isolated workspace directory for a container, or nil for "inherit".
  ---
  --- A DM channel is one person talking to the bot privately, so two peers must
  --- never share a working directory: they would see each other's files and
  --- git checkout, and one user's edits would land in another's tree. Every DM
  --- therefore gets `<cwd_root>/discord-<channel_id>`.
  ---
  --- Guild channels keep the default (the Neovim cwd): a guild channel is
  --- deliberately a shared workspace, and moving it elsewhere would change
  --- existing behaviour.
  --- @param channel_id string
  --- @param ctr table
  --- @return string|nil
  local function container_cwd(channel_id, ctr)
    if (ctr and ctr.chat_type) ~= 'p2p' then
      return nil
    end
    local root = util.p2p_cwd_root()
    if not root then
      return nil
    end
    return root .. '/discord-' .. util.workspace_dir_name(channel_id)
  end

  --- Whether a binding's session no longer exists.
  ---
  --- A binding can outlive its session: deleting a session removes it from
  --- storage, and `on_session_deleted` clears the bindings the shared layer can
  --- see -- but a state file written before that still points at an id that no
  --- longer exists. Returning it means answering into a dead session: the reply
  --- is written and never delivered, and the chat looks silently broken.
  ---
  --- Only ids this integration derives (`discord-...`) qualify. A binding set by
  --- hand to an unrelated session belongs to the user, not to this module.
  --- @param session string|nil
  --- @return boolean
  local function session_is_stale(session)
    if type(session) ~= 'string' or session == '' then
      return false
    end
    if session:sub(1, 8) ~= 'discord-' then
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
    log.warn('[Discord] Dropped stale binding: ' .. session)
  end

  --- Make sure a container owns a session.
  ---
  --- The main container keeps using the platform session (`state.session`), so
  --- `current_session()` / `set_session()` and everything built on them keep
  --- their meaning. Every other container must own one instead: the shared
  --- layer resolves a message's session through `get_binding()`, and an unbound
  --- container falls back to `current_session()` -- a DM message would then be
  --- answered inside the guild channel's session, and the reply would be
  --- delivered to the configured channel instead of the peer.
  ---
  --- A DM container's session also gets its own working directory (see
  --- `container_cwd`), so two peers never edit the same tree.
  --- @param channel_id string
  --- @param ctr table
  --- @return string|nil
  local function ensure_container_session(channel_id, ctr)
    drop_stale_binding(ctr)
    if ctr.session then
      return ctr.session
    end
    if channel_id == main_channel_id() then
      return state.session
    end

    local cwd = container_cwd(channel_id, ctr)
    if cwd and vim.fn.isdirectory(cwd) == 0 then
      -- The workspace has to exist before tools run in it: `read_file` /
      -- `find_files` reject a missing directory, and git commands fail there
      -- too. One mkdir per channel, done while the session is created.
      pcall(vim.fn.mkdir, cwd, 'p')
      if vim.fn.isdirectory(cwd) == 0 then
        log.warn('[Discord] Could not create workspace ' .. cwd)
        cwd = nil
      end
    end

    local id = require('chat.sessions').new_with_id(
      container_session_id(channel_id),
      cwd
    )
    if not id then
      log.error('[Discord] Failed to create a session for ' .. channel_id)
      return nil
    end

    ctr.session = id
    save_state()
    log.info('[Discord] Bound session ' .. id .. ' to ' .. channel_id)
    return id
  end

  --- Session a channel should talk in, falling back to the platform session.
  ---
  --- Binding happens here (on read) rather than while messages are being
  --- processed: a reply for a channel that never owned a session is impossible
  --- to route afterwards, so the binding must not depend on how far
  --- `handle_messages` got before a filter dropped the message.
  --- @param channel_id string|nil
  --- @return string|nil
  local function chat_session(channel_id)
    if not channel_id then
      return state.session
    end
    local ctr = state.containers[channel_id]
    if ctr then
      return ensure_container_session(channel_id, ctr)
    end
    if channel_id == main_channel_id() then
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
  --- replies and per-channel lookups agree.
  --- @param session string|nil
  local function set_session(session)
    state.session = session
    local main = main_channel_id()
    if main then
      local ctr = ensure_container(main)
      ctr.session = session
    end
    save_state()
  end

  --------------------------------------------------
  -- Bindings
  --------------------------------------------------
  -- Optional methods: the shared layer calls them only when they exist, so the
  -- other integrations keep their exact current behaviour.

  --- Session bound to a channel, creating one on first use.
  --- @param channel_id string|nil
  --- @return string|nil
  local function get_binding(channel_id)
    if not channel_id then
      return nil
    end
    return chat_session(channel_id)
  end

  --- Bind one channel without touching the platform session.
  --- Used by the in-chat `/session` command and by the Neovim picker.
  --- @param channel_id string
  --- @param session string|nil
  --- @return boolean
  local function set_binding(channel_id, session)
    if not channel_id then
      return false
    end
    local ctr = ensure_container(channel_id)
    ctr.session = session
    if channel_id == main_channel_id() then
      state.session = session
    end
    save_state()
    return true
  end

  --- Every session reachable through a binding, main one included.
  --- `on_response` matches against this list, so a reply for a per-channel
  --- binding still finds its integration.
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

  --- Channel ids whose binding points at a session.
  ---
  --- Needed by `chat.bridge`: unbinding a session must clear the per-channel
  --- bindings too, and that requires enumerating them.
  --- @param session string|nil
  --- @return string[]
  local function get_chat_bindings(session)
    local list = {}
    if not session or session_is_stale(session) then
      return list
    end
    if state.session == session and main_channel_id() then
      table.insert(list, main_channel_id())
    end
    for channel_id, ctr in pairs(state.containers) do
      if
        ctr.session == session
        and channel_id ~= main_channel_id()
        and not vim.tbl_contains(list, channel_id)
      then
        table.insert(list, channel_id)
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
  ---
  --- The platform-level pair delegates to the facade's public
  --- `current_session()` / `set_session()` rather than reading `state`
  --- directly. That keeps one source of truth: whatever answers at the module
  --- boundary answers here too, so a caller (or a spec) that substitutes the
  --- platform API is not silently bypassed by this capability table.
  local bridge = {
    --- Platform-level session.
    session = function()
      if ctx.M and ctx.M.current_session then
        return ctx.M.current_session()
      end
      return state.session
    end,

    --- Platform-level setter: keeps the main container in sync, unchanged.
    set_session = function(session)
      if ctx.M and ctx.M.set_session then
        ctx.M.set_session(session)
        return
      end
      set_session(session)
    end,

    --- Session a channel talks in, creating one on first use.
    session_for_chat = function(channel_id)
      if not channel_id then
        return nil
      end
      return chat_session(channel_id)
    end,

    --- Bind one channel without touching the platform session.
    bind_chat = function(channel_id, session)
      if not channel_id then
        return false
      end
      return set_binding(channel_id, session)
    end,

    --- Channel ids bound to a session.
    chats = function(session)
      return get_chat_bindings(session)
    end,

    --- Every session reachable through a binding, main one included.
    --- Listing (`session()`) alone hides every per-DM binding, so anything that
    --- enumerates sessions (the picker) reads this instead.
    sessions = function()
      return get_bound_sessions()
    end,
  }

  --------------------------------------------------
  -- Containers
  --------------------------------------------------
  --- All known containers, sorted by id for stable output (picker list).
  --- @return table[] { chat_id, chat_type, peer, name, session, last_message_id }
  local function get_containers()
    local list = {}
    for channel_id, ctr in pairs(state.containers) do
      table.insert(list, {
        -- `chat_id` is the name the shared layer understands; kept identical
        -- here so a picker can treat Lark and Discord the same way.
        chat_id = channel_id,
        channel_id = channel_id,
        chat_type = ctr.chat_type or 'group',
        peer = ctr.peer,
        name = ctr.name,
        session = ctr.session,
        last_message_id = ctr.last_message_id,
      })
    end
    table.sort(list, function(a, b)
      return a.chat_id < b.chat_id
    end)
    return list
  end

  --- Register a container so the poller starts reading it.
  --- @param channel_id string
  --- @param opts? table { chat_type = 'group'|'p2p', peer = string, name = string }
  --- @return boolean
  local function add_container(channel_id, opts)
    if not channel_id then
      return false
    end
    ensure_container(channel_id, opts)
    save_state()
    return true
  end

  return {
    ensure_container = ensure_container,
    container_cursor = container_cursor,
    advance_cursor = advance_cursor,
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

