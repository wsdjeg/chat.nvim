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

return M

