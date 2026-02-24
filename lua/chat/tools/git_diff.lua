local M = {}

local config = require('chat.config')
local util = require('chat.util')

-- Cache git availability check
local git_available = nil
local function is_git_available()
  if git_available == nil then
    local git_check = vim.fn.system({ 'git', '--version' })
    git_available = vim.v.shell_error == 0
  end
  return git_available
end

---@class ChatToolsGitDiffAction
---@field path? string
---@field cached? boolean
---@field branch? string

---@param action ChatToolsGitDiffAction
---@param ctx ChatToolContext
function M.git_diff(action, ctx)
  -- Check if git is available
  if not is_git_available() then
    return {
      error = 'git is not installed or not in PATH. Please install git first.',
    }
  end

  -- Build git command
  local cmd = { 'git', 'diff' }

  -- Add cached flag if requested
  if action.cached then
    table.insert(cmd, '--cached')
  end

  -- Add branch if specified
  if action.branch and type(action.branch) == 'string' then
    table.insert(cmd, action.branch)
  end

  -- Add path if specified
  local resolved_path = nil
  if action.path and type(action.path) == 'string' then
    resolved_path = util.resolve(action.path, ctx.cwd)
    table.insert(cmd, resolved_path)
  end

  -- Execute command
  local result
  local exit_code

  if vim.system then
    local job = vim.system(cmd, {
      text = true,
    })
    local system_result = job:wait()
    result = system_result.stdout or system_result.stderr or ''
    exit_code = system_result.code
  else
    result = vim.fn.system(cmd)
    exit_code = vim.v.shell_error
  end

  -- Process results
  if exit_code == 0 then
    if result == '' then
      result = 'No changes found.'
    end
    
    local summary = string.format(
      'Git diff output for: %s\n\n',
      resolved_path or 'repository'
    )
    
    if action.cached then
      summary = summary .. '(showing staged changes)\n\n'
    end
    
    if action.branch then
      summary = summary .. string.format('(comparing with branch: %s)\n\n', action.branch)
    end
    
    return {
      content = summary .. result,
    }
  else
    local error_msg = string.format(
      'Failed to run git diff (exit code: %d): %s\n\nCommand: %s\n\nError output: %s',
      exit_code,
      resolved_path or '(no path)',
      table.concat(cmd, ' '),
      result
    )
    return {
      error = error_msg,
    }
  end
end

function M.scheme()
  return {
    type = 'function',
    ['function'] = {
      name = 'git_diff',
      description = [[
        Run git diff on a specified path or the entire repository.

        This tool executes git diff to show changes between working directory and index,
        or between commits, branches, etc.

        USAGE:
        - @git_diff <path>          # Show changes for specific file/directory
        - @git_diff                 # Show all changes in repository
        - @git_diff cached=true     # Show staged changes (--cached)
        - @git_diff branch="main"   # Compare with another branch

        EXAMPLES:
        - @git_diff ./src/main.lua
        - @git_diff
        - @git_diff cached=true
        - @git_diff branch="origin/main" path="./src"

        NOTES:
        - Requires git to be installed and in PATH.
        - If no path is provided, shows all changes in repository.
        - The cached flag shows changes that are staged (git diff --cached).
        - The branch parameter allows comparing with another branch (git diff <branch>).
        ]],
      parameters = {
        type = 'object',
        properties = {
          path = {
            type = 'string',
            description = 'File or directory path to show diff for (optional)',
          },
          cached = {
            type = 'boolean',
            description = 'Show staged changes (git diff --cached) (optional)',
          },
          branch = {
            type = 'string',
            description = 'Branch to compare against (optional)',
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
    local info_parts = { 'git_diff' }
    if arguments.path then
      table.insert(info_parts, string.format('"%s"', arguments.path))
    end
    if arguments.cached then
      table.insert(info_parts, 'cached=true')
    end
    if arguments.branch then
      table.insert(info_parts, string.format('branch="%s"', arguments.branch))
    end
    return table.concat(info_parts, ' ')
  else
    return 'git_diff'
  end
end

return M

