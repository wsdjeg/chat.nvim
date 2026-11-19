-- lua/chat/providers.lua
-- Shared provider discovery helpers.
--
-- Several entry points used to enumerate `lua/chat/providers/*.lua` and call
-- `available_models()` on their own: the /provider skill, the HTTP routes
-- (GET /providers, POST /session/new, PUT /session/:id/provider) and the
-- picker sources. Keeping one implementation here makes those paths agree on
-- what a "known provider" is, and gives the argument-taking paths a way to
-- reject a typo before it lands in a session.
--
-- `available_models()` is deliberately wrapped: dynamic providers resolve
-- their list asynchronously (the first call starts a background curl and
-- returns an empty table) and a provider module may be missing entirely, so
-- callers must never see a nil or an exception - only an (possibly empty)
-- table.

local M = {}

--- List every provider module name found on the runtime path, sorted.
---
--- The runtime file list is authoritative: it covers both the bundled
--- providers and user-supplied ones dropped into
--- `~/.config/nvim/lua/chat/providers/`. Duplicates (the same module shipped
--- by two plugin dirs) are collapsed so a selection UI shows one entry.
--- @return string[] Sorted provider module names
function M.list()
  local files = vim.api.nvim_get_runtime_file('lua/chat/providers/*.lua', true)
  local names = {}
  local seen = {}
  for _, file in ipairs(files) do
    local name = vim.fn.fnamemodify(file, ':t:r')
    if name ~= '' and not seen[name] then
      seen[name] = true
      table.insert(names, name)
    end
  end
  table.sort(names)
  return names
end

--- True when `name` resolves to a loadable provider module.
---
--- Used by the argument-taking paths (/provider <name>) where a typo would
--- otherwise be written into the session silently: every later request would
--- fail inside `chat.protocol.request` with a nil jobid and only a debug log
--- line to explain it.
--- @param name string|nil Provider module name
--- @return boolean
function M.exists(name)
  if type(name) ~= 'string' or name == '' then
    return false
  end
  local ok, provider = pcall(require, 'chat.providers.' .. name)
  return ok and type(provider) == 'table'
end

--- Available models of a provider, or an empty table.
---
--- Never raises: a missing module, a provider without `available_models`, or a
--- list that is still loading all collapse to `{}`, which callers treat as
--- "unknown for now" rather than as an error.
--- @param name string|nil Provider module name
--- @return string[] Model names (possibly empty)
function M.available_models(name)
  if type(name) ~= 'string' or name == '' then
    return {}
  end
  local ok, provider = pcall(require, 'chat.providers.' .. name)
  if not ok or type(provider) ~= 'table' or not provider.available_models then
    return {}
  end
  local ok_models, models = pcall(provider.available_models)
  if not ok_models or type(models) ~= 'table' then
    return {}
  end
  return models
end

return M

