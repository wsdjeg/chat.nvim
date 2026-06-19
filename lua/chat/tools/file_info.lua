local M = {}

local util = require('chat.util')

---@class ChatToolsFileInfoAction
---@field filepath string File or directory path

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
---@return string? resolved_path
---@return string? error
local function resolve_and_validate(path, cwd)
  if
    not path
    or type(path) ~= 'string'
    or path == ''
  then
    return nil, 'filepath is required and must be a non-empty string.'
  end

  local resolved = util.resolve(path, cwd)
  if not resolved then
    return nil, 'Failed to resolve filepath.'
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

--- Get permissions string
---@param filepath string
---@return string
local function get_perms(filepath)
  local attrs = vim.fn.getfperm(filepath)
  if attrs and attrs ~= '' then
    return attrs
  end
  return '---------'
end

---@param action ChatToolsFileInfoAction
---@param ctx ChatToolContext
function M.file_info(action, ctx)
  if not ctx.cwd or ctx.cwd == '' then
    return { error = 'No working directory (cwd) specified in context.' }
  end

  local resolved, err = resolve_and_validate(action.filepath, ctx.cwd)
  if err then
    return { error = err }
  end

  if vim.fn.getftype(resolved) == '' then
    return { error = string.format('Path does not exist: %s', resolved) }
  end

  local ftype = vim.fn.getftype(resolved)
  local size = vim.fn.getfsize(resolved)
  local mtime = vim.fn.getftime(resolved)
  local perms = get_perms(resolved)

  local lines = {}
  table.insert(lines, string.format('Path:       %s', resolved))
  table.insert(lines, string.format('Type:       %s', ftype))

  if ftype == 'file' then
    table.insert(lines, string.format('Size:       %s (%d bytes)',
      format_size(size), size
    ))
  elseif ftype == 'dir' then
    -- Count entries in directory
    local count = 0
    for _ in vim.fs.dir(resolved) do
      count = count + 1
    end
    table.insert(lines, string.format('Entries:    %d', count))
  end

  table.insert(lines, string.format('Modified:   %s',
    mtime > 0 and os.date('%Y-%m-%d %H:%M:%S', mtime) or '-'
  ))
  table.insert(lines, string.format('Permissions: %s', perms))

  -- For files, show line count if text file
  if ftype == 'file' and size >= 0 and size < 1024 * 1024 then
    local ok, read_result = pcall(vim.fn.readfile, resolved)
    if ok and type(read_result) == 'table' then
      table.insert(lines, string.format('Lines:      %d', #read_result))
    end
  end

  return { content = table.concat(lines, '\n') }
end

function M.scheme()
  return {
    type = 'function',
    ['function'] = {
      name = 'file_info',
      description = [[Get file or directory metadata.

Returns type, size, modification time, permissions, and line count (for text files).
Lighter than read_file when you only need metadata, not content.

SECURITY:
- Path must be within working directory (cwd) and allowed_path config

EXAMPLES:
- @file_info filepath="./src/main.lua"
- @file_info filepath="./src/"
- @file_info filepath="./config.json"
      ]],
      parameters = {
        type = 'object',
        properties = {
          filepath = {
            type = 'string',
            description = 'File or directory path (relative to cwd or absolute)',
          },
        },
        required = { 'filepath' },
      },
    },
  }
end

function M.info(action_str, ctx)
  local ok, args = pcall(vim.json.decode, action_str)
  if ok then
    local resolved = util.resolve(args.filepath, ctx.cwd) or args.filepath
    return string.format('file_info %s', resolved)
  end
  return 'file_info'
end

return M

