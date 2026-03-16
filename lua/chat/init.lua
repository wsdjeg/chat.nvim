local M = {}

function M.open(opt)
  require('chat.windows').open(opt)
end

function M.setup(opt)
  require('chat.config').setup(opt)
  -- 创建反色高亮组
  local normal = vim.api.nvim_get_hl(0, { name = 'Normal' })
  local float = vim.api.nvim_get_hl(0, { name = 'NormalFloat' })

  -- 反色：背景变前景，前景变背景
  vim.api.nvim_set_hl(0, 'ChatTitle', {
    fg = float.bg or normal.bg,
    bg = float.fg or normal.fg,
    bold = true,
  })

  -- 圆角使用 NormalFloat 背景
  vim.api.nvim_set_hl(0, 'ChatTitleCurve', {
    fg = float.fg or normal.fg,
    bg = 'NONE', -- 透明背景
  })
end

return M
