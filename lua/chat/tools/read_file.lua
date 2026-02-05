local M = {}

local config = require('chat.config')

---@class ChatToolsReadfileAction
---@field filepath string
---@field line_start integer
---@field line_to integer

---@param action ChatToolsReadfileAction
function M.read_file(action)
  if not action.filepath then
    return {
      error = 'failed to read file, filepath is required.',
    }
  elseif type(action.filepath) ~= 'string' then
    return {
      error = 'the type of filepath is not string.',
    }
  elseif vim.fn.filereadable(action.filepath) == 0 then
    return {
      error = string.format('filepath(%s) is not readable.', action.filepath),
    }
  end

  if vim.startswith(action.filepath, config.allowed_path) then
    local ok, content = pcall(vim.fn.readfile, action.filepath)
    if ok then
      return {
        content = content,
      }
    else
      return {
        error = content,
      }
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
      name = 'read_file',
      description = 'read file',
      parameters = {
        type = 'object',
        properties = {
          filepath = {
            type = 'string',
            description = 'file path',
          },
        },
      required = { 'filepath' },
      },
    },
  }
end

return M
