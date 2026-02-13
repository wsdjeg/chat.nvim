local M = {}

local config = require('chat.config')

local util = require('chat.util')

---@class ChatToolsReadfileAction
---@field filepath string
---@field line_start integer
---@field line_to integer

---@param action ChatToolsReadfileAction
---@param ctx ChatToolContext
function M.read_file(action, ctx)
  
  local filepath = util.resolve(action.filepath, ctx.cwd)

  if not filepath then
    return {
      error = 'failed to read file, filepath is required.',
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

  local is_allowed_path = false

  if type(config.config.allowed_path) == 'table' then
    for _, v in ipairs(config.config.allowed_path) do
      if type(v) == 'string' and #v > 0 then
        if vim.startswith(filepath, v) then
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
      vim.startswith(filepath, config.config.allowed_path)
  end

  if is_allowed_path then
    local ok, content = pcall(vim.fn.readfile, filepath)
    if ok then
      return {
        content = string.format(
          'the file content is: \n\n%s',
          table.concat(content, '\n')
        ),
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
      description = [[must contains @read_file filepath, use @read_file ./directory/filename to read the content of the file.
      before using this function, you need to setup allowed_path in chat.nvim config. for example:
      ```lua
      require('chat').setup({
        allowed_path = 'path/to/your_project'
      })
      ```
      ]],
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

function M.info(action, ctx)
  local ok, arguments = pcall(vim.json.decode, action)
  if ok then
    return string.format('read_file %s', util.resolve(arguments.filepath, ctx.cwd))
  else
    return 'read_file'
  end
end

return M
