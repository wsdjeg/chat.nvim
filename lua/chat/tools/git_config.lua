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

---@class ChatToolsGitConfigAction
---@field action? string Action type: "get", "set", "list", "unset"
---@field key? string Config key (e.g., "user.name" or "user.email")
---@field value? string Config value (for set action)
---@field global? boolean Use global config file
---@field local? boolean Use local config file (default)
---@field system? boolean Use system config file
---@field file? string Use specified config file path

---@param action ChatToolsGitConfigAction
---@param ctx ChatToolContext
function M.git_config(action, ctx)
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
      error = 'Cannot run git_config in non-allowed path.',
    }
  end

  if not is_git_available() then
    return {
      error = 'git is not installed or not in PATH.',
    }
  end

  local cmd = { 'git', '-C', ctx.cwd, 'config' }

  if action.global then
    table.insert(cmd, '--global')
  elseif action.system then
    table.insert(cmd, '--system')
  elseif action.file then
    table.insert(cmd, '--file')
    table.insert(cmd, action.file)
  else
    table.insert(cmd, '--local')
  end

  local act = action.action or 'get'

  if act == 'get' then
    if not action.key then
      return {
        error = 'Key is required for get action',
      }
    end
    table.insert(cmd, action.key)
  elseif act == 'set' then
    if not action.key then
      return {
        error = 'Key is required for set action',
      }
    end
    if not action.value then
      return {
        error = 'Value is required for set action',
      }
    end
    table.insert(cmd, action.key)
    table.insert(cmd, action.value)
  elseif act == 'list' then
    table.insert(cmd, '--list')
  elseif act == 'unset' then
    if not action.key then
      return {
        error = 'Key is required for unset action',
      }
    end
    table.insert(cmd, '--unset')
    table.insert(cmd, action.key)
  else
    return {
      error = 'Invalid action: ' .. act,
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
          error = string.format('Git config cancelled (signal: %d)', signal),
          jobid = id,
        })
        return
      end

      local output = table.concat(stdout, '\n')
      local error_output = table.concat(stderr, '\n')

      if code == 0 then
        local summary = 'Git config ' .. act .. ' successful.\n\n'
        summary = summary .. 'Command: ' .. table.concat(cmd, ' ') .. '\n\n'

        if #output > 0 and output ~= '\n' then
          summary = summary .. output
        else
          if act == 'set' then
            summary = summary .. action.key .. ' = ' .. action.value
          elseif act == 'unset' then
            summary = summary .. action.key .. ' unset successfully.'
          end
        end

        ctx.callback({
          content = summary,
          jobid = id,
        })
      else
        ctx.callback({
          error = string.format(
            'Failed to run git config (exit %d):\n%s\n%s',
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
      name = 'git_config',
      description = [[
Get, set, or list git configuration.

This tool manages git configuration settings.

USAGE:
- @git_config action="get" key="user.name"           # Get user name
- @git_config action="set" key="user.email" value="test@example.com"  # Set user email
- @git_config action="list"                          # List all config
- @git_config action="list" global=true              # List global config
- @git_config action="unset" key="user.name"         # Unset config key

EXAMPLES:
- @git_config action="get" key="user.name"
- @git_config action="set" key="user.email" value="user@example.com"
- @git_config action="list"
- @git_config action="get" key="core.editor" global=true

NOTES:
- Requires git to be installed and in PATH.
- Default scope is local (repository config).
- Use global for user-wide settings.
- Use system for system-wide settings.
- Use file to specify a custom config file path.
      ]],
      parameters = {
        type = 'object',
        properties = {
          action = {
            type = 'string',
            description = 'Action type: get, set, list, or unset (default: get)',
            enum = { 'get', 'set', 'list', 'unset' },
          },
          key = {
            type = 'string',
            description = 'Config key (e.g., "user.name" or "user.email")',
          },
          value = {
            type = 'string',
            description = 'Config value (for set action)',
          },
          global = {
            type = 'boolean',
            description = 'Use global config file',
          },
          local_ = {
            type = 'boolean',
            description = 'Use local config file (default)',
          },
          system = {
            type = 'boolean',
            description = 'Use system config file',
          },
          file = {
            type = 'string',
            description = 'Use specified config file path',
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
    local parts = { 'git_config' }
    if args.action then
      table.insert(parts, string.format('action="%s"', args.action))
    end
    if args.key then
      table.insert(parts, string.format('key="%s"', args.key))
    end
    if args.value then
      table.insert(parts, string.format('value="%s"', args.value))
    end
    if args.global then
      table.insert(parts, 'global=true')
    end
    if args.system then
      table.insert(parts, 'system=true')
    end
    if args.file then
      table.insert(parts, string.format('file="%s"', args.file))
    end
    return table.concat(parts, ' ')
  end
  return 'git_config'
end

return M

