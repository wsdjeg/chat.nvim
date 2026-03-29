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

---@class ChatToolsGitPushAction
---@field remote? string Remote name (default: "origin")
---@field branch? string Branch name to push
---@field set_upstream? boolean Set upstream for the branch (-u)
---@field force? boolean Force push (--force)
---@field all? boolean Push all branches (--all)
---@field tags? boolean Push tags (--tags)

---@param action ChatToolsGitPushAction
---@param ctx ChatToolContext
function M.git_push(action, ctx)
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
      error = 'Cannot run git_push in non-allowed path.',
    }
  end

  if not is_git_available() then
    return {
      error = 'git is not installed or not in PATH.',
    }
  end

  -- Build git command
  local cmd = { 'git', '-C', ctx.cwd, 'push' }

  -- Add options
  if action.force then
    table.insert(cmd, '--force')
  end

  if action.set_upstream then
    table.insert(cmd, '-u')
  end

  if action.all then
    table.insert(cmd, '--all')
  end

  if action.tags then
    table.insert(cmd, '--tags')
  end

  -- Add remote and branch
  local remote = action.remote or 'origin'
  table.insert(cmd, remote)

  if action.branch and not action.all then
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
          error = string.format('Git push cancelled (signal: %d)', signal),
          jobid = id,
        })
        return
      end

      local output = table.concat(stdout, '\n')
      local error_output = table.concat(stderr, '\n')

      if code == 0 then
        local summary = 'Git push successful.\n\n'

        -- Build command summary
        local parts = { 'git push' }
        if action.force then
          table.insert(parts, '--force')
        end
        if action.set_upstream then
          table.insert(parts, '-u')
        end
        if action.all then
          table.insert(parts, '--all')
        end
        if action.tags then
          table.insert(parts, '--tags')
        end
        table.insert(parts, remote)
        if action.branch and not action.all then
          table.insert(parts, action.branch)
        end

        summary = summary .. 'Command: ' .. table.concat(parts, ' ') .. '\n\n'

        if #output > 0 and output ~= '\n' then
          summary = summary .. output
        end

        ctx.callback({
          content = summary,
          jobid = id,
        })
      else
        ctx.callback({
          error = string.format(
            'Failed to run git push (exit %d):\n%s\n%s',
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
      name = 'git_push',
      description = [[
Push commits to remote repository.

This tool executes git push to upload local commits to a remote repository.

USAGE:
- @git_push                           # Push to origin (current branch)
- @git_push branch="main"             # Push specific branch
- @git_push remote="upstream"         # Push to different remote
- @git_push set_upstream=true         # Set upstream (-u)
- @git_push force=true                # Force push
- @git_push all=true                  # Push all branches
- @git_push tags=true                 # Push tags

EXAMPLES:
- @git_push branch="feature-x"
- @git_push remote="origin" branch="main"
- @git_push set_upstream=true branch="new-branch"
- @git_push force=true branch="main"
- @git_push all=true
- @git_push tags=true

NOTES:
- Requires git to be installed and in PATH.
- Default remote is "origin".
- Use set_upstream=true to track remote branch.
- Use force=true with caution (rewrites history).
- Use all=true to push all branches at once.
- Use tags=true to push all tags.
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
            description = 'Branch name to push',
          },
          set_upstream = {
            type = 'boolean',
            description = 'Set upstream for the branch (-u)',
          },
          force = {
            type = 'boolean',
            description = 'Force push (--force)',
          },
          all = {
            type = 'boolean',
            description = 'Push all branches (--all)',
          },
          tags = {
            type = 'boolean',
            description = 'Push tags (--tags)',
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
    local parts = { 'git_push' }
    if args.remote then
      table.insert(parts, string.format('remote="%s"', args.remote))
    end
    if args.branch then
      table.insert(parts, string.format('branch="%s"', args.branch))
    end
    if args.set_upstream then
      table.insert(parts, 'set_upstream=true')
    end
    if args.force then
      table.insert(parts, 'force=true')
    end
    if args.all then
      table.insert(parts, 'all=true')
    end
    if args.tags then
      table.insert(parts, 'tags=true')
    end
    return table.concat(parts, ' ')
  end
  return 'git_push'
end

return M
