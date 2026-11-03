local M = {}

function M.open(opt)
  require('chat.windows').open(opt)
end

--- Start backend services (session, queue, http, mcp, integrations)
--- without opening any UI windows.
--- @param opt? table optional config, supports `cwd`
--- @return string|nil session_id
function M.start(opt)
  return require('chat.windows').start(opt)
end

--- Register a custom skill (slash command)
--- @param skill table ChatSkill spec: { name, description, handler, complete? }
--- @return boolean True if registered successfully
function M.register_skill(skill)
  return require('chat.skills').register(skill)
end

--- Unregister a skill by name
--- @param name string Skill name
function M.unregister_skill(name)
  require('chat.skills').unregister(name)
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

  -- Prompt placeholder shown in Normal mode while 'cursorline' is enabled:
  -- foreground from Comment, background from CursorLine, so the placeholder
  -- blends into the cursor line instead of punching a hole into it.
  local placeholder = config.config.highlights.placeholder
  if placeholder and vim.fn.hlexists(placeholder) == 0 then
    local comment = vim.api.nvim_get_hl(0, { name = 'Comment' })
    local cursorline = vim.api.nvim_get_hl(0, { name = 'CursorLine' })
    vim.api.nvim_set_hl(0, placeholder, {
      fg = comment.fg,
      bg = cursorline.bg or normal.bg,
    })
  end
end

function M.setup(opt)
  local config = require('chat.config')
  config.setup(opt)
  setup_highlights(config)

  -- Initialize skill system (register built-in skills)
  local skills = require('chat.skills')
  skills.init()

  -- Register user-defined skills from config
  if config.config.skills then
    for _, skill in ipairs(config.config.skills) do
      skills.register(skill)
    end
  end

  -- 初始化定时任务调度器（加载持久化任务并 arm timer）
  require('chat.scheduler').init()

  vim.api.nvim_create_autocmd({ 'ColorScheme' }, {
    pattern = { '*' },
    group = vim.api.nvim_create_augroup('chat.nvim', { clear = true }),
    callback = function()
      setup_highlights(config)
    end,
  })

  -- Neovim 退出时清理所有 timer
  vim.api.nvim_create_autocmd('VimLeavePre', {
    group = vim.api.nvim_create_augroup('chat_scheduler', { clear = true }),
    callback = function()
      require('chat.scheduler').shutdown()
    end,
  })
end

return M

