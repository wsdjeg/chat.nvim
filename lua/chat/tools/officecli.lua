local M = {}

local util = require('chat.util')
local job = require('job')

-- Cache make availability check
local officecli_available = nil
local function is_officecli_available()
  if officecli_available == nil then
    -- Install officecli on windows
    -- scoop install https://raw.githubusercontent.com/wsdjeg/Main-Plus/refs/heads/main/bucket/officecli.json
    officecli_available = vim.fn.executable('officecli') == 1
  end
  return officecli_available
end

---@class ChatToolsOfficeCliAction
---@field command? string officecli command (e.g., "view", "create")
---@field filepath? string[] Additional arguments for make
---@field directory? string Directory to run make in (default: ctx.cwd)

---@param action ChatToolsOfficeCliAction
---@param ctx ChatToolContext
function M.officecli(action, ctx)
  local filepath = util.resolve(action.filepath, ctx.cwd)

  if not filepath then
    return {
      error = 'failed to run officecli, filepath is required.',
    }
  elseif type(filepath) ~= 'string' then
    return {
      error = 'the type of filepath is not string.',
    }
  elseif vim.fn.filereadable(filepath) == 0 then
    return {
      error = string.format('filepath(%s) is not readable.', filepath),
    }
  end

  if not is_officecli_available() then
    return {
      error = 'officecli is not installed or not in PATH.',
    }
  end

  if util.is_allowed_path(filepath) then

  -- Build officecli command
  local cmd = { 'officecli' }

  if action.command and type(action.command) == 'string' and #action.command > 0 then
    table.insert(cmd, action.command)
  end

  table.insert(cmd, filepath)

  table.insert(cmd, 'text')

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
          error = string.format('officecli cancelled (signal: %d)', signal),
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

      local summary = string.format(
        'officecli %s %s (exit code: %d)\n\n',
        action.command,
        code == 0 and '✓ Success' or '✗ Failed',
        code
      )

      ctx.callback({
        content = summary .. (full_output ~= '' and full_output or 'No output.'),
        exit_code = code,
        jobid = id,
      })
    end,
  })

  if jobid > 0 then
    return { jobid = jobid }
  end
  else
    return {
      error = 'not allowed path',
    }
  end
end

function M.scheme()
  return {
    type = 'function',
    ['function'] = {
      name = 'officecli',
      description = [[
Run officecli and return results.

USAGE:
- @officecli command="view" filepath="users.xlsx"             # view excel file
]],
      parameters = {
        type = 'object',
        properties = {
          command = {
            type = 'string',
            description = 'officecli command to run (e.g., "view")',
          },
          filepath = {
            type = 'string',
            description = 'file path to run with officecli',
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
    local parts = { 'officecli' }
    if args.command then
      table.insert(parts, string.format('command="%s"', args.command))
    end
    local filepath = util.resolve(action.filepath, ctx.cwd)
    if filepath then
      table.insert(parts, string.format('filepath=%s', filepath))
    end
    return table.concat(parts, ' ')
  end
  return 'officecli'
end

return M
