local M = {}

local util = require('chat.util')

---@class ChatToolsListDirectoryAction
---@field path string Directory path to list
---@field recursive boolean? List recursively (default: false)
---@field max_results number? Maximum number of entries (default: 200)
---@field show_hidden boolean? Show hidden files (default: false)

--- Check if path is within cwd
---@param filepath string normalized absolute path
---@param cwd string normalized absolute cwd path
---@return boolean
local function is_within_cwd(filepath, cwd)
  if not cwd or cwd == '' then
    return false
  end
  -- Ensure both have trailing slash for proper prefix matching
  local fp = filepath:match('[/\\]$') and filepath or (filepath .. '/')
  local cw = cwd:match('[/\\]$') and cwd or (cwd .. '/')
  return vim.startswith(fp, cw)
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

--- Type symbol for display
---@param ftype string
---@return string
local function type_symbol(ftype)
  if ftype == 'directory' then
    return '[DIR] '
  elseif ftype == 'file' then
    return '      '
  elseif ftype == 'link' then
    return '[LINK]'
  else
    return '[' .. (ftype or '?') .. ']'
  end
end

--- Collect entries from a directory
---@param dir_path string
---@param recursive boolean
---@param show_hidden boolean
---@param max_results number
---@return table[] entries
---@return boolean truncated
local function collect_entries(dir_path, recursive, show_hidden, max_results)
  local entries = {}
  local truncated = false

  local function scan(dir, prefix)
    local items = {}
    for name, ftype in vim.fs.dir(dir) do
      if show_hidden or not name:match('^%.') then
        table.insert(items, { name = name, ftype = ftype })
      end
    end

    -- Sort: directories first, then alphabetically
    table.sort(items, function(a, b)
      if a.ftype ~= b.ftype then
        return a.ftype == 'directory'
      end
      return a.name < b.name
    end)

    for _, item in ipairs(items) do
      if #entries >= max_results then
        truncated = true
        return
      end

      local full_path = dir .. '/' .. item.name
      local display_path = prefix and (prefix .. '/' .. item.name) or item.name

      local size = -1
      if item.ftype == 'file' then
        size = vim.fn.getfsize(full_path)
      end

      table.insert(entries, {
        name = item.name,
        display_path = display_path,
        ftype = item.ftype,
        size = size,
        mtime = vim.fn.getftime(full_path),
      })

      -- Recurse into subdirectories
      if recursive and item.ftype == 'directory' and not truncated then
        scan(full_path, display_path)
      end
    end
  end

  scan(dir_path, nil)
  return entries, truncated
end

---@param action ChatToolsListDirectoryAction
---@param ctx ChatToolContext
function M.list_directory(action, ctx)
  if not ctx.cwd or ctx.cwd == '' then
    return { error = 'No working directory (cwd) specified in context.' }
  end

  local resolved, err = resolve_and_validate(action.path, ctx.cwd)
  if err then
    return { error = err }
  end

  if vim.fn.getftype(resolved) == '' then
    return { error = string.format('Directory does not exist: %s', resolved) }
  end

  if vim.fn.getftype(resolved) ~= 'dir' then
    return { error = string.format('Path is not a directory: %s', resolved) }
  end

  local recursive = action.recursive or false
  local show_hidden = action.show_hidden or false
  local max_results = action.max_results or 200

  local entries, truncated = collect_entries(
    resolved, recursive, show_hidden, max_results
  )

  if #entries == 0 then
    return {
      content = string.format('Directory is empty: %s', resolved),
    }
  end

  -- Build output
  local lines = {}
  table.insert(lines, string.format('%s (%d items%s)',
    resolved,
    #entries,
    truncated and string.format(', truncated at %d', max_results) or ''
  ))
  table.insert(lines, string.rep('-', 60))

  for _, entry in ipairs(entries) do
    local sym = type_symbol(entry.ftype)
    local size_str = ''
    if entry.ftype == 'file' and entry.size >= 0 then
      size_str = string.format(' %10s', format_size(entry.size))
    elseif entry.ftype == 'directory' then
      size_str = '          '
    end

    local time_str = ''
    if entry.mtime > 0 then
      time_str = os.date(' %Y-%m-%d %H:%M', entry.mtime)
    end

    table.insert(lines, string.format('%s %s%s %s',
      sym, entry.display_path, size_str, time_str
    ))
  end

  if truncated then
    table.insert(lines, string.rep('-', 60))
    table.insert(lines, string.format(
      '... and more (showing %d of unknown total, increase max_results to see more)',
      max_results
    ))
  end

  return { content = table.concat(lines, '\n') }
end

function M.scheme()
  return {
    type = 'function',
    ['function'] = {
      name = 'list_directory',
      description = [[List directory contents with file metadata.

Displays entries with type indicator, size, and modification time.
Directories are shown first, sorted alphabetically within each group.

SECURITY:
- Path must be within working directory (cwd) and allowed_path config

BEHAVIOR:
- Non-recursive by default (top-level entries only)
- Use recursive=true for tree-like listing
- Hidden files (starting with .) are hidden by default
- Results are capped at max_results (default 200) to prevent overflow

EXAMPLES:
- @list_directory path="./src"
- @list_directory path="./" recursive=true
- @list_directory path="./test" show_hidden=true
- @list_directory path="./project" max_results=50
      ]],
      parameters = {
        type = 'object',
        properties = {
          path = {
            type = 'string',
            description = 'Directory path to list (relative to cwd or absolute)',
          },
          recursive = {
            type = 'boolean',
            description = 'List recursively (default: false)',
          },
          show_hidden = {
            type = 'boolean',
            description = 'Show hidden files (default: false)',
          },
          max_results = {
            type = 'number',
            description = 'Maximum number of entries to return (default: 200)',
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
    local flags = {}
    if args.recursive then table.insert(flags, 'recursive') end
    if args.show_hidden then table.insert(flags, 'hidden') end
    local flag_str = #flags > 0 and (' [' .. table.concat(flags, ',') .. ']') or ''
    return string.format('list_directory %s%s', resolved, flag_str)
  end
  return 'list_directory'
end

return M

