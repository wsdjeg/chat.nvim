local M = {}

local util = require('chat.util')

---@class ChatToolsMoveFileAction
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
  return vim.startswith(filepath, cwd)
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

  -- Ensure cwd ends with separator for proper prefix matching
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

--- Fallback copy for cross-device moves
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

---@param action ChatToolsMoveFileAction
---@param ctx ChatToolContext
function M.move_file(action, ctx)
  -- Validate ctx.cwd
  if not ctx.cwd or ctx.cwd == '' then
    return { error = 'No working directory (cwd) specified in context.' }
  end

  -- Resolve and validate source
  local source, src_err = resolve_and_validate(
    action.source, ctx.cwd, 'source'
  )
  if src_err then
    return { error = src_err }
  end

  -- Resolve and validate destination
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

  -- Check destination exists
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
    -- Delete existing destination
    local ok, err = pcall(vim.fn.delete, dest, 'rf')
    if not ok then
      return { error = string.format(
        'Failed to remove existing destination: %s\n%s', dest, err
      ) }
    end
  end

  -- Try rename first (works for same-device moves, both files and dirs)
  local ok, err = pcall(vim.fn.rename, source, dest)
  if ok and vim.fn.getftype(dest) ~= '' then
    return {
      content = string.format(
        'Successfully moved: %s -> %s',
        source, dest
      ),
    }
  end

  -- Rename failed (likely cross-device): fallback to copy + delete
  local copy_ok, copy_err = copy_recursive(source, dest)
  if not copy_ok then
    -- Clean up partial copy
    pcall(vim.fn.delete, dest, 'rf')
    return {
      error = string.format(
        'Move failed (rename: %s, copy fallback: %s)',
        err or 'unknown error', copy_err or 'unknown error'
      ),
    }
  end

  -- Delete source after successful copy
  local del_ok, del_err = pcall(vim.fn.delete, source, 'rf')
  if not del_ok then
    -- Copy succeeded but source deletion failed — warn but don't fail
    return {
      content = string.format(
        'Moved (with warning): %s -> %s\n'
        .. 'Copy succeeded but failed to remove source: %s\n'
        .. 'You may need to manually delete the source.',
        source, dest, del_err or 'unknown error'
      ),
    }
  end

  return {
    content = string.format(
      'Successfully moved: %s -> %s',
      source, dest
    ),
  }
end

function M.scheme()
  return {
    type = 'function',
    ['function'] = {
      name = 'move_file',
      description = [[Move or rename a file/directory.

SECURITY:
- Both source and destination must be within working directory (cwd)
- Both source and destination must be within allowed_path config

BEHAVIOR:
- Works for both files and directories
- Rename is attempted first (same-device, instant)
- Falls back to copy+delete for cross-device moves
- Use overwrite=true to replace existing destination

EXAMPLES:
- @move_file source="./src/old.lua" destination="./src/new.lua"
- @move_file source="./src/utils.lua" destination="./lib/utils.lua"
- @move_file source="./old_dir" destination="./new_dir" overwrite=true
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
    local info = string.format('move_file %s -> %s', src, dst)
    if args.overwrite then
      info = info .. ' [overwrite]'
    end
    return info
  end
  return 'move_file'
end

return M

