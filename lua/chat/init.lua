local M = {}

function M.open(opt)
  require('chat.windows').open(opt)
end

local function setup_highlights(config)
  local normal = vim.api.nvim_get_hl(0, { name = 'Normal' })

  if
    vim.tbl_isempty(
      vim.api.nvim_get_hl(0, { name = config.config.highlights.title })
    )
  then
    vim.api.nvim_set_hl(0, config.config.highlights.title, {
      fg = normal.bg,
      bg = normal.fg,
      bold = true,
    })
  end
  if
    vim.tbl_isempty(
      vim.api.nvim_get_hl(0, { name = config.config.highlights.title_badge })
    )
  then
    vim.api.nvim_set_hl(0, config.config.highlights.title_badge, {
      fg = normal.fg,
      bg = normal.bg,
    })
  end
end

function M.setup(opt)
  local config = require('chat.config')
  config.setup(opt)
  setup_highlights(config)

  vim.api.nvim_create_autocmd({ 'ColorScheme' }, {
    pattern = { '*' },
    group = vim.api.nvim_create_augroup('chat.nvim', { clear = true }),
    callback = function()
      setup_highlights(config)
    end,
  })
end

return M
