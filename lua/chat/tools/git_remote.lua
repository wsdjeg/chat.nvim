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

local function check_allowed_path(ctx)
  local is_allowed_path = false

  if type(config.config.allowed_path) == 'table' then
    for _, v in ipairs(config.config.allowed_path) do
      if type(v) == 'string' and #v > 0 then
        if vim.startswith(ctx.cwd, vim.fs.normalize(v)) then
          is_allowed_path = true
          break
        end
      end
    end
  elseif
    type(config.config.allowed_path) == 'string'
    and #config.config.allowed_path > 0
  then
    is_allowed_path =
      vim.startswith(ctx.cwd, vim.fs.normalize(config.config.allowed_path))
  end

  return is_allowed_path
end

---@class ChatToolsGitRemoteAction
---@field action "list"|"get-url"
---@field name? string Remote name (required for get-url)
---@field verbose? boolean Show verbose output for list (default: true)
---@field push? boolean Get push URL instead of fetch URL (for get-url)

---@param action ChatToolsGitRemoteAction
---@param ctx ChatToolContext
function M.git_remote(action, ctx)
  if not check_allowed_path(ctx) then
    return {
      error = 'Cannot run git_remote in non-allowed path.',
    }
  end

  if not is_git_available() then
    return {
      error = 'git is not installed or not in PATH.',
    }
  end

  -- Build git command
  local cmd = { 'git', '-C', ctx.cwd, 'remote' }

  local action_type = action.action or 'list'

  if action_type == 'list' then
    -- git remote -v
    if action.verbose ~= false then
      table.insert(cmd, '-v')
    end
  elseif action_type == 'get-url' then
    -- git remote get-url <name>
    if not action.name then
      return { error = 'Remote name is required for get-url action.' }
    end
    table.insert(cmd, 'get-url')
    if action.push then
      table.insert(cmd, '--push')
    end
    table.insert(cmd, action.name)
  else
    return { error = 'Unknown action: ' .. action_type }
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
          error = string.format('Git remote cancelled (signal: %d)', signal),
          jobid = id,
        })
        return
      end

      local output = table.concat(stdout, '\n')
      if #stderr > 0 then
        output = output .. '\n' .. table.concat(stderr, '\n')
      end

      if code == 0 then
        local summary = string.format('Git remote: %s\n\n', action_type)
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

function M.scheme()
  return {
    type = 'function',
    ['function'] = {
      name = 'git_remote',
      description = [[
Manage set of tracked repositories (read-only).

ACTIONS:
- list: List remote repositories (default)
- get-url: Get URL of a remote

EXAMPLES:
- @git_remote                                    # List all remotes
- @git_remote action="list"                      # List all remotes (verbose)
- @git_remote action="get-url" name="origin"     # Get origin URL
- @git_remote action="get-url" name="origin" push=true  # Get push URL
      ]],
      parameters = {
        type = 'object',
        properties = {
          action = {
            type = 'string',
            enum = { 'list', 'get-url' },
            description = 'Action to perform (default: list)',
          },
          name = {
            type = 'string',
            description = 'Remote name (required for get-url)',
          },
          verbose = {
            type = 'boolean',
            description = 'Show verbose output for list (default: true)',
          },
          push = {
            type = 'boolean',
            description = 'Get push URL instead of fetch URL (for get-url)',
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
    local parts = { 'git_remote' }
    local action_type = args.action or 'list'
    table.insert(parts, string.format('action="%s"', action_type))
    if args.name then
      table.insert(parts, string.format('name="%s"', args.name))
    end
    if args.push then
      table.insert(parts, 'push=true')
    end
    return table.concat(parts, ' ')
  end
  return 'git_remote'
end

return M
