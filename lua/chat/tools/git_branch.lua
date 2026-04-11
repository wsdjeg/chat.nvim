local M = {}

local job = require('job')
local util = require('chat.util')

-- Cache git availability check
local git_available = nil
local function is_git_available()
  if git_available == nil then
    git_available = vim.fn.executable('git') == 1
  end
  return git_available
end

---@class ChatToolsGitBranchAction
---@field list? boolean List all branches (default: true if no branch specified)
---@field all? boolean List all branches including remote ones
---@field branch? string Branch name to create or switch to
---@field create? boolean Create a new branch
---@field delete? boolean Delete a branch
---@field force? boolean Force delete or reset
---@field track? boolean Set up tracking relationship

---@param action ChatToolsGitBranchAction
---@param ctx ChatToolContext
function M.git_branch(action, ctx)
  if not util.is_allowed_path(ctx.cwd) then
    return {
      error = 'Cannot run git_branch in non-allowed path.',
    }
  end

  if not is_git_available() then
    return {
      error = 'git is not installed or not in PATH.',
    }
  end

  -- Build git command
  local cmd = { 'git', '-C', ctx.cwd, 'branch' }

  -- Check if this is a list or modify operation
  if (action.list or not action.branch) and not action.create and not action.delete then
    -- List operation
    if action.all then
      table.insert(cmd, '-a')
    end
    if action.force then
      table.insert(cmd, '--format=%(refname:short) %(upstream:short)')
    end
  else
    -- Modify operation
    if action.delete then
      table.insert(cmd, '-d')
    elseif action.create and action.branch then
      -- Already in branch creation mode
    end

    if action.force then
      if action.delete then
        cmd[#cmd] = '-D' -- Force delete uses -D
      else
        table.insert(cmd, '--force')
      end
    end

    if action.track and action.branch then
      table.insert(cmd, '--track')
    end

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
          error = string.format('Git branch cancelled (signal: %d)', signal),
          jobid = id,
        })
        return
      end

      local output = table.concat(stdout, '\n')
      local error_output = table.concat(stderr, '\n')

      if code == 0 then
        local summary = ''

        -- List operation
        if (action.list or not action.branch) and not action.delete and not action.create then
          summary = 'Git branches:\n\n'
          if #output > 0 then
            output = M.format_branches(output, action.all)
          end
        else
          -- Modify operation
          if action.delete then
            summary = 'Branch deleted successfully:\n\n'
          elseif action.create then
            summary = 'Branch created successfully:\n\n'
          else
            summary = 'Operation completed successfully:\n\n'
          end
        end

        ctx.callback({
          content = summary .. output,
          jobid = id,
        })
      else
        ctx.callback({
          error = string.format(
            'Failed (exit %d): %s\n%s',
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

function M.format_branches(output, all)
  local lines = vim.split(output, '\n')
  local result = {}
  local current_branch = nil

  for _, line in ipairs(lines) do
    line = line:gsub('^%s*', '')
    if line ~= '' then
      local is_current = line:match('^%*')
      local branch_name = line:match('%*?%s*(.+)$')
      
      if is_current then
        current_branch = branch_name
        table.insert(result, '→ ' .. branch_name .. ' (current)')
      else
        -- Check if this is a remote branch
        if all and branch_name:match('^remotes/') then
          local remote_branch = branch_name:match('^remotes/(.+)$')
          table.insert(result, '  ' .. remote_branch .. ' (remote)')
        else
          table.insert(result, '  ' .. branch_name)
        end
      end
    end
  end

  table.insert(result, 1, string.format('Current: %s\n', current_branch or 'HEAD'))
  return table.concat(result, '\n')
end

function M.scheme()
  return {
    type = 'function',
    ['function'] = {
      name = 'git_branch',
      description = [[
Manage git branches.

USAGE:
- @git_branch                          # List local branches
- @git_branch all=true                 # List all branches including remote
- @git_branch branch="feature-x" create=true   # Create new branch
- @git_branch branch="old-feature" delete=true # Delete branch
- @git_branch force=true               # Force delete or reset

EXAMPLES:
- @git_branch                    # List branches
- @git_branch all=true           # List all local and remote branches
- @git_branch branch="new-feature" create=true  # Create new branch
- @git_branch branch="old-feature" delete=true  # Delete branch
- @git_branch branch="bugfix" create=true force=true  # Force create/reset
- @git_branch branch="temp" delete=true force=true  # Force delete

NOTES:
- Requires git to be installed and in PATH.
- Default action is list if no branch specified.
- Use create=true to create a new branch from current HEAD.
- Use delete=true to delete a branch (uses -d, safe delete).
- Use force=true with delete for -D (force delete).
- Use all=true to show remote branches in list mode.
      ]],
      parameters = {
        type = 'object',
        properties = {
          list = {
            type = 'boolean',
            description = 'List branches (default: true if no branch specified)',
          },
          all = {
            type = 'boolean',
            description = 'List all branches including remote ones (-a)',
          },
          branch = {
            type = 'string',
            description = 'Branch name to create or delete',
          },
          create = {
            type = 'boolean',
            description = 'Create a new branch',
          },
          delete = {
            type = 'boolean',
            description = 'Delete a branch',
          },
          force = {
            type = 'boolean',
            description = 'Force delete or reset',
          },
          track = {
            type = 'boolean',
            description = 'Set up tracking relationship',
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
    local parts = { 'git_branch' }
    
    if args.list and not args.branch then
      if args.all then
        table.insert(parts, 'all=true')
      end
      return table.concat(parts, ' ')
    end
    
    if args.branch then
      table.insert(parts, string.format('branch="%s"', args.branch))
    end
    
    if args.create then
      table.insert(parts, 'create=true')
    end
    
    if args.delete then
      table.insert(parts, 'delete=true')
    end
    
    if args.force then
      table.insert(parts, 'force=true')
    end
    
    return table.concat(parts, ' ')
  end
  return 'git_branch'
end

return M

