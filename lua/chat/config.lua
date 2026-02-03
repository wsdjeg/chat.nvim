local M = {}

local default = {
  width = 0.8, -- 80% of screen
  height = 0.8,
  provider = 'deepseek',
  model = 'deepseek-chat',
  border = 'rounded',
  api_key = '',
}

M.config = vim.tbl_deep_extend('force', default, {})

function M.setup(opt)
  M.config = vim.tbl_deep_extend('force', M.config, opt)
end

return M
