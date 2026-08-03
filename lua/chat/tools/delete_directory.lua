local M = {}

local util = require('chat.util')

---@class ChatToolsDeleteDirectoryAction
---@field path string Directory path to delete

--- Check if path is within cwd (path itself or under cwd)
---@param filepath string normalized absolute path
---@param cwd string normalized absolute cwd path (with trailing separator)
---@return boolean
local function is_within_cwd(filepath, cwd)
  if not cwd or cwd == '' then
    return false
  end
  -- Strip trailing separator from filepath for comparison
  local fp = filepath:gsub('[/\\]+$', '')
  local cw = cwd:gsub('[/\\]+$', '')
  return fp == cw or vim.startswith(fp, cw .. '/')
end

--- Resolve and validate a path
---@param path string
---@param cwd string
---@return string? resolved_path
---@return string? error
local function resolve_and_validate(path, cwd)
  if
    not path
    or type(path) ~= 'string'
    or path == ''
  then
    return nil, 'path is required and must be a non-empty string.'
  end

  local resolved = util.resolve(path, cwd)
  if not resolved then
    return nil, 'Failed to resolve path.'
  end

  local norm_cwd = vim.fs.normalize(cwd)
  if not norm_cwd:match('[/\\]$') then
    norm_cwd = norm_cwd .. '/'
  end

  if not is_within_cwd(resolved, norm_cwd) then
    return nil, string.format(
      'Security: path must be within working directory.\n  path: %s\n  cwd: %s',
      resolved, norm_cwd
    )
  end

  if not util.is_allowed_path(resolved) then
    return nil, string.format(
      'Security: path is not in allowed_path.\n  path: %s',
      resolved
    )
  end

  return resolved, nil
end

--- Count entries in a directory (recursive)
---@param dir string
---@return integer file_count
---@return integer dir_count
local function count_entries(dir)
  local file_count = 0
  local dir_count = 0
  for name, ftype in vim.fs.dir(dir) do
    if ftype == 'file' then
      file_count = file_count + 1
    elseif ftype == 'directory' then
      dir_count = dir_count + 1
      local fc, dc = count_entries(dir .. '/' .. name)
      file_count = file_count + fc
      dir_count = dir_count + dc
    end
  end
  return file_count, dir_count
end

---@param action ChatToolsDeleteDirectoryAction
---@param ctx ChatToolContext
function M.delete_directory(action, ctx)
  if not ctx.cwd or ctx.cwd == '' then
    return { error = 'No working directory (cwd) specified in context.' }
  end

  local resolved, err = resolve_and_validate(action.path, ctx.cwd)
  if err then
    return { error = err }
  end

  -- Check path exists
  local ftype = vim.fn.getftype(resolved)
  if ftype == '' then
    return { error = string.format('Path does not exist: %s', resolved) }
  end

  -- Must be a directory
  if ftype ~= 'dir' then
    return {
      error = string.format(
        'Path is not a directory: %s\nUse write_file with action="remove" to delete files.',
        resolved
      ),
    }
  end

  -- Safety: refuse to delete cwd itself
  local norm_cwd = vim.fs.normalize(ctx.cwd):gsub('[/\\]+$', '')
  local norm_resolved = resolved:gsub('[/\\]+$', '')
  if norm_resolved == norm_cwd then
    return {
      error = 'Safety: refusing to delete the working directory (cwd) itself.\n  cwd: '
        .. norm_cwd,
    }
  end

  -- Count entries before deletion (for summary)
  local file_count, dir_count = count_entries(resolved)
  local total_entries = file_count + dir_count

  -- Delete recursively (rf = recursive + force)
  local ok, del_err = pcall(vim.fn.delete, resolved, 'rf')
  if not ok then
    return {
      error = string.format(
        'Failed to delete directory: %s\n%s',
        resolved, del_err or 'unknown error'
      ),
    }
  end

  -- Verify deletion
  if vim.fn.getftype(resolved) ~= '' then
    return {
      error = string.format(
        'Directory deletion reported success but path still exists: %s',
        resolved
      ),
    }
  end

  local summary = string.format(
    'Successfully deleted directory: %s',
    resolved
  )
  if total_entries > 0 then
    summary = summary
      .. string.format(' (%d files, %d subdirectories)', file_count, dir_count)
  else
    summary = summary .. ' (empty directory)'
  end

  return { content = summary }
end

function M.scheme()
  return {
    type = 'function',
    ['function'] = {
      name = 'delete_directory',
      description = [[Delete a directory (recursive).

Equivalent to `rm -rf`. Removes the directory and all its contents recursively.
Cannot delete the working directory (cwd) itself for safety.

SECURITY:
- Path must be within working directory (cwd) and allowed_path config
- Refuses to delete the cwd itself

BEHAVIOR:
- Deletes directory and all contents recursively (rm -rf)
- If path does not exist, returns error
- If path is a file (not directory), returns error (use write_file action="remove" instead)
- Reports file and directory counts after deletion

EXAMPLES:
- @delete_directory path="./old_build"
- @delete_directory path="./temp/cache"
- @delete_directory path="./node_modules"
      ]],
      parameters = {
        type = 'object',
        properties = {
          path = {
            type = 'string',
            description = 'Directory path to delete (relative to cwd or absolute)',
          },
        },
        required = { 'path' },
      },
    },
  }
end

function M.info(action_str, ctx)
  local ok, args = pcall(vim.json.decode, action_str)
  if ok then
    local resolved = util.resolve(args.path, ctx.cwd) or args.path
    return string.format('delete_directory %s', resolved)
  end
  return 'delete_directory'
end

return M

