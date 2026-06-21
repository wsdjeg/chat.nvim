local M = {}

local util = require('chat.util')

---@class ChatToolsCopyFileAction
---@field source string
---@field destination string
---@field overwrite boolean? Overwrite destination if it exists (default: false)

--- Check if path is within cwd
---@param filepath string normalized absolute path
---@param cwd string normalized absolute cwd path
---@return boolean
local function is_within_cwd(filepath, cwd)
  if not cwd or cwd == '' then
    return false
  end
  local fp = filepath:match('[/\\]$') and filepath or (filepath .. '/')
  local cw = cwd:match('[/\\]$') and cwd or (cwd .. '/')
  return vim.startswith(fp, cw)
end

--- Resolve and validate a path
---@param path string
---@param cwd string
---@param label string for error messages
---@return string? resolved_path
---@return string? error
local function resolve_and_validate(path, cwd, label)
  if
    not path
    or type(path) ~= 'string'
    or path == ''
  then
    return nil, label .. ' is required and must be a non-empty string.'
  end

  local resolved = util.resolve(path, cwd)
  if not resolved then
    return nil, 'Failed to resolve ' .. label .. '.'
  end

  local norm_cwd = vim.fs.normalize(cwd)
  if not norm_cwd:match('[/\\]$') then
    norm_cwd = norm_cwd .. '/'
  end

  if not is_within_cwd(resolved, norm_cwd) then
    return nil, string.format(
      'Security: %s must be within working directory.\n  path: %s\n  cwd: %s',
      label, resolved, norm_cwd
    )
  end

  if not util.is_allowed_path(resolved) then
    return nil, string.format(
      'Security: %s is not in allowed_path.\n  path: %s',
      label, resolved
    )
  end

  return resolved, nil
end

--- Format file size to human readable
---@param size number
---@return string
local function format_size(size)
  if size < 0 then
    return '-'
  end
  if size < 1024 then
    return string.format('%dB', size)
  elseif size < 1024 * 1024 then
    return string.format('%.1fKB', size / 1024)
  elseif size < 1024 * 1024 * 1024 then
    return string.format('%.1fMB', size / (1024 * 1024))
  else
    return string.format('%.1fGB', size / (1024 * 1024 * 1024))
  end
end

--- Recursive copy using uv
---@param source string
---@param destination string
---@return boolean ok
---@return string? error
local function copy_recursive(source, destination)
  local source_type = vim.fn.getftype(source)
  if source_type == 'file' then
    local ok, err = vim.uv.fs_copyfile(source, destination)
    if not ok then
      return false, err or 'copy failed'
    end
    return true, nil
  elseif source_type == 'dir' then
    local ok, err = pcall(function()
      vim.fn.mkdir(destination, 'p')
      for name, ftype in vim.fs.dir(source) do
        local src = source .. '/' .. name
        local dst = destination .. '/' .. name
        if ftype == 'file' then
          local cok, cerr = vim.uv.fs_copyfile(src, dst)
          if not cok then
            error(cerr or 'copy failed for ' .. src)
          end
        elseif ftype == 'directory' then
          copy_recursive(src, dst)
        end
      end
    end)
    if not ok then
      return false, err or 'recursive copy failed'
    end
    return true, nil
  end
  return false, 'unsupported file type: ' .. tostring(source_type)
end

---@param action ChatToolsCopyFileAction
---@param ctx ChatToolContext
function M.copy_file(action, ctx)
  if not ctx.cwd or ctx.cwd == '' then
    return { error = 'No working directory (cwd) specified in context.' }
  end
  local source, src_err = resolve_and_validate(
    action.source, ctx.cwd, 'source'
  )
  if src_err then
    return { error = src_err }
  end

  local dest, dst_err = resolve_and_validate(
    action.destination, ctx.cwd, 'destination'
  )
  if dst_err then
    return { error = dst_err }
  end

  -- Check source exists
  if vim.fn.getftype(source) == '' then
    return { error = string.format('Source does not exist: %s', source) }
  end

  -- Prevent copying into itself
  if source == dest then
    return { error = 'Source and destination are the same path.' }
  end

  -- Check if destination is inside source (would cause infinite recursion)
  if vim.startswith(dest, source .. '/') then
    return {
      error = 'Cannot copy a directory into itself (destination is inside source).'
    }
  end

  -- Check destination
  local dest_exists = vim.fn.getftype(dest) ~= ''
  if dest_exists then
    if not action.overwrite then
      return {
        error = string.format(
          'Destination already exists: %s\nUse overwrite=true to replace it.',
          dest
        ),
      }
    end
    local ok, err = pcall(vim.fn.delete, dest, 'rf')
    if not ok then
      return { error = string.format(
        'Failed to remove existing destination: %s\n%s', dest, err
      ) }
    end
  end

  -- Copy
  local ok, err = copy_recursive(source, dest)
  if not ok then
    pcall(vim.fn.delete, dest, 'rf')
    return {
      error = string.format(
        'Copy failed: %s\n  source: %s\n  destination: %s',
        err or 'unknown error', source, dest
      ),
    }
  end

  -- Summary
  local src_type = vim.fn.getftype(source)
  local src_size = vim.fn.getfsize(source)
  local summary = string.format(
    'Successfully copied: %s -> %s',
    source, dest
  )
  if src_type == 'file' and src_size >= 0 then
    summary = summary .. string.format(' (%s)', format_size(src_size))
  elseif src_type == 'dir' then
    local count = 0
    for _ in vim.fs.dir(dest) do
      count = count + 1
    end
    summary = summary .. string.format(' (%d entries)', count)
  end

  return { content = summary }
end

function M.scheme()
  return {
    type = 'function',
    ['function'] = {
      name = 'copy_file',
      description = [[Copy a file or directory (recursive).

Works for both files and directories. Directory copies are recursive.
Source is preserved (unlike move_file which removes source).

SECURITY:
- Both source and destination must be within working directory (cwd)
- Both source and destination must be within allowed_path config

BEHAVIOR:
- Copies files and directories recursively
- Use overwrite=true to replace existing destination
- Prevents copying a directory into itself

EXAMPLES:
- @copy_file source="./config.json" destination="./config.backup.json"
- @copy_file source="./src" destination="./src_copy"
- @copy_file source="./templates/" destination="./new_project/templates/" overwrite=true
      ]],
      parameters = {
        type = 'object',
        properties = {
          source = {
            type = 'string',
            description = 'Source file/directory path (relative to cwd or absolute)',
          },
          destination = {
            type = 'string',
            description = 'Destination file/directory path (relative to cwd or absolute)',
          },
          overwrite = {
            type = 'boolean',
            description = 'Overwrite destination if it exists (default: false)',
          },
        },
        required = { 'source', 'destination' },
      },
    },
  }
end

function M.info(action_str, ctx)
  local ok, args = pcall(vim.json.decode, action_str)
  if ok then
    local src = util.resolve(args.source, ctx.cwd) or args.source
    local dst = util.resolve(args.destination, ctx.cwd) or args.destination
    local info = string.format('copy_file %s -> %s', src, dst)
    if args.overwrite then
      info = info .. ' [overwrite]'
    end
    return info
  end
  return 'copy_file'
end

return M

