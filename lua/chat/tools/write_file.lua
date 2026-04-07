local M = {}

local config = require('chat.config')
local util = require('chat.util')

---@class ChatToolsWriteFileAction
---@field filepath string
---@field action "create"|"overwrite"|"append"|"insert"|"delete"|"replace"|"remove"
---@field content string?
---@field line_start integer?
---@field line_to integer?
---@field backup boolean? -- Create backup before modifying
---@field validate boolean? -- Validate syntax after modification (for code files)



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

--- Get file extension
---@param filepath string
---@return string?
local function get_file_extension(filepath)
  return filepath:match('%.([^.]+)$')
end

--- Validate Lua syntax
---@param content string
---@return boolean, string? error_message
local function validate_lua_syntax(content)
  local fn, err = loadstring(content)
  if not fn then
    return false, err
  end
  return true, nil
end

--- Validate Python syntax (requires python in PATH)
---@param content string
---@return boolean, string? error_message
local function validate_python_syntax(content)
  local temp_file = vim.fn.tempname() .. '.py'
  vim.fn.writefile(vim.split(content, '\n'), temp_file)

  local result =
    vim.fn.system(string.format('python -m py_compile %s 2>&1', temp_file))
  vim.fn.delete(temp_file)

  if vim.v.shell_error ~= 0 then
    return false, result
  end
  return true, nil
end

--- Validate file syntax based on extension
---@param filepath string
---@param content string
---@return boolean, string? error_message
local function validate_syntax(filepath, content)
  local ext = get_file_extension(filepath)

  if ext == 'lua' then
    return validate_lua_syntax(content)
  elseif ext == 'py' then
    return validate_python_syntax(content)
  end

  -- Unknown file type, skip validation
  return true, nil
end

--- Create backup of file
---@param filepath string
---@return string? backup_path
local function create_backup(filepath)
  local backup_path = filepath .. '.backup.' .. os.time()
  if vim.fn.copy(filepath, backup_path) == 0 then
    return backup_path
  end
  return nil
end

--- Get context around a line range for error messages
---@param lines string[]
---@param start_line integer
---@param end_line integer
---@param context_lines integer
---@return string
local function get_line_context(lines, start_line, end_line, context_lines)
  local result = {}
  local context_start = math.max(1, start_line - context_lines)
  local context_end = math.min(#lines, end_line + context_lines)

  for i = context_start, context_end do
    local marker = (i >= start_line and i <= end_line) and '>' or ' '
    table.insert(result, string.format('%s%4d: %s', marker, i, lines[i]))
  end

  return table.concat(result, '\n')
end

---@param action ChatToolsWriteFileAction
---@param ctx ChatToolContext
function M.write_file(action, ctx)
  -- Validate filepath
  if
    not action.filepath
    or type(action.filepath) ~= 'string'
    or action.filepath == ''
  then
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
  if not util.is_allowed_path(filepath) then
    return {
      error = string.format(
        'Security: filepath is not in allowed_path.\n  filepath: %s',
        filepath
      ),
    }
  end

  -- Validate action type
  local valid_actions = {
    'create',
    'overwrite',
    'append',
    'insert',
    'delete',
    'replace',
    'remove',
  }
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
    vim.tbl_contains(
      { 'overwrite', 'append', 'insert', 'delete', 'replace' },
      action_type
    ) and not file_exists
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

    -- Validate syntax if requested
    if action.validate then
      local ok, err = validate_syntax(filepath, action.content)
      if not ok then
        return {
          error = string.format('Syntax validation failed:\n%s', err),
        }
      end
    end

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

    -- Validate syntax if requested
    if action.validate then
      local ok, err = validate_syntax(filepath, table.concat(lines, '\n'))
      if not ok then
        return {
          error = string.format('Syntax validation failed:\n%s', err),
        }
      end
    end

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

    -- Validate syntax if requested
    if action.validate then
      local ok, err = validate_syntax(filepath, table.concat(lines, '\n'))
      if not ok then
        return {
          error = string.format('Syntax validation failed:\n%s', err),
        }
      end
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

    -- Create backup if requested
    local backup_path = nil
    if action.backup then
      backup_path = create_backup(filepath)
    end

    -- Store deleted content for context
    local deleted_lines = {}
    for i = start_line, end_line do
      table.insert(deleted_lines, lines[i])
    end

    -- Delete lines
    local deleted_count = end_line - start_line + 1
    for _ = 1, deleted_count do
      table.remove(lines, start_line)
    end

    -- Validate syntax if requested
    if action.validate then
      local ok, err = validate_syntax(filepath, table.concat(lines, '\n'))
      if not ok then
        -- Restore from backup if available
        if backup_path and vim.fn.filereadable(backup_path) == 1 then
          vim.fn.rename(backup_path, filepath)
          lines = vim.fn.readfile(filepath)
        end
        return {
          error = string.format(
            'Syntax validation failed after deletion. Changes reverted.\n%s',
            err
          ),
        }
      end
    end

    vim.fn.writefile(lines, filepath, 'p')

    -- Clean up backup on success
    if backup_path and vim.fn.filereadable(backup_path) == 1 then
      vim.fn.delete(backup_path)
    end

    local result = string.format(
      'Successfully deleted lines %d-%d from: %s',
      start_line,
      end_line,
      filepath
    )

    -- Show context if deleted content might be important
    if deleted_count <= 10 then
      result = result
        .. string.format(
          '\n\nDeleted content:\n%s',
          table.concat(deleted_lines, '\n')
        )
    end

    return { content = result }
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

    -- Create backup if requested
    local backup_path = nil
    if action.backup then
      backup_path = create_backup(filepath)
    end

    -- Store original content for context
    local original_lines = {}
    for i = start_line, end_line do
      table.insert(original_lines, lines[i])
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

    -- Validate syntax if requested
    if action.validate then
      local ok, err = validate_syntax(filepath, table.concat(lines, '\n'))
      if not ok then
        -- Restore from backup if available
        if backup_path and vim.fn.filereadable(backup_path) == 1 then
          vim.fn.rename(backup_path, filepath)
          lines = vim.fn.readfile(filepath)
        end

        -- Build detailed error message with context
        local context_before = get_line_context(
          lines,
          math.max(1, start_line - 3),
          math.min(#lines, start_line + #replace_lines + 2),
          2
        )

        return {
          error = string.format(
            'Syntax validation failed after replacement. Changes reverted.\n\nOriginal lines (%d-%d):\n%s\n\nNew content:\n%s\n\nValidation error:\n%s',
            start_line,
            end_line,
            table.concat(original_lines, '\n'),
            table.concat(replace_lines, '\n'),
            err
          ),
        }
      end
    end

    vim.fn.writefile(lines, filepath, 'p')

    -- Clean up backup on success
    if backup_path and vim.fn.filereadable(backup_path) == 1 then
      vim.fn.delete(backup_path)
    end

    local result = string.format(
      'Successfully replaced lines %d-%d with %d lines in: %s',
      start_line,
      end_line,
      #replace_lines,
      filepath
    )

    -- Show context for small replacements
    if deleted_count <= 5 and #replace_lines <= 5 then
      result = result
        .. string.format(
          '\n\nOriginal (%d lines):\n%s\n\nNew (%d lines):\n%s',
          deleted_count,
          table.concat(original_lines, '\n'),
          #replace_lines,
          table.concat(replace_lines, '\n')
        )
    end

    return { content = result }
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

VALIDATION:
- Use validate=true to check syntax after modification
- Supported languages: Lua, Python
- Automatically reverts changes if validation fails

BACKUP:
- Use backup=true to create backup before modification
- Backup is automatically cleaned up on success
- Backup format: <filepath>.backup.<timestamp>

EXAMPLES:
- @write_file filepath="./src/main.lua" action="create" content="print('hello')"
- @write_file filepath="./src/main.lua" action="overwrite" content="new content"
- @write_file filepath="./src/main.lua" action="append" content="\n-- added"
- @write_file filepath="./src/main.lua" action="insert" line_start=5 content="-- comment"
- @write_file filepath="./src/main.lua" action="delete" line_start=5 line_to=10
- @write_file filepath="./src/main.lua" action="replace" line_start=5 line_to=10 content="new lines"
- @write_file filepath="./src/main.lua" action="replace" line_start=5 line_to=10 content="new lines" validate=true
- @write_file filepath="./src/main.lua" action="remove"
NOTES:
- Line numbers are 1-indexed (first line is line 1)
- line_start and line_to are both inclusive (e.g., line_start=5 line_to=10 deletes lines 5-10, including both)
- Requires allowed_path in chat.nvim config
- For insert: line_start can be #lines+1 to append at end
- The 'p' flag is used to automatically create parent directories if they don't exist
- Use validate=true for code files to catch syntax errors
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
            enum = {
              'create',
              'overwrite',
              'append',
              'insert',
              'delete',
              'replace',
              'remove',
            },
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
          backup = {
            type = 'boolean',
            description = 'Create backup before modification (default: false)',
          },
          validate = {
            type = 'boolean',
            description = 'Validate syntax after modification for code files (default: false)',
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

    if args.validate then
      info = info .. ' [validate]'
    end

    if args.backup then
      info = info .. ' [backup]'
    end

    return info
  end
  return 'write_file'
end

return M
