local M = {}

--- A single api key (string) or a list of keys (string[]) rotated
--- round-robin by the tokens module, with per-key cooldown on rate limits.
---@alias ChatApiKey string|string[]

---@alias ChatConfigApiKey table<string, ChatApiKey>

---@class ChatIcons
---@field bot? string Icon before the assistant display name
---@field user? string Icon before the user display name
---@field tool? string Icon of a running tool call
---@field success? string Icon of a successful tool call / completed turn
---@field error? string Icon of a failed tool call or message
---@field notice? string Icon of a UI-only notice line
---@field cache? string Icon of the prompt cache hit ratio

---@class ChatConfig
---@field width? number
---@field height? number
---@field auto_scroll? boolean
---@field render_markdown? boolean
---@field provider? string
---@field model? string
---@field border? string
---@field highlights? table
---@field icons? ChatIcons
---@field api_key? string | ChatConfigApiKey
---@field http? table
---@field allowed_path? string | string[]
---@field strftime? string
---@field names? { bot?: string, user?: string }
---@field system_prompt? string | function
---@field context? table
---@field storage_dir? string Base storage directory for all persistent data
---@field sessions? table Session lifecycle options (trash)
---@field memory? table
---@field user? table
---@field mastodon? table
---@field integrations? table
---@field mcp? table
---@field winhighlight? string
---@field retry? table
---@field continuation? table
---@field token_cooldown? number Seconds an api key is skipped after a rate-limit / server error (default: 30)
---@field quota_cooldown? number Seconds an api key is skipped after a quota-exhaustion error, e.g. coding-plan limits (default: 3600)
---@field cache? table Prefix cache probe configuration
---@field usage_stats? table Per provider/model request & token accounting
---@field skills? table[] User-defined skills
---@field tools? table Tool discovery configuration

--- Pristine UI glyph defaults.
---
--- Kept separate from `default` so an invalid `setup({ icons = ... })` value
--- can be repaired against the original icon instead of against whatever a
--- previous `setup()` call installed.
--- Every value must stay a single displayed character; `chat.icons.is_valid()`
--- enforces that (and `''` to disable the glyph entirely).
M.icon_defaults = {
  -- Icon before the assistant display name, e.g. '🤖 Bot:'
  bot = '🤖',
  -- Icon before the user display name, e.g. '👤 You:'
  user = '👤',
  -- Icon of a tool call that is currently running
  tool = '🔧',
  -- Icon of a successful tool call and of a completed turn
  success = '✅',
  -- Icon of a failed tool call or a failed message
  error = '❌',
  -- Icon of a UI-only notice line (e.g. api key rotation)
  notice = '🔁',
  -- Icon of the prompt cache hit ratio
  cache = '💾',
}

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
  -- Highlight groups for floating windows
  highlights = {
    -- Title text highlight group
    title = 'ChatNvimTitle',
    -- Title badge highlight group (decorative symbols on both sides of the title)
    title_badge = 'ChatNvimTitleBadge',
    -- Placeholder highlight used in Normal mode when 'cursorline' is enabled.
    -- Foreground comes from Comment, background from CursorLine.
    placeholder = 'ChatNvimPlaceholder',
  },
  -- Glyphs shown in the terminal UI. Validated in setup(), see chat.icons.
  icons = vim.deepcopy(M.icon_defaults),
  api_key = '',
  http = {
    host = '127.0.0.1',
    port = 7777,
    api_key = '',
  },
  -- default allowed_path is empty string, which means no files is allowed.
  allowed_path = '',
  strftime = '%m-%d %H:%M:%S',
  -- Custom role display names shown before the colon in the chat window
  names = {
    -- Display name for the AI assistant (e.g. '🤖 Bot: ...')
    bot = 'Bot',
    -- Display name for the user (e.g. '👤 You: ...')
    user = 'You',
  },
  system_prompt = '',
  context = {
    enable = true,
    trigger_threshold = 50, -- 触发截断的消息数
    keep_recent = 10, -- 最近 N 条不参与截断搜索
    slide_step = 0, -- >1 时窗口每累计 N 条消息才前移一次（缓存友好；0/1 = 每条都滑）
  },
  -- Base storage directory for all persistent data (plans, sessions, scheduler, etc.)
  -- Individual sub-modules use sub-directories under this path.
  storage_dir = vim.fn.stdpath('data') .. '/chat.nvim/',
  -- Session lifecycle options
  sessions = {
    -- When true, deleting a session moves its cache file into
    -- {storage_dir}/sessions-trash/ instead of removing it permanently.
    -- Restore with /restore, list with /trash, or move the file back by hand.
    -- The trash is never cleaned automatically.
    trash = true,
  },
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
      -- Ranking weight applied inside the daily module (multiplied once,
      -- only here -- chat.memory.init does not add its own multiplier).
      priority_weight = 1.5,
    },
    working = {
      enable = true,
      max_memories = 20,
      -- Ranking weight applied inside the working module (multiplied once,
      -- only here -- chat.memory.init does not add its own multiplier).
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
  -- Mastodon (read-only) configuration for the mastodon tool
  mastodon = {
    -- Default instance origin used by the mastodon tool
    instance = 'https://mastodon.social',
    -- Optional access token (Bearer). Required for search on most instances.
    access_token = '',
  },
  -- Tool discovery configuration
  tools = {
    -- When true, only essential tools + find_tool are sent with each request.
    -- Other tools are discoverable via the find_tool tool (saves prompt tokens).
    -- When false, all available tools are sent with every request (old behavior).
    lazy = true,
    -- Tools always included in requests when lazy mode is on (find_tool is always included).
    essential = { 'read_file', 'list_directory', 'search_text', 'find_files', 'get_time' },
    -- get_history result size budget. The tool returns conversation
    -- history, and a single tool result inside that history (read_file,
    -- fetch_web, git_diff) can be hundreds of KB, so the payload is capped
    -- by BYTES rather than by message count.
    get_history = {
      -- Budget used when the caller omits max_bytes (default: 32768).
      default_max_bytes = 32768,
      -- Ceiling for an explicit max_bytes (default: 204800). Raise it for
      -- large-context models that can afford reading a whole tool result
      -- in one call.
      max_bytes_limit = 204800,
    },
  },
  -- Auto-retry configuration for LLM requests on connection errors and timeouts
  retry = {
    -- Maximum number of retry attempts per request (default: 3)
    max_retries = 3,
    -- Delay between retries in milliseconds (default: 2000 = 2 seconds)
    retry_delay = 2000,
  },
  -- Auto-continuation for responses truncated by max_tokens
  -- (finish_reason == "length"). The truncated content is kept as an
  -- assistant message and the request is re-sent directly (no synthetic user
  -- message) until the response completes or the budget is exhausted.
  continuation = {
    -- Enable automatic continuation of truncated responses.
    enable = true,
    -- Maximum number of continuation requests per response (default: 3).
    max_continuations = 3,
  },
  -- Multi-api_key rotation: seconds an api key is skipped after a rate
  -- limit (429) or server error (5xx) before it is tried again
  token_cooldown = 30,
  -- Seconds an api key is skipped after a quota-exhaustion error
  -- (coding-plan / per-account limits), much longer than a plain rate
  -- limit because the quota window itself is long
  quota_cooldown = 3600,
  -- Prefix cache observability. Providers bill cached prompt tokens at a
  -- fraction of the normal price, but only while the request prefix stays
  -- byte-identical (system prompt + tools + already sent messages). The
  -- probe fingerprints every request and logs the first position that
  -- diverges from the previous request of the same session.
  cache = {
    -- Log divergences (`[cache] ... break=#N/M reason=tools|system|
    -- messages|truncated`) and keep per-session counters, see
    -- `require('chat.sessions').cache_stats(session)`.
    -- Set false to disable all probe bookkeeping.
    probe = true,
  },
  -- Per provider/model request & token accounting, written to
  -- {storage_dir}/usage_stats.json on every completed request.
  -- Query with require('chat.usage_stats'): total() / range(since).
  usage_stats = {
    -- Set false to stop recording (queries then return empty tables).
    enable = true,
    -- Hourly buckets older than this many days are dropped (default: 7).
    hourly_days = 7,
    -- Daily buckets older than this many days are dropped (default: 365).
    daily_days = 365,
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

  -- Validate the icons *before* the deep merge: an invalid glyph would
  -- otherwise end up in the live config and only surface later, inside a
  -- Vim regex or a window title. sanitize() always returns a complete table,
  -- so the merge never leaves a hole behind.
  if opt.icons ~= nil then
    local icons = require('chat.icons').sanitize(opt.icons)
    opt = vim.tbl_extend('force', opt, { icons = icons })
  end

  M.config = vim.tbl_deep_extend('force', M.config, opt)

  require('chat.mcp').setup()
end

return M

