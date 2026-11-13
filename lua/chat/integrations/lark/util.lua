-- lua/chat/integrations/lark/util.lua
-- Config readers, constants and small list helpers shared by every lark
-- submodule.
--
-- Nothing here keeps state: reads go to `chat.config` live, so a `config.setup()`
-- between test specs is always visible (the specs rely on it).
local config = require('chat.config')

local M = {}

--- Open API base URL shared by every request this integration makes.
M.API_BASE = 'https://open.feishu.cn/open-apis'

-- Upper bound for the "recent speakers" cache kept in the state file. The
-- cache is meant for a future Neovim picker (allow / deny without copying
-- open_ids from the open platform console), so a handful is plenty.
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

--- Merge a config list with a runtime map into one sorted, de-duplicated list.
--- @param config_list string[]|nil
--- @param state_map table|nil
--- @return string[]
function M.merge_ids(config_list, state_map)
  local result = {}
  local seen = {}

  for _, id in ipairs(config_list or {}) do
    if not seen[id] then
      seen[id] = true
      table.insert(result, id)
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

--- `integrations.lark` config table.
--- @return table
function M.lark_config()
  return (config.config.integrations and config.config.integrations.lark) or {}
end

--- `integrations.lark.acl` config table.
--- @return table
function M.acl_config()
  return M.lark_config().acl or {}
end

--- `integrations.lark.p2p` config table.
--- @return table
function M.p2p_config()
  return M.lark_config().p2p or {}
end

--- The configured main container (`chat_id`).
---
--- Kept as a plain config read: `current_session()` / `set_session()` are
--- platform-level APIs, and the shared layer depends on them. The main
--- container is the one those APIs address.
--- @return string|nil
function M.main_chat_id()
  return M.lark_config().chat_id
end

--- Root directory under which per-chat (p2p) workspaces are created.
---
--- `integrations.lark.p2p.cwd_root` wins; otherwise the first entry of
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
--- `oc_...` ids are already safe, but the value comes from the Open API and
--- ends up as a directory name: anything unexpected is replaced instead of
--- rejected, so a malformed id can not escape the workspace root.
--- @param chat_id string
--- @return string
function M.workspace_dir_name(chat_id)
  return (tostring(chat_id):gsub('[^%w%-_]', '_'))
end

return M

