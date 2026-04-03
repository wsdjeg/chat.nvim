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

---@class ChatToolsGitMergeAction
---@field branch? string Branch to merge
---@field message? string Merge message
---@field no_ff? boolean Create a merge commit even if fast-forward is possible (--no-ff)
---@field ff_only? boolean Abort if fast-forward is not possible (--ff-only)
---@field abort? boolean Abort the current merge (--abort)
---@field continue? boolean Continue the current merge after resolving conflicts (--continue)

---@param action ChatToolsGitMergeAction
---@param ctx ChatToolContext
function M.git_merge(action, ctx)
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
      error = 'Cannot run git_merge in non-allowed path.',
    }
  end

  if not is_git_available() then
    return {
      error = 'git is not installed or not in PATH.',
    }
  end

  local cmd = { 'git', '-C', ctx.cwd, 'merge' }

  if action.abort then
    table.insert(cmd, '--abort')
  elseif action.continue then
    table.insert(cmd, '--continue')
  else
    if action.no_ff then
      table.insert(cmd, '--no-ff')
    elseif action.ff_only then
      table.insert(cmd, '--ff-only')
    end

    if action.message and #action.message > 0 then
      table.insert(cmd, '-m')
      table.insert(cmd, action.message)
    end

    if not action.branch then
      return {
        error = 'Branch name is required for merge',
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
          error = string.format('Git merge cancelled (signal: %d)', signal),
          jobid = id,
        })
        return
      end

      local output = table.concat(stdout, '\n')
      local error_output = table.concat(stderr, '\n')

      if code == 0 then
        local summary = 'Git merge successful.\n\n'
        summary = summary .. 'Command: ' .. table.concat(cmd, ' ') .. '\n\n'

        if #output > 0 and output ~= '\n' then
          summary = summary .. output
        elseif action.abort then
          summary = summary .. 'Merge aborted successfully.'
        elseif action.continue then
          summary = summary .. 'Merge continued successfully.'
        else
          summary = summary .. 'Branch merged successfully.'
        end

        ctx.callback({
          content = summary,
          jobid = id,
        })
      else
        ctx.callback({
          error = string.format(
            'Failed to run git merge (exit %d):\n%s\n%s',
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
      name = 'git_merge',
      description = [[
Merge branches.

This tool executes git merge to integrate changes from another branch
into the current branch.

USAGE:
- @git_merge branch="feature-x"                         # Merge feature branch
- @git_merge branch="main" message="Merge main branch"  # Merge with custom message
- @git_merge branch="feature" no_ff=true                # Force merge commit
- @git_merge branch="main" ff_only=true                 # Fast-forward only
- @git_merge abort=true                                 # Abort current merge
- @git_merge continue=true                              # Continue after conflict resolution

EXAMPLES:
- @git_merge branch="feature-x"
- @git_merge branch="develop" message="Update from develop"
- @git_merge branch="main" no_ff=true
- @git_merge abort=true
- @git_merge continue=true

NOTES:
- Requires git to be installed and in PATH.
- Use no_ff to create a merge commit even if fast-forward is possible.
- Use ff_only to abort if fast-forward is not possible.
- Use abort to cancel an ongoing merge after conflicts.
- Use continue after resolving merge conflicts.
      ]],
      parameters = {
        type = 'object',
        properties = {
          branch = {
            type = 'string',
            description = 'Branch to merge',
          },
          message = {
            type = 'string',
            description = 'Merge commit message',
          },
          no_ff = {
            type = 'boolean',
            description = 'Create a merge commit even if fast-forward is possible (--no-ff)',
          },
          ff_only = {
            type = 'boolean',
            description = 'Abort if fast-forward is not possible (--ff-only)',
          },
          abort = {
            type = 'boolean',
            description = 'Abort the current merge (--abort)',
          },
          continue = {
            type = 'boolean',
            description = 'Continue the current merge after resolving conflicts (--continue)',
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
    local parts = { 'git_merge' }
    if args.branch then
      table.insert(parts, string.format('branch="%s"', args.branch))
    end
    if args.message then
      table.insert(parts, string.format('message="%s"', args.message))
    end
    if args.no_ff then
      table.insert(parts, 'no_ff=true')
    end
    if args.ff_only then
      table.insert(parts, 'ff_only=true')
    end
    if args.abort then
      table.insert(parts, 'abort=true')
    end
    if args.continue then
      table.insert(parts, 'continue=true')
    end
    return table.concat(parts, ' ')
  end
  return 'git_merge'
end

return M

