local M = {}

local default = {
  width = 0.8, -- 80% of screen
  height = 0.8,
  provider = 'deepseek',
  model = 'deepseek-chat',
  border = 'rounded',
  api_key = '',
  -- default allowed_path is empty string, which means no files is allowed.
  allowed_path = '',
  strftime = '%m-%d %H:%M:%S',
  memory = {
    enable = true,
    max_memories = 500, -- 最多存储500条记忆
    retrieval_limit = 3, -- 每次检索最多3条
    similarity_threshold = 0.3, -- 文本相似度阈值
    storage_dir = vim.fn.stdpath('cache') .. '/chat.nvim/memory/',
  },
}

M.config = vim.tbl_deep_extend('force', default, {})

function M.setup(opt)
  M.config = vim.tbl_deep_extend('force', M.config, opt)
end

return M
