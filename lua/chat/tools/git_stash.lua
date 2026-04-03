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

---@class ChatToolsGitStashAction
---@field action? string Action type: "save", "list", "pop", "drop", "apply", "clear"
---@field message? string Message for save action
---@field index? number Stash index (default: 0 for most recent)

---@param action ChatToolsGitStashAction
---@param ctx ChatToolContext
function M.git_stash(action, ctx)
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
      error = 'Cannot run git_stash in non-allowed path.',
    }
  end

  if not is_git_available() then
    return {
      error = 'git is not installed or not in PATH.',
    }
  end

  local cmd = { 'git', '-C', ctx.cwd, 'stash' }
  local act = action.action or 'save'

  if act == 'save' then
    table.insert(cmd, 'push')
    if action.message and #action.message > 0 then
      table.insert(cmd, '-m')
      table.insert(cmd, action.message)
    end
  elseif act == 'list' then
    table.insert(cmd, 'list')
  elseif act == 'pop' then
    table.insert(cmd, 'pop')
    if action.index then
      table.insert(cmd, 'stash@{' .. action.index .. '}')
    end
  elseif act == 'drop' then
    table.insert(cmd, 'drop')
    if action.index then
      table.insert(cmd, 'stash@{' .. action.index .. '}')
    else
      table.insert(cmd, 'stash@{0}')
    end
  elseif act == 'apply' then
    table.insert(cmd, 'apply')
    if action.index then
      table.insert(cmd, 'stash@{' .. action.index .. '}')
    end
  elseif act == 'clear' then
    table.insert(cmd, 'clear')
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
          error = string.format('Git stash cancelled (signal: %d)', signal),
          jobid = id,
        })
        return
      end

      local output = table.concat(stdout, '\n')
      local error_output = table.concat(stderr, '\n')

      if code == 0 then
        local summary = 'Git stash ' .. act .. ' successful.\n\n'
        summary = summary .. 'Command: ' .. table.concat(cmd, ' ') .. '\n\n'

        if #output > 0 and output ~= '\n' then
          summary = summary .. output
        elseif act == 'save' then
          summary = summary .. 'Changes saved to stash.'
        elseif act == 'drop' then
          summary = summary .. 'Stash dropped.'
        elseif act == 'clear' then
          summary = summary .. 'All stashes cleared.'
        end

        ctx.callback({
          content = summary,
          jobid = id,
        })
      else
        ctx.callback({
          error = string.format(
            'Failed to run git stash %s (exit %d):\n%s\n%s',
            act,
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
      name = 'git_stash',
      description = [[
Stash changes in git repository.

This tool manages git stash to temporarily store changes.

USAGE:
- @git_stash action="save" message="WIP"          # Save current changes
- @git_stash action="list"                        # List all stashes
- @git_stash action="pop" index=0                 # Apply and remove stash
- @git_stash action="apply" index=0               # Apply without removing
- @git_stash action="drop" index=0                # Delete a stash
- @git_stash action="clear"                       # Remove all stashes

EXAMPLES:
- @git_stash action="save" message="Work in progress"
- @git_stash action="list"
- @git_stash action="pop"                        # Pop latest stash
- @git_stash action="drop" index=2               # Drop stash at index 2
- @git_stash action="apply" index=1              # Apply stash at index 1

NOTES:
- Requires git to be installed and in PATH.
- Index 0 is the most recent stash.
- Use apply to keep stash for later use, pop to remove after applying.
      ]],
      parameters = {
        type = 'object',
        properties = {
          action = {
            type = 'string',
            description = 'Action type: save, list, pop, drop, apply, clear (default: save)',
            enum = { 'save', 'list', 'pop', 'drop', 'apply', 'clear' },
          },
          message = {
            type = 'string',
            description = 'Message for save action',
          },
          index = {
            type = 'number',
            description = 'Stash index (default: 0 for most recent)',
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
    local parts = { 'git_stash' }
    if args.action then
      table.insert(parts, string.format('action="%s"', args.action))
    end
    if args.message then
      table.insert(parts, string.format('message="%s"', args.message))
    end
    if args.index then
      table.insert(parts, string.format('index=%d', args.index))
    end
    return table.concat(parts, ' ')
  end
  return 'git_stash'
end

return M

