-- lua/chat/integrations/telegram/util.lua
-- Config readers, constants and small list helpers shared by every telegram
-- submodule.
--
-- Nothing here keeps state: reads go to `chat.config` live, so a `config.setup()`
-- between test specs is always visible (the specs rely on it).
local config = require('chat.config')

local M = {}

--- Bot API base URL. The token is appended per request (see `M.api_url`).
M.API_BASE = 'https://api.telegram.org/bot'

-- Upper bound for the "recent speakers" cache kept in the state file. The
-- cache backs the Neovim picker (allow / deny without copying numeric ids out
-- of the Telegram client), so a handful is plenty.
M.MAX_RECENT_SENDERS = 30

--- Sorted keys of a map, for stable output.
--- @param map table
--- @return string[]
function M.sorted_keys(map)
  local list = {}
  for k in pairs(map) do
    table.insert(list, k)
  end
  table.sort(list)
  return list
end

--- Normalize a Telegram id into its string form.
---
--- Telegram ids are integers, and group / channel ids are negative
--- (`-1001234567890`). They are used as map keys, state-file keys and
--- directory-name fragments, so exactly one representation is needed:
--- `tostring` would turn a large value into `-1.00123456789e+12` on LuaJIT,
--- while `%.0f` always yields the plain digits.
--- @param value number|string|nil
--- @return string|nil
function M.id_to_string(value)
  if value == nil then
    return nil
  end
  if type(value) == 'number' then
    return string.format('%.0f', value)
  end
  if type(value) ~= 'string' or value == '' then
    return nil
  end
  return value
end

--- Merge a config list with a runtime map into one sorted, de-duplicated list.
--- @param config_list string[]|number[]|nil
--- @param state_map table|nil
--- @return string[]
function M.merge_ids(config_list, state_map)
  local result = {}
  local seen = {}

  for _, id in ipairs(config_list or {}) do
    local key = M.id_to_string(id)
    if key and not seen[key] then
      seen[key] = true
      table.insert(result, key)
    end
  end

  for id in pairs(state_map or {}) do
    if not seen[id] then
      seen[id] = true
      table.insert(result, id)
    end
  end

  table.sort(result)
  return result
end

--- `integrations.telegram` config table.
--- @return table
function M.telegram_config()
  return (config.config.integrations and config.config.integrations.telegram)
    or {}
end

--- `integrations.telegram.acl` config table.
--- @return table
function M.acl_config()
  return M.telegram_config().acl or {}
end

--- `integrations.telegram.p2p` config table.
--- @return table
function M.p2p_config()
  return M.telegram_config().p2p or {}
end

--- Bot token, or nil when it is not configured.
--- @return string|nil
function M.bot_token()
  local token = M.telegram_config().bot_token
  if type(token) ~= 'string' or token == '' then
    return nil
  end
  return token
end

--- URL of one Bot API method.
--- @param method string e.g. 'getUpdates', 'sendMessage'
--- @param token? string Defaults to the configured bot token
--- @return string
function M.api_url(method, token)
  return M.API_BASE .. (token or M.bot_token() or '') .. '/' .. method
end

--- The configured main chat (`chat_id`).
---
--- Kept as a plain config read: `current_session()` / `set_session()` are
--- platform-level APIs, and the shared layer depends on them. The main chat is
--- the one those APIs address.
--- @return string|nil
function M.main_chat_id()
  return M.id_to_string(M.telegram_config().chat_id)
end

--- Root directory under which per-chat (private chat) workspaces are created.
---
--- `integrations.telegram.p2p.cwd_root` wins; otherwise the first entry of
--- `allowed_path` is used. That is deliberate: a workspace outside
--- `allowed_path` is useless because every file tool would refuse it, and
--- keeping the root inside the allowed tree means the isolation never widens
--- what the bot may touch.
---
--- Returns nil when nothing usable is configured, which makes the container
--- keep the session's default directory (the Neovim cwd).
--- @return string|nil
function M.p2p_cwd_root()
  local root = M.p2p_config().cwd_root
  if type(root) == 'string' and root ~= '' then
    return vim.fs.normalize(root)
  end

  local allowed = config.config.allowed_path
  if type(allowed) == 'table' then
    for _, entry in ipairs(allowed) do
      if type(entry) == 'string' and entry ~= '' then
        return vim.fs.normalize(entry)
      end
    end
    return nil
  end
  if type(allowed) == 'string' and allowed ~= '' then
    return vim.fs.normalize(allowed)
  end
  return nil
end

--- Sanitize a chat id into a single filesystem-safe path segment.
---
--- Group ids are negative by design, so `-` is kept; anything else unexpected
--- is replaced instead of rejected, so a malformed id can not escape the
--- workspace root.
--- @param chat_id string
--- @return string
function M.workspace_dir_name(chat_id)
  return (tostring(chat_id):gsub('[^%w%-_]', '_'))
end

return M

