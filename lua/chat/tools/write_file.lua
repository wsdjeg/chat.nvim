local M = {}

local config = require('chat.config')
local util = require('chat.util')

---@class ChatToolsWriteFileAction
---@field filepath string
---@field action "create"|"overwrite"|"append"|"insert"|"delete"|"replace"|"remove"
---@field content string?
---@field line_start integer?
---@field line_to integer?

--- Check if path is within allowed paths
---@param filepath string normalized absolute path
---@return boolean
local function is_allowed_path(filepath)
  if type(config.config.allowed_path) == 'table' then
    for _, v in ipairs(config.config.allowed_path) do
      if type(v) == 'string' and #v > 0 then
        if vim.startswith(filepath, vim.fs.normalize(v)) then
          return true
        end
      end
    end
  elseif
    type(config.config.allowed_path) == 'string'
    and #config.config.allowed_path > 0
  then
    if vim.startswith(filepath, vim.fs.normalize(config.config.allowed_path)) then
      return true
    end
  end
  return false
end

--- Check if path is within cwd
---@param filepath string normalized absolute path
---@param cwd string normalized absolute cwd path
---@return boolean
local function is_within_cwd(filepath, cwd)
  if not cwd or cwd == '' then
    return false
  end
  return vim.startswith(filepath, cwd)
end

---@param action ChatToolsWriteFileAction
---@param ctx ChatToolContext
function M.write_file(action, ctx)
  -- Validate filepath
  if not action.filepath or type(action.filepath) ~= 'string' or action.filepath == '' then
    return { error = 'filepath is required and must be a non-empty string.' }
  end

  -- Validate ctx.cwd
  if not ctx.cwd or ctx.cwd == '' then
    return { error = 'No working directory (cwd) specified in context.' }
  end

  local filepath = util.resolve(action.filepath, ctx.cwd)
  if not filepath then
    return { error = 'Failed to resolve filepath.' }
  end

  -- Normalize cwd for comparison
  local cwd = vim.fs.normalize(ctx.cwd)
  -- Ensure cwd ends with separator for proper prefix matching
  if not cwd:match('[/\\]$') then
    cwd = cwd .. '/'
  end

  -- Security check: filepath must be within cwd
  if not is_within_cwd(filepath, cwd) then
    return {
      error = string.format(
        'Security: filepath must be within working directory.\n  filepath: %s\n  cwd: %s',
        filepath,
        cwd
      ),
    }
  end

  -- Security check: filepath must be within allowed_path
  if not is_allowed_path(filepath) then
    return {
      error = string.format(
        'Security: filepath is not in allowed_path.\n  filepath: %s',
        filepath
      ),
    }
  end

  -- Validate action type
  local valid_actions = { 'create', 'overwrite', 'append', 'insert', 'delete', 'replace', 'remove' }
  local action_type = action.action or 'create'
  if not vim.tbl_contains(valid_actions, action_type) then
    return {
      error = string.format(
        'Invalid action "%s". Must be one of: %s',
        action_type,
        table.concat(valid_actions, ', ')
      ),
    }
  end

  -- Handle remove (delete entire file)
  if action_type == 'remove' then
    if vim.fn.filereadable(filepath) == 0 then
      return { error = string.format('File does not exist: %s', filepath) }
    end
    local ok, err = pcall(vim.fn.delete, filepath)
    if not ok then
      return { error = string.format('Failed to delete file: %s', err) }
    end
    return {
      content = string.format('Successfully removed file: %s', filepath),
    }
  end

  -- Check if file exists
  local file_exists = vim.fn.filereadable(filepath) == 1

  if action_type == 'create' and file_exists then
    return { error = string.format('File already exists: %s', filepath) }
  end

  if
    vim.tbl_contains({ 'overwrite', 'append', 'insert', 'delete', 'replace' }, action_type)
    and not file_exists
  then
    return { error = string.format('File does not exist: %s', filepath) }
  end

  -- Get current content if file exists
  local lines = {}
  if file_exists then
    lines = vim.fn.readfile(filepath)
  end

  -- Perform action
  if action_type == 'create' or action_type == 'overwrite' then
    if not action.content then
      return { error = 'content is required for create/overwrite action' }
    end
    local new_lines = vim.split(action.content, '\n', { plain = true })
    vim.fn.writefile(new_lines, filepath, 'p')
    return {
      content = string.format(
        'Successfully %s file: %s\n%d lines written.',
        action_type == 'create' and 'created' or 'overwritten',
        filepath,
        #new_lines
      ),
    }

  elseif action_type == 'append' then
    if not action.content then
      return { error = 'content is required for append action' }
    end
    local append_lines = vim.split(action.content, '\n', { plain = true })
    vim.list_extend(lines, append_lines)
    vim.fn.writefile(lines, filepath, 'p')
    return {
      content = string.format(
        'Successfully appended %d lines to: %s',
        #append_lines,
        filepath
      ),
    }

  elseif action_type == 'insert' then
    if not action.content then
      return { error = 'content is required for insert action' }
    end
    local line_num = action.line_start or 1
    if line_num < 1 or line_num > #lines + 1 then
      return {
        error = string.format(
          'line_start must be between 1 and %d (got %d)',
          #lines + 1,
          line_num
        ),
      }
    end
    local insert_lines = vim.split(action.content, '\n', { plain = true })
    for i, line in ipairs(insert_lines) do
      table.insert(lines, line_num + i - 1, line)
    end
    vim.fn.writefile(lines, filepath, 'p')
    return {
      content = string.format(
        'Successfully inserted %d lines at line %d in: %s',
        #insert_lines,
        line_num,
        filepath
      ),
    }

  elseif action_type == 'delete' then
    if not action.line_start then
      return { error = 'line_start is required for delete action' }
    end
    local start_line = action.line_start
    local end_line = action.line_to or start_line

    if start_line < 1 or end_line > #lines or start_line > end_line then
      return {
        error = string.format(
          'Invalid line range: %d-%d (file has %d lines)',
          start_line,
          end_line,
          #lines
        ),
      }
    end

    local deleted_count = end_line - start_line + 1
    for _ = 1, deleted_count do
      table.remove(lines, start_line)
    end
    vim.fn.writefile(lines, filepath, 'p')
    return {
      content = string.format(
        'Successfully deleted lines %d-%d from: %s',
        start_line,
        end_line,
        filepath
      ),
    }

  elseif action_type == 'replace' then
    if not action.content then
      return { error = 'content is required for replace action' }
    end
    if not action.line_start then
      return { error = 'line_start is required for replace action' }
    end

    local start_line = action.line_start
    local end_line = action.line_to or start_line

    if start_line < 1 or end_line > #lines or start_line > end_line then
      return {
        error = string.format(
          'Invalid line range: %d-%d (file has %d lines)',
          start_line,
          end_line,
          #lines
        ),
      }
    end

    local replace_lines = vim.split(action.content, '\n', { plain = true })
    -- Delete old lines first
    local deleted_count = end_line - start_line + 1
    for _ = 1, deleted_count do
      table.remove(lines, start_line)
    end
    -- Insert new lines
    for i, line in ipairs(replace_lines) do
      table.insert(lines, start_line + i - 1, line)
    end
    vim.fn.writefile(lines, filepath, 'p')
    return {
      content = string.format(
        'Successfully replaced lines %d-%d with %d lines in: %s',
        start_line,
        end_line,
        #replace_lines,
        filepath
      ),
    }
  end

  return { error = 'Unknown action' }
end

function M.scheme()
  return {
    type = 'function',
    ['function'] = {
      name = 'write_file',
      description = [[Write, modify, or delete file content.

SECURITY:
- Filepath must be within working directory (cwd)
- Filepath must be within allowed_path config

ACTIONS:
- create: Create new file (fails if exists)
- overwrite: Overwrite entire file content
- append: Append content to end of file
- insert: Insert content at specific line
- delete: Delete specific line range
- replace: Replace specific line range with new content
- remove: Delete entire file

EXAMPLES:
- @write_file filepath="./src/main.lua" action="create" content="print('hello')"
- @write_file filepath="./src/main.lua" action="overwrite" content="new content"
- @write_file filepath="./src/main.lua" action="append" content="\n-- added"
- @write_file filepath="./src/main.lua" action="insert" line_start=5 content="-- comment"
- @write_file filepath="./src/main.lua" action="delete" line_start=5 line_to=10
- @write_file filepath="./src/main.lua" action="replace" line_start=5 line_to=10 content="new lines"
- @write_file filepath="./src/main.lua" action="remove"

NOTES:
- Line numbers are 1-indexed (first line is line 1)
- Requires allowed_path in chat.nvim config
- For insert: line_start can be #lines+1 to append at end
- The 'p' flag is used to automatically create parent directories if they don't exist
      ]],
      parameters = {
        type = 'object',
        properties = {
          filepath = {
            type = 'string',
            description = 'File path (relative to cwd or absolute)',
          },
          action = {
            type = 'string',
            enum = { 'create', 'overwrite', 'append', 'insert', 'delete', 'replace', 'remove' },
            description = 'Action to perform (default: create)',
          },
          content = {
            type = 'string',
            description = 'Content to write (required for create/overwrite/append/insert/replace)',
          },
          line_start = {
            type = 'integer',
            description = 'Starting line number, 1-indexed (for insert/delete/replace)',
            minimum = 1,
          },
          line_to = {
            type = 'integer',
            description = 'Ending line number, 1-indexed (for delete/replace)',
            minimum = 1,
          },
        },
        required = { 'filepath' },
      },
    },
  }
end

function M.info(action, ctx)
  local ok, args = pcall(vim.json.decode, action)
  if ok then
    local filepath = util.resolve(args.filepath, ctx.cwd) or args.filepath
    local action_type = args.action or 'create'
    local info = string.format('write_file %s [%s]', filepath, action_type)

    if args.line_start then
      info = info .. string.format(' lines %d', args.line_start)
      if args.line_to then
        info = info .. string.format('-%d', args.line_to)
      end
    end

    return info
  end
  return 'write_file'
end

return M

