local M = {}

local util = require('chat.util')

---@class ChatToolsCreateDirectoryAction
---@field path string Directory path to create

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

---@param action ChatToolsCreateDirectoryAction
---@param ctx ChatToolContext
function M.create_directory(action, ctx)
  if not ctx.cwd or ctx.cwd == '' then
    return { error = 'No working directory (cwd) specified in context.' }
  end

  local resolved, err = resolve_and_validate(action.path, ctx.cwd)
  if err then
    return { error = err }
  end

  -- Already exists?
  if vim.fn.getftype(resolved) ~= '' then
    if vim.fn.getftype(resolved) == 'dir' then
      return {
        content = string.format(
          'Directory already exists: %s',
          resolved
        ),
      }
    end
    return {
      error = string.format(
        'Path already exists and is not a directory: %s',
        resolved
      ),
    }
  end

  -- Create directory (recursive, like mkdir -p)
  local ok, mk_err = pcall(vim.fn.mkdir, resolved, 'p')
  if not ok then
    return {
      error = string.format(
        'Failed to create directory: %s\n%s',
        resolved, mk_err or 'unknown error'
      ),
    }
  end

  -- Verify
  if vim.fn.getftype(resolved) ~= 'dir' then
    return {
      error = string.format(
        'Directory creation reported success but path not found: %s',
        resolved
      ),
    }
  end

  return {
    content = string.format(
      'Successfully created directory: %s',
      resolved
    ),
  }
end

function M.scheme()
  return {
    type = 'function',
    ['function'] = {
      name = 'create_directory',
      description = [[Create a directory (including parent directories).

Equivalent to `mkdir -p`. Creates all intermediate directories as needed.
If the directory already exists, reports success without error.

SECURITY:
- Path must be within working directory (cwd) and allowed_path config

BEHAVIOR:
- Creates parent directories automatically (mkdir -p)
- If directory already exists, returns success
- If path exists as a file, returns error

EXAMPLES:
- @create_directory path="./src/utils"
- @create_directory path="./test/integration/fixtures"
- @create_directory path="./docs/api/v1"
      ]],
      parameters = {
        type = 'object',
        properties = {
          path = {
            type = 'string',
            description = 'Directory path to create (relative to cwd or absolute)',
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
    return string.format('create_directory %s', resolved)
  end
  return 'create_directory'
end

return M

