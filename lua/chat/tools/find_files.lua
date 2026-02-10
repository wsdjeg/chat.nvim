local M = {}

local config = require('chat.config')

---@class ChatToolsFindFilesAction
---@field pattern string

---@param action ChatToolsFindFilesAction
function M.find_files(action)
  if not action.pattern then
    return {
      error = 'failed to find finds, pattern is required.',
    }
  end
  if type(action.pattern) ~= 'string' then
    return {
      error = 'the type of pattern should be string.',
    }
  end

  if not vim.startswith(vim.fn.getcwd(), config.config.allowed_path) then
    return {
      error = 'can not find files in not allowed path.',
    }
  end

  local files = vim.fn.globpath(vim.fn.getcwd(), action.pattern, false, true)

  if #files > 0 then
    return {
      content = string.format(
        'here is founded files: \n\n%s',
        table.concat(files, '\n')
      ),
    }
  else
    return {
      content = 'there is not files based on given pattern.',
    }
  end
end

function M.scheme()
  return {
    type = 'function',
    ['function'] = {
      name = 'find_files',
      description = [[
      user can use @find_files <pattern> to find files in current working directory.
      ]],
      parameters = {
        type = 'object',
        properties = {
          pattern = {
            type = 'string',
            description = 'pattern used to run globpath to find files in current directory.',
          },
        },
        required = { 'pattern' },
      },
    },
  }
end

return M
