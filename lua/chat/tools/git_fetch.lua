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

---@class ChatToolsGitFetchAction
---@field remote? string Remote name (default: "origin")
---@field branch? string Branch name to fetch
---@field all? boolean Fetch all remotes (--all)
---@field prune? boolean Remove local branches that no longer exist on remote (--prune)
---@field tags? boolean Fetch all tags (--tags)

---@param action ChatToolsGitFetchAction
---@param ctx ChatToolContext
function M.git_fetch(action, ctx)
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
      error = 'Cannot run git_fetch in non-allowed path.',
    }
  end

  if not is_git_available() then
    return {
      error = 'git is not installed or not in PATH.',
    }
  end

  local cmd = { 'git', '-C', ctx.cwd, 'fetch' }

  if action.all then
    table.insert(cmd, '--all')
  end

  if action.prune then
    table.insert(cmd, '--prune')
  end

  if action.tags then
    table.insert(cmd, '--tags')
  end

  if not action.all then
    local remote = action.remote or 'origin'
    table.insert(cmd, remote)

    if action.branch then
      table.insert(cmd, action.branch)
    end
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
          error = string.format('Git fetch cancelled (signal: %d)', signal),
          jobid = id,
        })
        return
      end

      local output = table.concat(stdout, '\n')
      local error_output = table.concat(stderr, '\n')

      if code == 0 then
        local summary = 'Git fetch successful.\n\n'
        summary = summary .. 'Command: ' .. table.concat(cmd, ' ') .. '\n\n'

        if #output > 0 and output ~= '\n' then
          summary = summary .. output
        else
          summary = summary .. 'Remote changes fetched successfully.'
        end

        ctx.callback({
          content = summary,
          jobid = id,
        })
      else
        ctx.callback({
          error = string.format(
            'Failed to run git fetch (exit %d):\n%s\n%s',
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
      name = 'git_fetch',
      description = [[
Fetch changes from remote repository.

This tool executes git fetch to download changes from a remote repository
without merging them into the current branch.

USAGE:
- @git_fetch                           # Fetch from origin (default)
- @git_fetch remote="upstream"         # Fetch from specific remote
- @git_fetch branch="main"             # Fetch specific branch
- @git_fetch all=true                  # Fetch all remotes
- @git_fetch prune=true                # Remove deleted remote branches
- @git_fetch tags=true                 # Fetch all tags

EXAMPLES:
- @git_fetch
- @git_fetch remote="upstream" branch="main"
- @git_fetch all=true prune=true
- @git_fetch tags=true

NOTES:
- Requires git to be installed and in PATH.
- Default remote is "origin" if not specified.
- Unlike git_pull, this does not merge changes into your current branch.
- Use prune=true to clean up local branches that were deleted on remote.
      ]],
      parameters = {
        type = 'object',
        properties = {
          remote = {
            type = 'string',
            description = 'Remote name (default: "origin")',
          },
          branch = {
            type = 'string',
            description = 'Branch name to fetch',
          },
          all = {
            type = 'boolean',
            description = 'Fetch all remotes (--all)',
          },
          prune = {
            type = 'boolean',
            description = 'Remove local branches that no longer exist on remote (--prune)',
          },
          tags = {
            type = 'boolean',
            description = 'Fetch all tags (--tags)',
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
    local parts = { 'git_fetch' }
    if args.remote then
      table.insert(parts, string.format('remote="%s"', args.remote))
    end
    if args.branch then
      table.insert(parts, string.format('branch="%s"', args.branch))
    end
    if args.all then
      table.insert(parts, 'all=true')
    end
    if args.prune then
      table.insert(parts, 'prune=true')
    end
    if args.tags then
      table.insert(parts, 'tags=true')
    end
    return table.concat(parts, ' ')
  end
  return 'git_fetch'
end

return M

