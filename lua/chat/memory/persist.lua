-- lua/chat/memory/persist.lua
-- Persistence pipeline shared by the three memory store modules.
--
-- Why this exists:
--   * Module-level `M.load()` used to run at require time, i.e. before
--     `config.setup()` in most flows, so it read the *default* storage
--     directory instead of the configured one. Loading is deferred to the
--     first real use here, when the effective config is known, and it reloads
--     when the configured directory changes -- so a runtime config change
--     (or a test switching storage_dir) never keeps stale data around.
--   * The cleanup timers could not be stopped: `vim.loop.new_timer():start()`
--     dropped the handle on the floor. The handle is kept here and closed by
--     `stop_timer()`.
--
-- Writes stay synchronous (store() must be durable the moment it returns) and
-- go through chat.memory.atomic (tmp + rename with a direct-write fallback),
-- so a failed rename never loses the target file.
local atomic = require('chat.memory.atomic')

local M = {}

local uv = vim.uv or vim.loop

---@class ChatMemoryPersist
---@field load fun(): table
---@field save fun(): boolean
---@field ensure_loaded fun()
---@field start_timer fun(interval_ms: number, callback: function)
---@field stop_timer fun()
---@field has_timer fun(): boolean

---Create a persistence pipeline for one memory module.
---
---@param opts { name: string, path: fun(): string|nil, get: fun(): table, set: fun(table), on_loaded?: fun() }
---@return ChatMemoryPersist
function M.new(opts)
  local loaded_path = nil
  local timer = nil

  local self = {}

  ---Current target file, normalized (nil when storage is unavailable).
  local function current_path()
    local path = opts.path()
    if not path then
      return nil
    end
    return vim.fs.normalize(path)
  end

  ---@param path string
  local function ensure_dir(path)
    local dir = vim.fs.dirname(path)
    if dir and vim.fn.isdirectory(dir) == 0 then
      vim.fn.mkdir(dir, 'p')
    end
  end

  ---Read the file for the current config into the module state.
  function self.load()
    local path = current_path()
    loaded_path = path

    if not path then
      opts.set({})
      return opts.get()
    end

    local file = io.open(path, 'r')
    if not file then
      -- A missing file must reset the in-memory state: the module is a
      -- process-wide singleton, so keeping the previous directory's data
      -- would leak memories across config changes (and across tests).
      opts.set({})
      return opts.get()
    end

    local content = file:read('*a')
    file:close()

    local ok, parsed = pcall(vim.json.decode, content)
    if ok and type(parsed) == 'table' then
      opts.set(parsed)
    else
      opts.set({})
    end

    if opts.on_loaded then
      opts.on_loaded()
    end

    return opts.get()
  end

  ---Write the module state now.
  ---@return boolean
  function self.save()
    local path = current_path()
    if not path then
      return false
    end

    ensure_dir(path)
    local ok = atomic.atomic_write(path, vim.json.encode(opts.get()))
    if ok then
      loaded_path = path
    end
    return ok
  end

  ---Load once for the current config, reloading when the path changed.
  function self.ensure_loaded()
    if loaded_path == current_path() then
      return
    end
    self.load()
  end

  ---Start a repeating timer once. The handle is kept so it can be closed.
  ---@param interval_ms number
  ---@param callback function
  function self.start_timer(interval_ms, callback)
    if timer then
      return
    end
    timer = uv.new_timer()
    timer:start(interval_ms, interval_ms, function()
      vim.schedule(callback)
    end)
  end

  ---Stop and close the cleanup timer, so it can never fire again.
  function self.stop_timer()
    if not timer then
      return
    end
    if not timer:is_closing() then
      timer:stop()
      timer:close()
    end
    timer = nil
  end

  ---@return boolean
  function self.has_timer()
    return timer ~= nil
  end

  return self
end

return M

