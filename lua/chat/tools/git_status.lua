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

---@class ChatToolsGitStatusAction
---@field path? string
---@field short? boolean
---@field show_branch? boolean

---@param action ChatToolsGitStatusAction
---@param ctx ChatToolContext
function M.git_status(action, ctx)
  -- Security check for ctx.cwd
  if not util.is_allowed_path(ctx.cwd) then
    return {
      error = 'Cannot run git_status in non-allowed path.',
    }
  end
  if not is_git_available() then
    return {
      error = 'git is not installed or not in PATH.',
    }
  end

  -- Build git command
  local cmd = { 'git', '-C', ctx.cwd, 'status' }

  local use_short = action.short ~= false
  if use_short then
    table.insert(cmd, '-s')
  end

  local show_branch = action.show_branch ~= false
  if show_branch and use_short then
    table.insert(cmd, '-b')
  end

  local resolved_path = nil
  if action.path and type(action.path) == 'string' then
    table.insert(cmd, '--')
    resolved_path = util.resolve(action.path, ctx.cwd)

    -- Security: ensure resolved_path is within ctx.cwd
    if
      not vim.startswith(
        vim.fs.normalize(resolved_path),
        vim.fs.normalize(ctx.cwd)
      )
    then
      return {
        error = 'Cannot access path outside working directory.',
      }
    end

    table.insert(cmd, resolved_path)
  end

  local stdout = {}
  local stderr = {}

  local jobid = job.start(cmd, {
    on_stdout = function(_, data)
      vim.list_extend(stdout, data)
    end,
    on_stderr = function(_, data)
      vim.list_extend(stderr, data)
    end,
    on_exit = function(id, code, signal)
      if signal ~= 0 then
        ctx.callback({
          error = string.format('Git status cancelled (signal: %d)', signal),
          jobid = id,
        })
        return
      end

      local output = table.concat(stdout, '\n')
      if #stderr > 0 then
        output = output .. '\n' .. table.concat(stderr, '\n')
      end

      if code == 0 then
        if output == '' then
          output = 'Working tree clean.'
        end

        local summary =
          string.format('Git status: %s\n\n', resolved_path or 'repository')
        ctx.callback({
          content = summary .. M.format_status(output, use_short),
          jobid = id,
        })
      else
        ctx.callback({
          error = string.format(
            'Failed (exit %d): %s\n%s',
            code,
            table.concat(cmd, ' '),
            output
          ),
          jobid = id,
        })
      end
    end,
  })

  if jobid > 0 then
    return { jobid = jobid }
  end
end

function M.format_status(output, short)
  if not short then
    return output
  end

  local lines = vim.split(output, '\n')
  local result = {}

  for _, line in ipairs(lines) do
    if line:match('^##') then
      table.insert(result, 'Branch: ' .. line:sub(4))
    elseif not line:match('^%s*$') then
      local status, file = line:match('^(..)%s+(.+)$')
      if status and file then
        local desc = M.status_code_description(status)
        table.insert(result, string.format('  %s  %s%s', status, file, desc))
      else
        table.insert(result, line)
      end
    end
  end

  return table.concat(result, '\n')
end

function M.status_code_description(code)
  local descriptions = {
    [' M'] = ' (modified)',
    ['M '] = ' (staged)',
    ['MM'] = ' (staged + modified)',
    [' A'] = ' (added)',
    ['A '] = ' (added, staged)',
    [' D'] = ' (deleted)',
    ['D '] = ' (deleted, staged)',
    ['R '] = ' (renamed)',
    ['C '] = ' (copied)',
    ['??'] = ' (untracked)',
    ['!!'] = ' (ignored)',
    ['UU'] = ' (conflict)',
    ['AA'] = ' (conflict)',
    ['DD'] = ' (conflict)',
  }
  return descriptions[code] or ''
end

function M.scheme()
  return {
    type = 'function',
    ['function'] = {
      name = 'git_status',
      description = [[
Show the working tree status.

USAGE:
- @git_status                    # Show repository status
- @git_status path="./src"       # Status for specific path
- @git_status short=false        # Long format

OUTPUT (short mode):
  M  file (staged)
   M file (modified)
  ?? file (untracked)
      ]],
      parameters = {
        type = 'object',
        properties = {
          path = {
            type = 'string',
            description = 'File or directory path (optional)',
          },
          short = {
            type = 'boolean',
            description = 'Use short format (default: true)',
          },
          show_branch = {
            type = 'boolean',
            description = 'Show branch info (default: true)',
          },
        },
        required = {},
      },
    },
  }
end

function M.info(action, ctx)
  local ok, args = pcall(vim.json.decode, action)
  if ok then
    local parts = { 'git_status' }
    if args.path then
      table.insert(parts, string.format('"%s"', args.path))
    end
    if args.short == false then
      table.insert(parts, 'short=false')
    end
    return table.concat(parts, ' ')
  end
  return 'git_status'
end

return M
