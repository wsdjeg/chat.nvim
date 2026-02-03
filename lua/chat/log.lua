local M = {}
local log
function M.info(msg)
  if not log then
    local ok, l = pcall(require, 'logger')
    if ok then
      log = l.derive('chat.nvim')
      log.info(msg)
    end
  else
    log.info(msg)
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
