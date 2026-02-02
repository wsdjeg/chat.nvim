local M = {}

local default = {
  width = 0.8, -- 80% of screen
  height = 0.8,
  provider = 'deepseek',
  api_key = ''
}

M.config = vim.tbl_deep_extend('keep', default, {})

function M.setup(opt)
  M.config = vim.tbl_deep_extend('keep', default, opt)
end

return M
