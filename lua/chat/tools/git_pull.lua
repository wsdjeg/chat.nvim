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

---@class ChatToolsGitPullAction
---@field remote? string Remote name (default: "origin")
---@field branch? string Branch name to pull
---@field rebase? boolean Use rebase instead of merge
---@field force? boolean Force pull (with --force)

---@param action ChatToolsGitPullAction
---@param ctx ChatToolContext
function M.git_pull(action, ctx)
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
      error = 'Cannot run git_pull in non-allowed path.',
    }
  end

  if not is_git_available() then
    return {
      error = 'git is not installed or not in PATH.',
    }
  end

  -- Build git command
  local cmd = { 'git', '-C', ctx.cwd, 'pull' }

  -- Add options
  if action.rebase then
    table.insert(cmd, '--rebase')
  end

  if action.force then
    table.insert(cmd, '--force')
  end

  -- Add remote and branch
  if action.remote then
    table.insert(cmd, action.remote)
  end

  if action.branch then
    if not action.remote then
      table.insert(cmd, 'origin')
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
          error = string.format('Git pull cancelled (signal: %d)', signal),
          jobid = id,
        })
        return
      end

      local output = table.concat(stdout, '\n')
      local error_output = table.concat(stderr, '\n')

      if code == 0 then
        local summary = 'Git pull successful.\n\n'

        -- Build command summary
        local parts = { 'git pull' }
        if action.rebase then
          table.insert(parts, '--rebase')
        end
        if action.force then
          table.insert(parts, '--force')
        end
        if action.remote then
          table.insert(parts, action.remote)
        end
        if action.branch then
          if not action.remote then
            table.insert(parts, 'origin')
          end
          table.insert(parts, action.branch)
        end

        summary = summary .. 'Command: ' .. table.concat(parts, ' ') .. '\n\n'

        if #output > 0 and output ~= '\n' then
          summary = summary .. output
        else
          summary = summary .. 'Already up to date.'
        end

        ctx.callback({
          content = summary,
          jobid = id,
        })
      else
        ctx.callback({
          error = string.format(
            'Failed to run git pull (exit %d):\n%s\n%s',
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
      name = 'git_pull',
      description = [[
Pull changes from remote repository and merge.

This tool executes git pull to fetch and integrate changes from a remote repository.

USAGE:
- @git_pull                           # Pull from origin (current branch)
- @git_pull branch="main"             # Pull specific branch from origin
- @git_pull remote="upstream"         # Pull from different remote
- @git_pull rebase=true               # Use rebase instead of merge
- @git_pull force=true                # Force pull

EXAMPLES:
- @git_pull
- @git_pull branch="main"
- @git_pull remote="upstream" branch="main"
- @git_pull rebase=true
- @git_pull force=true

NOTES:
- Requires git to be installed and in PATH.
- Default remote is "origin" if not specified.
- Use rebase=true to avoid merge commits.
- Use force=true with caution (overwrites local changes).
      ]],
      parameters = {
        type = 'object',
        properties = {
          remote = {
            type = 'string',
            description = 'Remote name (optional)',
          },
          branch = {
            type = 'string',
            description = 'Branch name to pull (optional)',
          },
          rebase = {
            type = 'boolean',
            description = 'Use rebase instead of merge (--rebase)',
          },
          force = {
            type = 'boolean',
            description = 'Force pull (--force)',
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
    local parts = { 'git_pull' }
    if args.remote then
      table.insert(parts, string.format('remote="%s"', args.remote))
    end
    if args.branch then
      table.insert(parts, string.format('branch="%s"', args.branch))
    end
    if args.rebase then
      table.insert(parts, 'rebase=true')
    end
    if args.force then
      table.insert(parts, 'force=true')
    end
    return table.concat(parts, ' ')
  end
  return 'git_pull'
end

return M

