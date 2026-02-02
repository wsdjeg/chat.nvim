local M = {}

function M.open()
  require('chat.windows').open()
end

function M.setup(opt)
  require('chat.config').setup(opt)
end

return M
