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

---@class ChatToolsGitCheckoutAction
---@field branch? string Branch name to checkout
---@field new_branch? string Create and checkout a new branch
---@field file? string File path to restore
---@field force? boolean Force checkout
---@field track? boolean Set up tracking for remote branch
---@field detach? boolean Detached HEAD (checkout commit or tag)

---@param action ChatToolsGitCheckoutAction
---@param ctx ChatToolContext
function M.git_checkout(action, ctx)
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
      error = 'Cannot run git_checkout in non-allowed path.',
    }
  end

  if not is_git_available() then
    return {
      error = 'git is not installed or not in PATH.',
    }
  end

  -- Build git command
  local cmd = { 'git', '-C', ctx.cwd, 'checkout' }

  -- Add options
  if action.force then
    table.insert(cmd, '--force')
  end

  if action.track then
    table.insert(cmd, '--track')
  end

  if action.detach then
    table.insert(cmd, '--detach')
  end

  -- Determine target
  if action.new_branch then
    table.insert(cmd, '-b')
    table.insert(cmd, action.new_branch)
  elseif action.branch then
    table.insert(cmd, action.branch)
  elseif action.file then
    -- Restore file
    table.insert(cmd, '--')
    table.insert(cmd, action.file)
  else
    return {
      error = 'Must specify either branch, new_branch, or file to checkout.',
    }
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
          error = string.format('Git checkout cancelled (signal: %d)', signal),
          jobid = id,
        })
        return
      end

      local output = table.concat(stdout, '\n')
      local error_output = table.concat(stderr, '\n')

      if code == 0 then
        local summary = 'Git checkout successful.\n\n'

        -- Build command summary
        local parts = { 'git checkout' }
        if action.force then
          table.insert(parts, '--force')
        end
        if action.track then
          table.insert(parts, '--track')
        end
        if action.detach then
          table.insert(parts, '--detach')
        end
        if action.new_branch then
          table.insert(parts, '-b')
          table.insert(parts, action.new_branch)
        elseif action.branch then
          table.insert(parts, action.branch)
        elseif action.file then
          table.insert(parts, '-- ' .. action.file)
        end

        summary = summary .. 'Command: ' .. table.concat(parts, ' ') .. '\n\n'

        if #output > 0 and output ~= '\n' then
          summary = summary .. output
        else
          if action.new_branch then
            summary = summary .. 'Switched to new branch: ' .. action.new_branch
          elseif action.branch then
            summary = summary .. 'Switched to branch: ' .. action.branch
          elseif action.file then
            summary = summary .. 'Restored: ' .. action.file
          end
        end

        ctx.callback({
          content = summary,
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

function M.scheme()
  return {
    type = 'function',
    ['function'] = {
      name = 'git_checkout',
      description = [[
Switch branches or restore working tree files.

This tool executes git checkout to switch branches, create new branches, or restore files.

USAGE:
- @git_checkout branch="main"                 # Switch to existing branch
- @git_checkout new_branch="feature-x"        # Create and checkout new branch
- @git_checkout branch="origin/feature" track=true  # Track remote branch
- @git_checkout file="src/main.lua"           # Restore file from HEAD
- @git_checkout branch="v1.0.0" detach=true   # Checkout commit/tag (detached HEAD)
- @git_checkout force=true                    # Force checkout

EXAMPLES:
- @git_checkout branch="develop"              # Switch to develop branch
- @git_checkout new_branch="bugfix/login"     # Create new branch
- @git_checkout file="README.md"              # Restore file
- @git_checkout branch="feature" force=true   # Force switch (discard changes)
- @git_checkout branch="origin/main" track=true  # Track and checkout remote branch

NOTES:
- Requires git to be installed and in PATH.
- Use branch for switching to existing branches or commits.
- Use new_branch to create and checkout a new branch (-b).
- Use file to restore specific files from HEAD.
- Use track=true to set up upstream tracking for remote branches.
- Use detach=true when checking out commits or tags for detached HEAD.
- Use force=true to discard local changes when switching branches.
      ]],
      parameters = {
        type = 'object',
        properties = {
          branch = {
            type = 'string',
            description = 'Branch name to checkout',
          },
          new_branch = {
            type = 'string',
            description = 'Create and checkout a new branch (-b)',
          },
          file = {
            type = 'string',
            description = 'File path to restore from HEAD',
          },
          force = {
            type = 'boolean',
            description = 'Force checkout',
          },
          track = {
            type = 'boolean',
            description = 'Set up tracking for remote branch',
          },
          detach = {
            type = 'boolean',
            description = 'Detached HEAD (checkout commit or tag)',
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
    local parts = { 'git_checkout' }
    if args.new_branch then
      table.insert(parts, string.format('new_branch="%s"', args.new_branch))
    elseif args.branch then
      table.insert(parts, string.format('branch="%s"', args.branch))
    elseif args.file then
      table.insert(parts, string.format('file="%s"', args.file))
    end
    if args.force then
      table.insert(parts, 'force=true')
    end
    if args.track then
      table.insert(parts, 'track=true')
    end
    if args.detach then
      table.insert(parts, 'detach=true')
    end
    return table.concat(parts, ' ')
  end
  return 'git_checkout'
end

return M

