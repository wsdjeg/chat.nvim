local M = {}
local log
local logger_failed = false

for _, v in ipairs({ 'info', 'warn', 'error', 'debug' }) do
  M[v] = function(msg)
    if logger_failed then
      return
    end
    if not log then
      local ok, l = pcall(require, 'logger')
      if ok then
        local ok2, derived = pcall(l.derive, 'chat.nvim')
        if ok2 then
          log = derived
        else
          logger_failed = true
          return
        end
      else
        logger_failed = true
        return
      end
    end
    pcall(log[v], msg)
  end
end

function M.set_level(l)
  if log then
    pcall(log.set_level, l)
  end
end

--- Return all runtime log lines (in-memory log kept by logger.nvim).
--- Line format: `[ HH:MM:SS:mmm ] [ Level ] [ name ] message`
--- Returns nil when logger.nvim is not available.
function M.view_all()
  local ok, base = pcall(require, 'logger.base')
  if not ok then
    return nil
  end
  local ok2, s = pcall(base.view_all)
  if ok2 and type(s) == 'string' then
    return s
  end
  return nil
end

--- Clear the runtime log (shared across plugins using logger.nvim).
function M.clear()
  local ok, base = pcall(require, 'logger.base')
  if ok then
    pcall(base.clear)
  end
end

function M.notify(msg, color)
  local ok, nt = pcall(require, 'notify')
  if ok then
    pcall(nt.notify, msg, color)
  else
    pcall(vim.notify, msg)
  end
end

return M

