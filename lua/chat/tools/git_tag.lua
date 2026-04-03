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

---@class ChatToolsGitTagAction
---@field action? string Action type: "create", "list", "delete", "push"
---@field name? string Tag name
---@field message? string Tag message (for annotated tags)
---@field force? boolean Force tag creation/deletion
---@field remote? string Remote name for push action (default: "origin")

---@param action ChatToolsGitTagAction
---@param ctx ChatToolContext
function M.git_tag(action, ctx)
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
      error = 'Cannot run git_tag in non-allowed path.',
    }
  end

  if not is_git_available() then
    return {
      error = 'git is not installed or not in PATH.',
    }
  end

  local cmd = { 'git', '-C', ctx.cwd }
  local act = action.action or 'list'

  if act == 'create' then
    table.insert(cmd, 'tag')
    if not action.name then
      return {
        error = 'Tag name is required for create action',
      }
    end
    if action.message and #action.message > 0 then
      table.insert(cmd, '-a')
      table.insert(cmd, '-m')
      table.insert(cmd, action.message)
    end
    if action.force then
      table.insert(cmd, '-f')
    end
    table.insert(cmd, action.name)
  elseif act == 'list' then
    table.insert(cmd, 'tag')
    table.insert(cmd, '-l')
  elseif act == 'delete' then
    table.insert(cmd, 'tag')
    table.insert(cmd, '-d')
    if not action.name then
      return {
        error = 'Tag name is required for delete action',
      }
    end
    table.insert(cmd, action.name)
  elseif act == 'push' then
    table.insert(cmd, 'push')
    local remote = action.remote or 'origin'
    table.insert(cmd, remote)
    if not action.name then
      table.insert(cmd, '--tags')
    else
      table.insert(cmd, action.name)
    end
    if action.force then
      table.insert(cmd, '--force')
    end
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
          error = string.format('Git tag cancelled (signal: %d)', signal),
          jobid = id,
        })
        return
      end

      local output = table.concat(stdout, '\n')
      local error_output = table.concat(stderr, '\n')

      if code == 0 then
        local summary = 'Git tag ' .. act .. ' successful.\n\n'
        summary = summary .. 'Command: ' .. table.concat(cmd, ' ') .. '\n\n'

        if #output > 0 and output ~= '\n' then
          summary = summary .. output
        elseif act == 'create' then
          summary = summary .. 'Tag "' .. action.name .. '" created.'
        elseif act == 'delete' then
          summary = summary .. 'Tag "' .. action.name .. '" deleted.'
        elseif act == 'push' then
          if action.name then
            summary = summary .. 'Tag "' .. action.name .. '" pushed.'
          else
            summary = summary .. 'All tags pushed.'
          end
        end

        ctx.callback({
          content = summary,
          jobid = id,
        })
      else
        ctx.callback({
          error = string.format(
            'Failed to run git tag %s (exit %d):\n%s\n%s',
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
      name = 'git_tag',
      description = [[
Manage git tags.

This tool manages git tags for marking specific commits.

USAGE:
- @git_tag action="create" name="v1.0.0" message="Release version 1.0"  # Create annotated tag
- @git_tag action="create" name="v1.0.0"                              # Create lightweight tag
- @git_tag action="list"                                              # List all tags
- @git_tag action="delete" name="v1.0.0"                              # Delete local tag
- @git_tag action="push" name="v1.0.0" remote="origin"                # Push specific tag
- @git_tag action="push" remote="origin"                              # Push all tags

EXAMPLES:
- @git_tag action="create" name="v1.0.0" message="Initial release"
- @git_tag action="list"
- @git_tag action="delete" name="v1.0.0"
- @git_tag action="push" name="v1.0.0"
- @git_tag action="create" name="v1.0.0" force=true  # Overwrite existing tag

NOTES:
- Annotated tags include a message and store metadata.
- Lightweight tags are just pointers to commits.
- Use force=true with caution when overwriting tags.
      ]],
      parameters = {
        type = 'object',
        properties = {
          action = {
            type = 'string',
            description = 'Action type: create, list, delete, push (default: list)',
            enum = { 'create', 'list', 'delete', 'push' },
          },
          name = {
            type = 'string',
            description = 'Tag name',
          },
          message = {
            type = 'string',
            description = 'Tag message (for annotated tags)',
          },
          force = {
            type = 'boolean',
            description = 'Force tag creation/deletion',
          },
          remote = {
            type = 'string',
            description = 'Remote name for push action (default: origin)',
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
    local parts = { 'git_tag' }
    if args.action then
      table.insert(parts, string.format('action="%s"', args.action))
    end
    if args.name then
      table.insert(parts, string.format('name="%s"', args.name))
    end
    if args.message then
      table.insert(parts, string.format('message="%s"', args.message))
    end
    if args.force then
      table.insert(parts, 'force=true')
    end
    if args.remote then
      table.insert(parts, string.format('remote="%s"', args.remote))
    end
    return table.concat(parts, ' ')
  end
  return 'git_tag'
end

return M

