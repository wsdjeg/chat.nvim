local M = {}

function M.open(opt)
  require('chat.windows').open(opt)
end

function M.setup(opt)
  require('chat.config').setup(opt)
end

return M
