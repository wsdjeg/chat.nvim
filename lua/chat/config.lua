local M = {}

---@alias ChatConfigApiKey table<string, string>

---@class ChatConfig
---@field width? number
---@field height? number
---@field auto_scroll? boolean
---@field render_markdown? boolean
---@field provider? string
---@field model? string
---@field border? string
---@field highlights? table
---@field api_key? string | ChatConfigApiKey
---@field http? table
---@field allowed_path? string | string[]
---@field strftime? string
---@field system_prompt? string | function
---@field context? table
---@field storage_dir? string Base storage directory for all persistent data
---@field memory? table
---@field user? table
---@field integrations? table
---@field mcp? table
---@field winhighlight? string
---@field retry? table
---@field skills? table[] User-defined skills
---@field tools? table Tool discovery configuration

local default = {
  width = 0.8, -- 80% of screen
  height = 0.8,
  -- if auto_scroll is false, never scroll the result window automatically.
  -- if auto_scroll is true, only scroll to the bottom if the cursor was already on the last line before new content is appended.
  auto_scroll = true,
  -- enable RenderMarkdown plugin for the result buffer (requires render-markdown.nvim)
  render_markdown = true,
  provider = 'deepseek',
  model = 'deepseek-v4-flash',
  border = 'rounded',
  -- Highlight groups for the floating window
  highlights = {
    -- Title text highlight group
    title = 'ChatNvimTitle',
    -- Title badge highlight group (decorative symbols on both sides of the title)
    title_badge = 'ChatNvimTitleBadge',
  },
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
  context = {
    enable = true,
    trigger_threshold = 50, -- 触发截断的消息数
    keep_recent = 10, -- 最近 N 条不参与截断搜索
  },
  -- Base storage directory for all persistent data (plans, sessions, scheduler, etc.)
  -- Individual sub-modules use sub-directories under this path.
  storage_dir = vim.fn.stdpath('data') .. '/chat.nvim/',
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
    -- Override for memory storage directory.
    -- If not set, defaults to storage_dir .. 'memory/'
    storage_dir = nil,
  },
  -- User profile (人物画像) configuration
  user = {
    enable = true,
    -- User ID, auto-detected from system username if empty
    id = '',
    -- Override for user profile storage directory.
    -- If not set, defaults to storage_dir .. 'users/'
    storage_dir = nil,
  },
  -- Tool discovery configuration
  tools = {
    -- When true, only essential tools + find_tool are sent with each request.
    -- Other tools are discoverable via the find_tool tool (saves prompt tokens).
    -- When false, all available tools are sent with every request (old behavior).
    lazy = true,
    -- Tools always included in requests when lazy mode is on (find_tool is always included).
    essential = { 'read_file', 'list_directory', 'search_text', 'find_files', 'get_time' },
  },
  -- Auto-retry configuration for LLM requests on connection errors and timeouts
  retry = {
    -- Maximum number of retry attempts per request (default: 3)
    max_retries = 3,
    -- Delay between retries in milliseconds (default: 2000 = 2 seconds)
    retry_delay = 2000,
  },
  -- Window highlight configuration for floating windows
  winhighlight = 'NormalFloat:Normal,FloatBorder:WinSeparator',
}

---@type ChatConfig
M.config = vim.tbl_deep_extend('force', default, {})

---Get the effective memory storage directory
---@return string
function M.get_memory_storage_dir()
  return M.config.memory.storage_dir
    or (M.config.storage_dir .. 'memory/')
end

---Get the effective user storage directory
---@return string
function M.get_user_storage_dir()
  return M.config.user.storage_dir
    or (M.config.storage_dir .. 'users/')
end

---@param opt ChatConfig
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

