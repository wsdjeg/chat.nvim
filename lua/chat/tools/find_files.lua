local M = {}

local job = require('job')
local util = require('chat.util')

-- Cache rg availability check result
local rg_available = nil
local function is_rg_available()
  if rg_available == nil then
    rg_available = vim.fn.executable('rg') == 1
  end
  return rg_available
end

-- Smart case: if pattern has uppercase, use case-sensitive; otherwise case-insensitive
local function should_ignore_case(pattern)
  return not pattern:match('%u')
end

---@class ChatToolsFindFilesAction
---@field pattern string
---@field directory? string
---@field hidden? boolean
---@field no_ignore? boolean
---@field exclude? string | string[]
---@field max_results? integer

---@param action ChatToolsFindFilesAction
function M.find_files(action, ctx)
  -- Parameter validation
  if
    not action.pattern
    or type(action.pattern) ~= 'string'
    or action.pattern == ''
  then
    return {
      error = 'Pattern is required and must be a non-empty string.',
    }
  end

  -- Security check for ctx.cwd
  if not util.is_allowed_path(ctx.cwd) then
    return {
      error = 'Cannot find files in non-allowed path.',
    }
  end

  -- Resolve search directory
  local search_dir = ctx.cwd
  if
    action.directory
    and type(action.directory) == 'string'
    and #action.directory > 0
  then
    -- 使用 util.resolve 自动处理绝对/相对路径
    search_dir = util.resolve(action.directory, ctx.cwd)

    -- Security check: ensure search_dir is within allowed path
    if not util.is_allowed_path(search_dir) then
      return {
        error = 'Cannot search outside allowed path.',
      }
    end

    -- Verify directory exists
    if vim.fn.isdirectory(search_dir) == 0 then
      return {
        error = string.format(
          'Directory does not exist: %s',
          action.directory
        ),
      }
    end
  end

  -- Check if rg is available
  if not is_rg_available() then
    return {
      error = 'ripgrep (rg) is not installed or not in PATH. Please install it first.',
    }
  end

  -- Smart case: detect if pattern has uppercase
  local ignore_case = should_ignore_case(action.pattern)

  -- Build command: rg --files [options] --glob <pattern> [--glob !<exclude>]
  local cmd = { 'rg', '--files' }

  -- Add glob-case-insensitive if smart case determines it
  if ignore_case then
    table.insert(cmd, '--glob-case-insensitive')
  end

  -- Include hidden files
  if action.hidden then
    table.insert(cmd, '--hidden')
  end

  -- Don't respect .gitignore and other ignore files
  if action.no_ignore then
    table.insert(cmd, '--no-ignore')
  end

  -- Add include glob pattern
  table.insert(cmd, '--glob')
  table.insert(cmd, action.pattern)

  -- Add exclude patterns with ! prefix
  if action.exclude then
    local excludes = type(action.exclude) == 'string' and { action.exclude }
      or action.exclude
    if type(excludes) == 'table' then
      for _, excl in ipairs(excludes) do
        if type(excl) == 'string' and #excl > 0 then
          table.insert(cmd, '--glob')
          table.insert(cmd, '!' .. excl)
        end
      end
    end
  end

  -- Add search directory
  table.insert(cmd, search_dir)

  local stdout = {}
  local stderr = {}

  -- Default max_results to 100, clamp to [1, 1000]
  local max_results = action.max_results or 100
  max_results = math.max(1, math.min(1000, max_results))
  local truncated = false

  local jobid = job.start(cmd, {
    on_stdout = function(_, data)
      for _, v in ipairs(data) do
        if #v > 0 then
          if #stdout < max_results then
            table.insert(stdout, v)
          else
            truncated = true
          end
        end
      end
    end,
    on_stderr = function(_, data)
      for _, v in ipairs(data) do
        table.insert(stderr, v)
      end
    end,
    on_exit = function(id, code, signal)
      if signal ~= 0 then
        ctx.callback({
          error = string.format(
            'find_files cancelled by user (signal: %d)',
            signal
          ),
          jobid = id,
        })
        return
      end

      if code == 0 then
        -- Found matching files
        local file_count = #stdout
        local output
        if truncated then
          output = string.format(
            'Found more than %d files matching "%s" in %s (showing first %d):\n\n%s\n\n⚠️ Result truncated. Use a more specific pattern or set max_results higher to see more.',
            max_results,
            action.pattern,
            search_dir,
            file_count,
            table.concat(stdout, '\n')
          )
        else
          output = string.format(
            'Found %d files matching "%s" in %s:\n\n%s',
            file_count,
            action.pattern,
            search_dir,
            table.concat(stdout, '\n')
          )
        end
        ctx.callback({
          content = output,
          jobid = id,
        })
      elseif code == 1 then
        -- No files found (normal case, not an error)
        ctx.callback({
          content = string.format(
            'No files found matching "%s" in %s',
            action.pattern,
            search_dir
          ),
          jobid = id,
        })
      else
        -- Exit code >= 2: actual error
        ctx.callback({
          error = string.format(
            'find_files command failed (exit code: %d):\n\nCommand: %s\n\nOutput:\n%s',
            code,
            table.concat(cmd, ' '),
            table.concat(stderr, '\n')
          ),
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
      name = 'find_files',
      description = [[
      user can use @find_files <pattern> to find files in current working directory.
      Uses ripgrep (rg) for fast file finding.
      ]],
      parameters = {
        type = 'object',
        properties = {
          pattern = {
            type = 'string',
            description = 'Glob pattern to match files (e.g., "*.lua", "**/*.md"). Smart case: lowercase = case-insensitive, uppercase = case-sensitive.',
          },
          directory = {
            type = 'string',
            description = 'Subdirectory to search in (relative to current working directory, must be within cwd)',
          },
          hidden = {
            type = 'boolean',
            description = 'Include hidden files (default: false)',
          },
          no_ignore = {
            type = 'boolean',
            description = 'Do not respect .gitignore and ignore files (default: false)',
          },
          exclude = {
            description = 'Glob pattern(s) to exclude files (e.g., "*.test.lua" or ["*.test.lua", "node_modules/*"])',
            oneOf = {
              { type = 'string' },
              { type = 'array', items = { type = 'string' } },
            },
          },
          max_results = {
            type = 'integer',
            description = 'Maximum number of results to return (default: 100, max: 1000). ⚠️ Only increase when necessary - large results may exceed context limits.',
            minimum = 1,
            maximum = 1000,
          },
        },
        required = { 'pattern' },
      },
    },
  }
end

function M.info(action, ctx)
  local ok, arguments = pcall(vim.json.decode, action)
  if ok then
    local display_dir = arguments.directory
        and util.resolve(arguments.directory, ctx.cwd)
      or ctx.cwd

    local info_parts = {
      string.format('find_files "%s"', arguments.pattern),
      string.format('in %s', display_dir),
    }

    local options = {}
    if not arguments.pattern:match('%u') then
      table.insert(options, 'ignore_case')
    end
    if arguments.hidden then
      table.insert(options, 'hidden')
    end
    if arguments.no_ignore then
      table.insert(options, 'no_ignore')
    end
    if arguments.exclude then
      local excludes = type(arguments.exclude) == 'string'
          and { arguments.exclude }
        or arguments.exclude
      local excl_strs = {}
      for _, excl in ipairs(excludes) do
        table.insert(excl_strs, '!' .. excl)
      end
      table.insert(options, 'exclude=' .. table.concat(excl_strs, ','))
    end
    if arguments.max_results then
      table.insert(options, 'max_results=' .. arguments.max_results)
    end

    if #options > 0 then
      table.insert(info_parts, '[' .. table.concat(options, ', ') .. ']')
    end

    return table.concat(info_parts, ' ')
  else
    return 'find_files'
  end
end

return M
