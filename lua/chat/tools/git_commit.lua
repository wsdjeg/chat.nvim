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

---@class ChatToolsGitCommitAction
---@field message string Commit message
---@field allow_empty? boolean Allow empty commit
---@field amend? boolean Amend previous commit

---@param action ChatToolsGitCommitAction
---@param ctx ChatToolContext
function M.git_commit(action, ctx)
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
      error = 'Cannot run git_commit in non-allowed path.',
    }
  end

  if not is_git_available() then
    return {
      error = 'git is not installed or not in PATH.',
    }
  end

  -- Validate commit message
  if
    not action.message
    or type(action.message) ~= 'string'
    or #action.message == 0
  then
    return {
      error = 'Commit message is required.',
    }
  end

  -- Build git command
  -- Build git command
  local cmd = { 'git', '-C', ctx.cwd, 'commit', '-m', action.message }

  -- Add optional flags
  if action.allow_empty then
    table.insert(cmd, '--allow-empty')
  end

  if action.amend then
    table.insert(cmd, '--amend')
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
          error = string.format('Git commit cancelled (signal: %d)', signal),
          jobid = id,
        })
        return
      end

      local output = table.concat(stdout, '\n')
      if #stderr > 0 then
        output = output .. '\n' .. table.concat(stderr, '\n')
      end

      if code == 0 then
        local summary = 'Git commit successful.\n\n'
        summary = summary .. 'Commit message: ' .. action.message .. '\n\n'

        -- Try to extract commit hash from output
        local commit_hash = output:match('%[([a-f0-9]+)%]')
        if commit_hash then
          summary = summary .. 'Commit hash: ' .. commit_hash .. '\n'
        end

        -- Extract branch info
        local branch = output:match('branch%s+([%w%-_/]+)')
        if branch then
          summary = summary .. 'Branch: ' .. branch .. '\n'
        end

        -- Extract file changes
        local files_changed = output:match('(%d+%s+file[s]?)%s+changed')
        if files_changed then
          summary = summary .. 'Files: ' .. files_changed .. '\n'
        end

        ctx.callback({
          content = summary .. '\n' .. output,
          jobid = id,
        })
      else
        -- Try to provide helpful error messages
        local error_msg = output:lower()

        if error_msg:match('nothing to commit') then
          ctx.callback({
            error = 'Nothing to commit. Use git_add first to stage changes, or use allow_empty=true.',
            jobid = id,
          })
        elseif error_msg:match('please tell me who you are') then
          ctx.callback({
            error = 'Git user name and email not configured. Please run:\n  git config --global user.name "Your Name"\n  git config --global user.email "your@email.com"',
            jobid = id,
          })
        else
          ctx.callback({
            error = string.format(
              'Failed to run git commit (exit %d):\n%s',
              code,
              output
            ),
            jobid = id,
          })
        end
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
      name = 'git_commit',
      description = [[
Create a git commit with the specified message.

This tool executes git commit to create a new commit with staged changes.

USAGE:
- @git_commit message="Your commit message"          # Create commit
- @git_commit message="fix: bug" allow_empty=true    # Allow empty commit
- @git_commit message="update" amend=true             # Amend previous commit

EXAMPLES:
- @git_commit message="feat: add user authentication"
- @git_commit message="fix: resolve login issue"
- @git_commit message="docs: update README" allow_empty=true
- @git_commit message="WIP" amend=true

NOTES:
- Requires git to be installed and in PATH.
- Requires changes to be staged first (use git_add).
- Commit message is required.
- Use allow_empty=true for commits without changes.
- Use amend=true to modify the previous commit.

RECOMMENDED COMMIT MESSAGE FORMAT:
- feat: new feature
- fix: bug fix
- docs: documentation changes
- refactor: code refactoring
- test: adding tests
- chore: maintenance tasks
      ]],
      parameters = {
        type = 'object',
        properties = {
          message = {
            type = 'string',
            description = 'Commit message (required)',
          },
          allow_empty = {
            type = 'boolean',
            description = 'Allow empty commit (optional)',
          },
          amend = {
            type = 'boolean',
            description = 'Amend previous commit (optional)',
          },
        },
        required = { 'message' },
      },
    },
  }
end

function M.info(action, ctx)
  local ok, args = pcall(vim.json.decode, action)
  if ok then
    local parts = { 'git_commit' }
    if args.message then
      table.insert(parts, string.format('message="%s"', args.message))
    end
    if args.allow_empty then
      table.insert(parts, 'allow_empty=true')
    end
    if args.amend then
      table.insert(parts, 'amend=true')
    end
    return table.concat(parts, ' ')
  end
  return 'git_commit'
end

return M
