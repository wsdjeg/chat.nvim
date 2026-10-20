-- test/restore_util.lua
-- Shared save/restore helper for specs that temporarily stub module methods.
-- Keeps stubs from leaking into other test files in the shared nvim process.

local saved = {}

local M = {}

--- Save the current value of `mod[method]` so it can be restored later.
--- Only the first snap per (mod, method) is kept (preserves the original).
function M.snap(mod, method)
  if not saved[mod] then saved[mod] = {} end
  if saved[mod][method] == nil then
    saved[mod][method] = mod[method]
  end
end

--- Restore every snapped method to its original value, then clear the record.
function M.restore_all()
  for mod, methods in pairs(saved) do
    for method, orig in pairs(methods) do
      mod[method] = orig
    end
  end
  saved = {}
end

--- Force a fresh require of a module, discarding any package.loaded stub left
--- behind by other specs that replace modules via package.loaded.
function M.reload(modname)
  package.loaded[modname] = nil
  return require(modname)
end

--- Register the global config and session-storage tables so they are restored
--- on the next restore_all() call. Call from each spec's setUp.
function M.store_global_state()
  local config = require('chat.config')
  local storage = require('chat.sessions.storage')
  M.snap(config, 'config')
  M.snap(storage, 'cache_dir')
  M.snap(storage, 'sessions')
end

return M
