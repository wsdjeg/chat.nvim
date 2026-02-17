local M = {}
local log

for _, v in ipairs({ 'info', 'warn', 'error', 'debug' }) do
  M[v] = function(msg)
    if not log then
      local ok, l = pcall(require, 'logger')
      if ok then
        log = l.derive('chat.nvim')
        log[v](msg)
      end
    else
      log[v](msg)
    end
  end
end

function M.set_level(l)
  if log then
    log.set_level(l)
  end
end

function M.notify(msg, color)
  local ok, nt = pcall(require, 'notify')
  if ok then
    nt.notify(msg, color)
  else
    vim.notify(msg)
  end
end

return M
