--- Chat <-> session bridging facade.
---
--- Every place that answers "is this session bridged to platform X?" or "which
--- chat does this session reply to?" goes through this module. The platforms
--- own the storage (`state.session`, `containers[].session` for Lark), this
--- module owns the questions.
---
--- The reason it exists: `bridge` / `unbridge` / `on_response` /
--- `get_integrations` used to answer that question with three different
--- implementations, so a half-unbind (`unbridge` clearing the platform session
--- but leaving per-chat bindings) went unnoticed while the title bar and the
--- HTTP API reported the integration as gone.
local M = {}

local log = require('chat.log')

--- Members a platform must declare in `integration.bridge`.
---
--- Checked eagerly instead of relied upon implicitly: a platform that can bind
--- a chat but cannot enumerate its chats would silently half-unbind.
local REQUIRED = {
  'session', -- fun(): string|nil           platform-level session
  'set_session', -- fun(session: string|nil) platform-level setter
  'session_for_chat', -- fun(chat_id): string|nil
  'bind_chat', -- fun(chat_id, session|nil): boolean
  'chats', -- fun(session): string[]        chat ids bound to that session
}

-- Optional members, used when present:
--   sessions -- fun(): string[]  every session this platform can reach,
--                               per-chat bindings included. Platforms without
--                               it are listed as their platform session only.

--- Lazy require: `chat.integrations` loads every platform, so requiring it at
--- module load time would create a cycle through the platforms themselves.
local function ims()
  return require('chat.integrations')
end

--- Capability set for a platform without per-chat bindings.
---
--- Every integration implements `current_session` / `set_session`, so
--- platform-level bridging keeps working exactly as before.
--- @param integration table
--- @return table
local function platform_only(integration)
  return {
    session = function()
      return integration.current_session()
    end,
    set_session = function(session)
      integration.set_session(session)
    end,
    session_for_chat = nil,
    bind_chat = nil,
    chats = function()
      return {}
    end,
  }
end

--- Bridge capabilities of a platform.
--- @param name string
--- @return table|nil nil when the platform is unknown
function M.caps(name)
  local integration = ims().platform(name)
  if not integration then
    return nil
  end
  if integration.bridge then
    for _, key in ipairs(REQUIRED) do
      if type(integration.bridge[key]) ~= 'function' then
        error(string.format('[bridge] %s.bridge is missing %s()', name, key))
      end
    end
    return integration.bridge
  end
  return platform_only(integration)
end

--- Whether a platform supports binding a single chat.
--- @param name string
--- @return boolean
function M.supports_chat(name)
  local c = M.caps(name)
  return c ~= nil and c.bind_chat ~= nil
end

--- Platform-level session of a platform.
--- @param name string
--- @return string|nil
function M.session(name)
  local c = M.caps(name)
  if not c then
    return nil
  end
  return c.session()
end

--- Session a chat talks in, falling back to the platform session.
---
--- A platform that cannot address one chat answers with its platform session,
--- which is exactly what the shared layer used to read directly.
--- @param name string
--- @param chat_id string|nil
--- @return string|nil
function M.session_for(name, chat_id)
  local c = M.caps(name)
  if not c then
    return nil
  end
  if not chat_id or not c.session_for_chat then
    return c.session()
  end
  return c.session_for_chat(chat_id)
end

--- Chat ids bound to a session.
--- @param name string
--- @param session string|nil
--- @return string[]
function M.chats(name, session)
  local c = M.caps(name)
  if not c or not session then
    return {}
  end
  return c.chats(session) or {}
end

--- Every session a platform can reach, per-chat bindings included.
---
--- The platform-level session and the chats bound to their own sessions are
--- both answers to "which session does this platform talk in". Read this
--- instead of `session()` when *listing* (picker list, status output): a
--- platform that binds one chat per conversation (Lark) keeps every p2p
--- session out of `session()`, so listing `session()` hides them.
--- @param name string
--- @return string[] de-duplicated session ids, platform order preserved
function M.bound_sessions(name)
  local c = M.caps(name)
  if not c then
    return {}
  end
  local out, seen = {}, {}
  local function add(session)
    if type(session) ~= 'string' or session == '' or seen[session] then
      return
    end
    seen[session] = true
    table.insert(out, session)
  end
  if c.sessions then
    for _, session in ipairs(c.sessions() or {}) do
      add(session)
    end
  else
    add(c.session())
  end
  return out
end

--- Bind a platform to a session (platform level, `:Chat bridge <platform>`).
---
--- Rebinding drops whatever the platform pointed at before, so a per-chat
--- binding can never outlive the session it was created under.
--- @param name string
--- @param session string|nil
--- @return boolean|nil true bound, false unknown platform, nil no session
function M.bind(name, session)
  local c = M.caps(name)
  if not c then
    return false
  end
  if not session then
    return nil
  end
  local current = c.session()
  if current == session then
    return true
  end
  if current then
    M.unbind(name, current)
  end
  c.set_session(session)
  log.debug(string.format('[bridge] %s -> %s', name, session))
  return true
end

--- Bind one chat of a platform.
--- @param name string
--- @param chat_id string
--- @param session string|nil
--- @return boolean false when the platform cannot address one chat
function M.bind_chat(name, chat_id, session)
  local c = M.caps(name)
  if not c or not c.bind_chat or not chat_id then
    return false
  end
  return c.bind_chat(chat_id, session) and true or false
end

--- Drop every binding of a session on one platform.
---
--- Both levels are cleared, which is what `unbridge` always claimed to do.
--- @param name string
--- @param session string|nil
--- @return number how many bindings were dropped
function M.unbind(name, session)
  local c = M.caps(name)
  if not c or not session then
    return 0
  end
  local count = 0
  if c.session() == session then
    c.set_session(nil)
    count = count + 1
  end
  if c.bind_chat then
    for _, chat_id in ipairs(M.chats(name, session)) do
      if c.bind_chat(chat_id, nil) then
        count = count + 1
      end
    end
  end
  if count > 0 then
    log.debug(
      string.format('[bridge] unbound %s from %s (%d)', session, name, count)
    )
  end
  return count
end

--- Platforms a session is bridged to.
---
--- The single answer for routing (`on_response`), display (window title,
--- `GET /session/:id/bridge`, `/status`) and cleanup (`on_session_deleted`).
--- @param session string|nil
--- @return string[] sorted platform names
function M.list(session)
  local out = {}
  if not session then
    return out
  end
  for _, name in ipairs(ims().list_platforms()) do
    local c = M.caps(name)
    if c and (c.session() == session or #M.chats(name, session) > 0) then
      table.insert(out, name)
    end
  end
  return out
end

return M

