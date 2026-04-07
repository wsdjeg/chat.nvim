local M = {}

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

  -- Validate line_start parameter
  if action.line_start ~= nil then
    if type(action.line_start) ~= 'number' then
      return {
        error = 'line_start must be a number',
      }
    end
    if action.line_start < 1 then
      return {
        error = 'line_start must be at least 1',
      }
    end
  end

  -- Validate line_to parameter
  if action.line_to ~= nil then
    if type(action.line_to) ~= 'number' then
      return {
        error = 'line_to must be a number',
      }
    end
    if action.line_to < 1 then
      return {
        error = 'line_to must be at least 1',
      }
    end
  end

  -- Validate line_start <= line_to if both are provided
  if
    action.line_start ~= nil
    and action.line_to ~= nil
    and action.line_start > action.line_to
  then
    return {
      error = string.format(
        'line_start (%d) cannot be greater than line_to (%d)',
        action.line_start,
        action.line_to
      ),
    }
  end

  if util.is_allowed_path(filepath) then
    local ok, content = pcall(vim.fn.readfile, filepath)
    if ok then
      -- Handle line range if specified
      local start_line = action.line_start or 1
      local end_line = action.line_to or #content

      -- Extract the range
      local range_content = {}
      for i = start_line, end_line do
        table.insert(range_content, content[i])
      end

      -- Format output message
      local message
      if action.line_start ~= nil or action.line_to ~= nil then
        message = string.format(
          'the file content is (lines %d-%d): \n\n%s',
          start_line,
          end_line,
          table.concat(range_content, '\n')
        )
      else
        message = string.format(
          'the file content is: \n\n%s',
          table.concat(content, '\n')
        )
      end

      return {
        content = message,
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
      description = [[Reads the content of a file or specific line range.
      
      Examples:
      - @read_file ./src/main.lua                         - Read entire file
      - @read_file ./src/main.lua line_start=10 line_to=20 - Read lines 10-20
      - @read_file ./src/main.lua line_start=50           - Read from line 50 to end
      - @read_file ./src/main.lua line_to=10              - Read first 10 lines
      Notes:
      - Line numbers are 1-indexed (first line is line 1)
      - line_start and line_to are both inclusive (e.g., line_start=10 line_to=20 reads lines 10-20, including both)
      - If line_start is not specified, defaults to line 1
      - If line_to is not specified, defaults to last line
      - If both line_start and line_to are specified, line_start must be <= line_to
      - If both line_start and line_to are specified, line_start must be <= line_to
      
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
          line_start = {
            type = 'integer',
            description = 'Starting line number (1-indexed, inclusive)',
            minimum = 1,
          },
          line_to = {
            type = 'integer',
            description = 'Ending line number (1-indexed, inclusive)',
            minimum = 1,
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
    local info =
      string.format('read_file %s', util.resolve(arguments.filepath, ctx.cwd))
    if arguments.line_start or arguments.line_to then
      local start_line = arguments.line_start or 1
      local end_line = arguments.line_to or 'end'
      info = info
        .. string.format(
          ' (lines %s-%s)',
          tostring(start_line),
          tostring(end_line)
        )
    end
    return info
  else
    return 'read_file'
  end
end

return M
