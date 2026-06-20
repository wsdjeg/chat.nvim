local M = {}

local config = require('chat.config')
local util = require('chat.util')
local job = require('job')
local storage = require('chat.sessions.storage')

-- Cache make availability check
local make_available = nil
local function is_make_available()
  if make_available == nil then
    make_available = vim.fn.executable('make') == 1
  end
  return make_available
end

-- Detect Windows for encoding conversion
-- Windows cmd.exe uses GBK (CP936) by default, not UTF-8
local is_windows = vim.fn.has('win32') == 1

---@class ChatToolsMakeAction
---@field target? string Make target to run (e.g., "test", "build")
---@field args? string[] Additional arguments for make
---@field directory? string Directory to run make in (default: ctx.cwd)

--- Check if Makefile was modified after user's last message
--- Returns nil if safe to run, or an error string if blocked
--- @param work_dir string The working directory to check
--- @param session_id string|nil The session ID
--- @return string|nil error message if blocked, nil if safe
local function check_makefile_mtime(work_dir, session_id)
  if not session_id then
    return nil -- No session context, allow execution
  end

  local session = storage.sessions[session_id]
  if not session then
    return nil
  end

  local last_user_time = session.last_user_message_time
  if not last_user_time then
    return nil -- No user message recorded yet, allow execution
  end

  -- Check Makefile in the working directory
  local makefile_path = vim.fs.normalize(work_dir .. '/Makefile')
  local makefile_stat = vim.uv.fs_stat(makefile_path)
  if not makefile_stat then
    return nil -- No Makefile exists, allow execution
  end

  local makefile_mtime = makefile_stat.mtime.sec
  if makefile_mtime > last_user_time then
    return string.format(
      'Security: Makefile was modified after your last message.\n'
      .. 'Makefile mtime: %s\n'
      .. 'Last user message: %s\n'
      .. 'Please review the Makefile changes before running make.',
      os.date('%Y-%m-%d %H:%M:%S', makefile_mtime),
      os.date('%Y-%m-%d %H:%M:%S', last_user_time)
    )
  end

  return nil
end

---@param action ChatToolsMakeAction
---@param ctx ChatToolContext
function M.make(action, ctx)
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
      error = 'Cannot run make in non-allowed path.',
    }
  end

  if not is_make_available() then
    return {
      error = 'make is not installed or not in PATH.',
    }
  end

  -- Build make command
  local cmd = { 'make' }

  -- Add target if specified
  if action.target and type(action.target) == 'string' and #action.target > 0 then
    table.insert(cmd, action.target)
  end

  -- Add additional arguments
  if action.args and type(action.args) == 'table' then
    for _, arg in ipairs(action.args) do
      if type(arg) == 'string' and #arg > 0 then
        table.insert(cmd, arg)
      end
    end
  end

  -- Resolve working directory
  local work_dir = ctx.cwd
  if action.directory and type(action.directory) == 'string' then
    work_dir = util.resolve(action.directory, ctx.cwd)

    -- Security: ensure work_dir is within ctx.cwd
    if not vim.startswith(vim.fs.normalize(work_dir), vim.fs.normalize(ctx.cwd)) then
      return {
        error = 'Cannot access directory outside working directory.',
      }
    end
  end

  -- Check Makefile modification time vs user message time
  local mtime_error = check_makefile_mtime(work_dir, ctx.session)
  if mtime_error then
    return {
      error = mtime_error,
    }
  end

  local stdout = {}
  local stderr = {}

  -- Build job options
  -- On Windows, use encoding='gbk' to convert cmd.exe output to UTF-8
  -- job.nvim uses vim.fn.iconv() internally for this conversion
  local job_opts = {
    cwd = work_dir,
    on_stdout = function(_, data)
      vim.list_extend(stdout, data)
    end,
    on_stderr = function(_, data)
      vim.list_extend(stderr, data)
    end,
    on_exit = function(id, code, signal)
      if signal ~= 0 then
        ctx.callback({
          error = string.format('Make cancelled (signal: %d)', signal),
          jobid = id,
        })
        return
      end

      local output = table.concat(stdout, '\n')
      local error_output = table.concat(stderr, '\n')

      -- Combine output
      local full_output = output
      if #error_output > 0 then
        full_output = full_output .. '\n' .. error_output
      end

      local target_desc = action.target or 'default target'
      local summary = string.format(
        'Make %s: %s (exit code: %d)\n\n',
        target_desc,
        code == 0 and '✓ Success' or '✗ Failed',
        code
      )

      ctx.callback({
        content = summary .. (full_output ~= '' and full_output or 'No output.'),
        exit_code = code,
        jobid = id,
      })
    end,
  }

  -- On Windows, convert GBK output to UTF-8 to prevent NonUTF8Body API errors
  if is_windows then
    job_opts.encoding = 'gbk'
  end

  local jobid = job.start(cmd, job_opts)

  if jobid > 0 then
    return { jobid = jobid }
  end
end

function M.scheme()
  return {
    type = 'function',
    ['function'] = {
      name = 'make',
      description = [[
Run make targets and return results.

USAGE:
- @make                           # Run default target
- @make target="test"             # Run make test
- @make target="build"            # Run make build
- @make target="test" args=["-j4"]  # Run with options
- @make directory="./subproject"  # Run in subdirectory

EXAMPLES:
- Run tests: @make target="test"
- Build with 4 jobs: @make target="build" args=["-j4"]
- Clean and rebuild: @make target="clean" args=["all"]

OUTPUT:
Returns make command output with exit code and status.
      ]],
      parameters = {
        type = 'object',
        properties = {
          target = {
            type = 'string',
            description = 'Make target to run (e.g., "test", "build", "clean")',
          },
          args = {
            type = 'array',
            items = { type = 'string' },
            description = 'Additional arguments for make (e.g., ["-j4", "VERBOSE=1"])',
          },
          directory = {
            type = 'string',
            description = 'Directory to run make in (default: current working directory)',
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
    local parts = { 'make' }
    if args.target then
      table.insert(parts, string.format('target="%s"', args.target))
    end
    if args.args and #args.args > 0 then
      table.insert(parts, string.format('args=%s', vim.json.encode(args.args)))
    end
    if args.directory then
      table.insert(parts, string.format('directory="%s"', args.directory))
    end
    return table.concat(parts, ' ')
  end
  return 'make'
end

return M

