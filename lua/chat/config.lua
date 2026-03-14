local M = {}

local default = {
  width = 0.8, -- 80% of screen
  height = 0.8,
  -- if auto_scroll is false, never scroll the result window automatically.
  -- if auto_scroll is true, only scroll to the bottom if the cursor was already on the last line before new content is appended.
  auto_scroll = true,
  provider = 'deepseek',
  model = 'deepseek-chat',
  border = 'rounded',
  api_key = '',
  http = {
    host = '127.0.0.1',
    port = 7777,
    api_key = '',
  },
  -- default allowed_path is empty string, which means no files is allowed.
  allowed_path = '',
  strftime = '%m-%d %H:%M:%S',
  system_prompt = '',
  memory = {
    enable = true,
    long_term = {
      enable = true,
      max_memories = 500,
      retrieval_limit = 3,
      similarity_threshold = 0.3,
    },
    daily = {
      enable = true,
      retention_days = 7,
      max_memories = 100,
      similarity_threshold = 0.4,
    },
    working = {
      enable = true,
      max_memories = 20,
      priority_weight = 2.0,
    },
    storage_dir = vim.fn.stdpath('cache') .. '/chat.nvim/memory/',
  },
}

M.config = vim.tbl_deep_extend('force', default, {})

function M.setup(opt)
  if
    opt.system_prompt
    and type(opt.system_prompt) ~= 'string'
    and type(opt.system_prompt) ~= 'function'
  then
    require('chat.log').error(
      'system_prompt must be string or function, got '
        .. type(opt.system_prompt)
    )
    return
  end
  M.config = vim.tbl_deep_extend('force', M.config, opt)

  require('chat.mcp').setup()

end

return M
