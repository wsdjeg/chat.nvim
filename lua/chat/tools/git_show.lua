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

---@class ChatToolsGitShowAction
---@field commit string  -- commit hash or tag
---@field stat? boolean  -- show stat only
---@field path? string   -- specific file path

---@param action ChatToolsGitShowAction
---@param ctx ChatToolContext
function M.git_show(action, ctx)
  -- Security check for ctx.cwd
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

  if not is_allowed_path then
    return {
      error = 'Cannot run git show in non-allowed path.',
    }
  end

  if not is_git_available() then
    return {
      error = 'git is not installed or not in PATH.',
    }
  end

  -- commit is required
  if
    not action.commit
    or type(action.commit) ~= 'string'
    or action.commit == ''
  then
    return {
      error = 'commit parameter is required.',
    }
  end

  -- Validate commit doesn't contain dangerous characters
  local commit = action.commit
  if commit:match('[;|&`$%(%)%[%]{}]') then
    return {
      error = 'Invalid commit format.',
    }
  end

  -- Build git command
  local cmd = { 'git', '-C', ctx.cwd, 'show', commit }

  if action.stat then
    table.insert(cmd, '--stat')
  end

  local resolved_path = nil
  if action.path and type(action.path) == 'string' and action.path ~= '' then
    resolved_path = util.resolve(action.path, ctx.cwd)

    -- Security: ensure resolved_path is within ctx.cwd
    if
      not vim.startswith(
        vim.fs.normalize(resolved_path),
        vim.fs.normalize(ctx.cwd)
      )
    then
      return {
        error = 'Cannot access path outside working directory.',
      }
    end

    table.insert(cmd, '--')
    table.insert(cmd, resolved_path)
  end

  local stdout = {}
  local stderr = {}

  local jobid = job.start(cmd, {
    cwd = ctx.cwd,
    on_stdout = function(_, data)
      vim.list_extend(stdout, data)
    end,
    on_stderr = function(_, data)
      vim.list_extend(stderr, data)
    end,
    on_exit = function(id, code, signal)
      if signal ~= 0 then
        ctx.callback({
          error = string.format('Git show cancelled (signal: %d)', signal),
          jobid = id,
        })
        return
      end

      local output = table.concat(stdout, '\n')
      if #stderr > 0 then
        output = output .. '\n' .. table.concat(stderr, '\n')
      end

      if code == 0 then
        if output == '' then
          output = 'No output.'
        end

        local summary = string.format('Git show: %s\n\n', commit)
        if action.stat then
          summary = summary .. '(showing stat only)\n\n'
        end
        if resolved_path then
          summary = summary .. string.format('Path: %s\n\n', resolved_path)
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
      name = 'git_show',
      description = [[
Show detailed changes of a specific commit.

USAGE:
- @git_show commit="abc123"           # Show commit details
- @git_show commit="v1.0.0"           # Show tag commit
- @git_show commit="abc123" stat=true # Show stat only (file list)
- @git_show commit="abc123" path="./src/main.lua"  # Show changes for specific file

EXAMPLES:
- @git_show commit="a1b2c3d"
- @git_show commit="HEAD~1"
- @git_show commit="v1.0.0" stat=true
- @git_show commit="abc123" path="src/main.lua"

NOTES:
- Requires git to be installed and in PATH.
- commit can be a commit hash, tag, or relative ref (HEAD~1, HEAD^, etc.).
- Use stat=true to see only the file list with change counts.
- Use path to filter changes to a specific file.
      ]],
      parameters = {
        type = 'object',
        properties = {
          commit = {
            type = 'string',
            description = 'Commit hash, tag, or reference (e.g., "abc123", "v1.0.0", "HEAD~1")',
          },
          stat = {
            type = 'boolean',
            description = 'Show stat only (file list with change counts)',
          },
          path = {
            type = 'string',
            description = 'Filter to specific file path (optional)',
          },
        },
        required = { 'commit' },
      },
    },
  }
end

function M.info(action, ctx)
  local ok, args = pcall(vim.json.decode, action)
  if ok then
    local parts = { 'git_show', args.commit or '' }
    if args.stat then
      table.insert(parts, 'stat=true')
    end
    if args.path then
      table.insert(parts, string.format('path="%s"', args.path))
    end
    return table.concat(parts, ' ')
  end
  return 'git_show'
end

return M
