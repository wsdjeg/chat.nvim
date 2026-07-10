local M = {}

local config = require('chat.config')
local job = require('job')

-- Cache git availability check
local git_available = nil
local function is_git_available()
  if git_available == nil then
    git_available = vim.fn.executable('git') == 1
  end
  return git_available
end

---@class ChatToolsGitRebaseAction
---@field branch? string Branch to rebase onto
---@field abort? boolean Abort the current rebase (--abort)
---@field continue? boolean Continue the current rebase after resolving conflicts (--continue)
---@field skip? boolean Skip the current commit and continue rebase (--skip)

---@param action ChatToolsGitRebaseAction
---@param ctx ChatToolContext
function M.git_rebase(action, ctx)
  -- Security check for ctx.cwd
  local is_allowed_path = false
  local normalized_cwd = vim.fs.normalize(ctx.cwd)

  if type(config.config.allowed_path) == 'table' then
    for _, v in ipairs(config.config.allowed_path) do
      if type(v) == 'string' and #v > 0 then
        if vim.startswith(normalized_cwd, vim.fs.normalize(v)) then
          is_allowed_path = true
          break
        end
      end
    end
  elseif
    type(config.config.allowed_path) == 'string'
    and #config.config.allowed_path > 0
  then
    is_allowed_path = vim.startswith(
      normalized_cwd,
      vim.fs.normalize(config.config.allowed_path)
    )
  end

  if not is_allowed_path then
    return {
      error = 'Cannot run git_rebase in non-allowed path.',
    }
  end

  if not is_git_available() then
    return {
      error = 'git is not installed or not in PATH.',
    }
  end

  local cmd = { 'git', '-C', ctx.cwd, 'rebase' }

  if action.abort then
    table.insert(cmd, '--abort')
  elseif action.continue then
    -- Set core.editor=true to avoid editor opening during rebase --continue
    table.insert(cmd, 2, 'core.editor=true')
    table.insert(cmd, 2, '-c')
    table.insert(cmd, '--continue')
  elseif action.skip then
    table.insert(cmd, '--skip')
  else
    if not action.branch then
      return {
        error = 'Branch name is required for rebase (or use abort/continue/skip).',
      }
    end
    table.insert(cmd, action.branch)
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
          error = string.format('Git rebase cancelled (signal: %d)', signal),
          jobid = id,
        })
        return
      end

      local output = table.concat(stdout, '\n')
      local error_output = table.concat(stderr, '\n')

      if code == 0 then
        local summary = 'Git rebase successful.\n\n'
        summary = summary .. 'Command: ' .. table.concat(cmd, ' ') .. '\n\n'

        if #output > 0 and output ~= '\n' then
          summary = summary .. output
        elseif action.abort then
          summary = summary .. 'Rebase aborted successfully.'
        elseif action.continue then
          summary = summary .. 'Rebase continued successfully.'
        elseif action.skip then
          summary = summary .. 'Commit skipped and rebase continued.'
        else
          summary = summary .. 'Branch rebased successfully.'
        end

        ctx.callback({
          content = summary,
          jobid = id,
        })
      else
        ctx.callback({
          error = string.format(
            'Failed to run git rebase (exit %d):\n%s\n%s',
            code,
            table.concat(cmd, ' '),
            error_output
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

function M.scheme()
  return {
    type = 'function',
    ['function'] = {
      name = 'git_rebase',
      description = [[
Rebase current branch onto another branch.

This tool executes git rebase to reapply commits on top of another base branch.
Rebase rewrites commit history, creating a linear project history.

USAGE:
- @git_rebase branch="main"                    # Rebase current branch onto main
- @git_rebase branch="feature-x"               # Rebase onto feature-x
- @git_rebase abort=true                       # Abort current rebase
- @git_rebase continue=true                    # Continue after conflict resolution
- @git_rebase skip=true                        # Skip current commit and continue

EXAMPLES:
- @git_rebase branch="main"
- @git_rebase branch="develop"
- @git_rebase abort=true
- @git_rebase continue=true
- @git_rebase skip=true

NOTES:
- Requires git to be installed and in PATH.
- Rebase rewrites history. Use with caution on shared branches.
- Use abort to cancel an in-progress rebase after conflicts.
- Use continue after resolving rebase conflicts (--continue).
- Use skip to skip the current commit that has conflicts (--skip).
- Unlike merge, rebase creates a linear history without merge commits.
      ]],
      parameters = {
        type = 'object',
        properties = {
          branch = {
            type = 'string',
            description = 'Branch to rebase onto',
          },
          abort = {
            type = 'boolean',
            description = 'Abort the current rebase (--abort)',
          },
          continue = {
            type = 'boolean',
            description = 'Continue the current rebase after resolving conflicts (--continue)',
          },
          skip = {
            type = 'boolean',
            description = 'Skip the current commit and continue rebase (--skip)',
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
    local parts = { 'git_rebase' }
    if args.branch then
      table.insert(parts, string.format('branch="%s"', args.branch))
    end
    if args.abort then
      table.insert(parts, 'abort=true')
    end
    if args.continue then
      table.insert(parts, 'continue=true')
    end
    if args.skip then
      table.insert(parts, 'skip=true')
    end
    return table.concat(parts, ' ')
  end
  return 'git_rebase'
end

return M

