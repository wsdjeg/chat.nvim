local M = {}

local config = require('chat.config')
local util = require('chat.util')
local job = require('job')

-- Cache git availability check
local git_available = nil
local function is_git_available()
  if git_available == nil then
    git_available = vim.fn.executable('git') == 1
  end
  return git_available
end

---@class ChatToolsGitLogAction
---@field path? string
---@field count? integer
---@field oneline? boolean
---@field author? string
---@field since? string
---@field from? string
---@field to? string
---@field grep? string

---@param action ChatToolsGitLogAction
---@param ctx ChatToolContext
function M.git_log(action, ctx)
  -- Security check for ctx.cwd
  local is_allowed_path = false

  if type(config.config.allowed_path) == 'table' then
    for _, v in ipairs(config.config.allowed_path) do
      if type(v) == 'string' and #v > 0 then
        if vim.startswith(ctx.cwd, vim.fs.normalize(v)) then
          is_allowed_path = true
          break
        end
      end
    end
  elseif
    type(config.config.allowed_path) == 'string'
    and #config.config.allowed_path > 0
  then
    is_allowed_path =
      vim.startswith(ctx.cwd, vim.fs.normalize(config.config.allowed_path))
  end

  if not is_allowed_path then
    return {
      error = 'Cannot run git log in non-allowed path.',
    }
  end

  -- Check if git is available
  if not is_git_available() then
    return {
      error = 'git is not installed or not in PATH. Please install git first.',
    }
  end

  -- Handle count
  -- count <= 0 means no limit
  if action.count and action.count <= 0 then
    action.count = nil
  elseif action.count == nil then
    -- Only default count=5 when no filters are set
    local has_filters = action.author or action.since or action.grep or action.from or action.to
    if not has_filters then
      action.count = 5
    end
  end
  action.oneline = action.oneline ~= false -- default to true

  -- Build git command
  local cmd = { 'git', 'log' }

  -- Add count limit
  if action.count and type(action.count) == 'number' then
    table.insert(cmd, string.format('-%d', action.count))
  end

  -- Add oneline flag
  if action.oneline then
    table.insert(cmd, '--oneline')
  end

  -- Add author filter
  if action.author and type(action.author) == 'string' then
    table.insert(cmd, string.format('--author=%s', action.author))
  end

  -- Add time filter
  if action.since and type(action.since) == 'string' then
    table.insert(cmd, string.format('--since=%s', action.since))
  end

  -- Add grep filter
  if action.grep and type(action.grep) == 'string' then
    table.insert(cmd, string.format('--grep=%s', action.grep))
  end

  -- Add commit range (from/to)
  if action.from or action.to then
    local range = (action.from or '') .. '..' .. (action.to or '')
    table.insert(cmd, range)
  end

  -- Add path (default to ctx.cwd)
  local resolved_path
  if action.path and type(action.path) == 'string' and action.path ~= '' then
    -- Use path as subdir of ctx.cwd
    resolved_path = util.resolve(action.path, ctx.cwd)
  else
    -- Default to ctx.cwd
    resolved_path = ctx.cwd
  end

  table.insert(cmd, '--')
  table.insert(cmd, resolved_path)

  local stdout = {}
  local stderr = {}

  local jobid = job.start(cmd, {
    on_stdout = function(_, data)
      for _, v in ipairs(data) do
        table.insert(stdout, v)
      end
    end,
    on_stderr = function(_, data)
      for _, v in ipairs(data) do
        table.insert(stderr, v)
      end
    end,
    on_exit = function(id, code, signal)
      -- Check if cancelled by signal
      if signal ~= 0 then
        ctx.callback({
          error = string.format(
            'Git log cancelled by user (signal: %d)',
            signal
          ),
          jobid = id,
        })
        return
      end

      local output = table.concat(stdout, '\n')
      if #stderr > 0 then
        output = output .. '\n\n' .. table.concat(stderr, '\n')
      end
      if output == '' then
        output = 'No commits found.'
      end
      if code == 0 then
        local summary =
          string.format('Git log output for: %s\n\n', resolved_path)

        local filters = {}
        if action.from or action.to then
          local range = (action.from or '') .. '..' .. (action.to or '')
          table.insert(filters, string.format('range: %s', range))
        end
        if action.count then
          table.insert(
            filters,
            string.format('limit: %d commits', action.count)
          )
        end
        if action.author then
          table.insert(filters, string.format('author: %s', action.author))
        end
        if action.since then
          table.insert(filters, string.format('since: %s', action.since))
        end
        if action.grep then
          table.insert(filters, string.format('grep: %s', action.grep))
        end

        if #filters > 0 then
          summary = summary .. '(' .. table.concat(filters, ', ') .. ')\n\n'
        end

        ctx.callback({
          content = summary .. output,
          jobid = id,
        })
      else
        local error_msg = string.format(
          'Failed to run git log (exit code: %d): %s\n\nCommand: %s\n\nError output: %s',
          code,
          resolved_path,
          table.concat(cmd, ' '),
          output
        )
        ctx.callback({
          error = error_msg,
          jobid = id,
        })
      end
    end,
  })

  if jobid > 0 then
    return {
      jobid = jobid,
    }
  end
end

function M.scheme()
  return {
    type = 'function',
    ['function'] = {
      name = 'git_log',
      description = [[
        Show commit logs with various filters and options.

        This tool executes git log to show commit history for the repository or specific files.

        USAGE:
        - @git_log                           # Show last 5 commits (default)
        - @git_log count=10                  # Show last 10 commits
        - @git_log count=0                   # Show all commits (no limit)
        - @git_log oneline=false             # Show detailed format
        - @git_log path="./src/main.lua"     # Show commits for specific file
        - @git_log author="john"             # Filter by author
        - @git_log since="2024-01-01"        # Commits since date
        - @git_log from="v1.4.0"             # Commits from tag to HEAD
        - @git_log from="v1.0.0" to="v2.0.0" # Commits between tags
        - @git_log grep="fix"                # Search in commit messages

        EXAMPLES:
        - @git_log count=20
        - @git_log path="./src" since="2024-01-01"
        - @git_log author="Alice" count=5
        - @git_log from="v1.4.0"
        - @git_log grep="bug" since="2024-01-01"

        NOTES:
        - Requires git to be installed and in PATH.
        - Default: count=5, oneline=true, path=current working directory.
        - count <= 0 means no limit (show all commits).
        - If filters are set (author/since/grep/from/to), count defaults to no limit.
        - If path is provided, it's treated as subdirectory of current working directory.
        - Date formats: "2024-01-01", "2 weeks ago", "yesterday", etc.
        - Grep supports regex patterns in commit messages.
        - from/to: tag or commit hash for range (e.g., from="v1.4.0" to="v2.0.0").
        ]],
      parameters = {
        type = 'object',
        properties = {
          path = {
            type = 'string',
            description = 'File or directory path (subdirectory of cwd, default: cwd)',
          },
          count = {
            type = 'integer',
            description = 'Limit number of commits to show (default: 5, use 0 or negative for no limit)',
          },
          oneline = {
            type = 'boolean',
            description = 'Show each commit on a single line (default: true)',
          },
          author = {
            type = 'string',
            description = 'Filter commits by author name or email',
          },
          since = {
            type = 'string',
            description = 'Show commits after this date (e.g., "2024-01-01", "2 weeks ago")',
          },
          from = {
            type = 'string',
            description = 'Starting tag/commit for range (e.g., "v1.4.0")',
          },
          to = {
            type = 'string',
            description = 'Ending tag/commit for range (e.g., "v2.0.0", default: HEAD)',
          },
          grep = {
            type = 'string',
            description = 'Search for pattern in commit messages',
          },
        },
        required = {},
      },
    },
  }
end

function M.info(action, ctx)
  local ok, arguments = pcall(vim.json.decode, action)
  if ok then
    local info_parts = { 'git_log' }
    if arguments.from or arguments.to then
      table.insert(
        info_parts,
        string.format('range=%s..%s', arguments.from or '', arguments.to or '')
      )
    end
    if arguments.count then
      table.insert(info_parts, string.format('count=%d', arguments.count))
    end
    if arguments.oneline == false then
      table.insert(info_parts, 'oneline=false')
    end
    if arguments.author then
      table.insert(info_parts, string.format('author="%s"', arguments.author))
    end
    if arguments.path then
      table.insert(info_parts, string.format('path="%s"', arguments.path))
    end
    if arguments.since then
      table.insert(info_parts, string.format('since="%s"', arguments.since))
    end
    if arguments.grep then
      table.insert(info_parts, string.format('grep="%s"', arguments.grep))
    end
    return table.concat(info_parts, ' ')
  else
    return 'git_log'
  end
end

return M
