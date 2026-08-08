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

function M.notify(msg, color)
  local ok, nt = pcall(require, 'notify')
  if ok then
    pcall(nt.notify, msg, color)
  else
    pcall(vim.notify, msg)
  end
end

return M

