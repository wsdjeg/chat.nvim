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

---@class ChatToolsGitResetAction
---@field mode? string Reset mode: "soft", "mixed", "hard" (default: "hard")
---@field commit? string Commit hash, tag, or reference (default: "HEAD")
---@field path? string Specific file path or directory to reset

---@param action ChatToolsGitResetAction
---@param ctx ChatToolContext
function M.git_reset(action, ctx)
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
      error = 'Cannot run git_reset in non-allowed path.',
    }
  end

  if not is_git_available() then
    return {
      error = 'git is not installed or not in PATH.',
    }
  end

  local cmd = { 'git', '-C', ctx.cwd, 'reset' }
  local mode = action.mode or 'hard'

  if mode == 'soft' then
    table.insert(cmd, '--soft')
  elseif mode == 'mixed' then
    table.insert(cmd, '--mixed')
  elseif mode == 'hard' then
    table.insert(cmd, '--hard')
  else
    return {
      error = 'Invalid mode: ' .. mode .. ' (must be soft, mixed, or hard)',
    }
  end

  local commit = action.commit or 'HEAD'
  table.insert(cmd, commit)

  if action.path then
    table.insert(cmd, '--')
    table.insert(cmd, action.path)
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
          error = string.format('Git reset cancelled (signal: %d)', signal),
          jobid = id,
        })
        return
      end

      local output = table.concat(stdout, '\n')
      local error_output = table.concat(stderr, '\n')

      if code == 0 then
        local summary = 'Git reset successful.\n\n'
        summary = summary .. 'Command: ' .. table.concat(cmd, ' ') .. '\n\n'

        if #output > 0 and output ~= '\n' then
          summary = summary .. output
        else
          summary = summary .. 'Reset completed in ' .. mode .. ' mode.'
        end

        ctx.callback({
          content = summary,
          jobid = id,
        })
      else
        ctx.callback({
          error = string.format(
            'Failed to run git reset (exit %d):\n%s\n%s',
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
      name = 'git_reset',
      description = [[
Reset current HEAD to the specified state.

This tool executes git reset to undo changes in the working directory.

USAGE:
- @git_reset commit="abc123" mode="soft"  # Reset to commit, keep all changes staged
- @git_reset mode="mixed"                 # Reset HEAD to HEAD, unstage changes (default)
- @git_reset mode="hard"                  # Discard all changes in working directory
- @git_reset path="./src/main.lua"        # Reset specific file to HEAD

MODES:
- soft: Moves HEAD only, keeps changes staged
- mixed: Moves HEAD, unstages changes (default)
- hard: Moves HEAD, discards all changes (use with caution!)

EXAMPLES:
- @git_reset mode="soft" commit="HEAD~1"  # Undo last commit, keep changes staged
- @git_reset mode="hard" commit="abc123"  # Reset to specific commit, discard changes
- @git_reset path="README.md"             # Unstage changes to README.md
- @git_reset mode="hard"                  # Discard all local changes

WARNING:
- Use --hard with caution as it permanently discards changes!
- Consider stashing changes first if you might need them later.
      ]],
      parameters = {
        type = 'object',
        properties = {
          mode = {
            type = 'string',
            description = 'Reset mode: soft, mixed, or hard (default: hard)',
            enum = { 'soft', 'mixed', 'hard' },
          },
          commit = {
            type = 'string',
            description = 'Commit hash, tag, or reference (default: HEAD)',
          },
          path = {
            type = 'string',
            description = 'Specific file path or directory to reset',
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
    local parts = { 'git_reset' }
    if args.mode then
      table.insert(parts, string.format('mode="%s"', args.mode))
    end
    if args.commit then
      table.insert(parts, string.format('commit="%s"', args.commit))
    end
    if args.path then
      table.insert(parts, string.format('path="%s"', args.path))
    end
    return table.concat(parts, ' ')
  end
  return 'git_reset'
end

return M

