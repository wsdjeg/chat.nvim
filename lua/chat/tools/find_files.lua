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
  local is_allowed_path = false

  if type(config.config.allowed_path) == 'table' then
    for _, v in ipairs(config.config.allowed_path) do
      if type(v) == 'string' and #v > 0 then
        if vim.startswith(vim.fn.getcwd(), v) then
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
      vim.startswith(vim.fn.getcwd(), config.config.allowed_path)
  end

  if not is_allowed_path then
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
