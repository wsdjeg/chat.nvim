local M = {}

local config = require('chat.config')

-- Compatibility: provide startsWith function for older Neovim versions
local function starts_with(str, prefix)
  if vim.startswith then
    return vim.startswith(str, prefix)
  else
    return str:sub(1, #prefix) == prefix
  end
end

-- Cache rg availability check result
local rg_available = nil
local function is_rg_available()
  if rg_available == nil then
    local rg_check = vim.fn.system({ 'rg', '--version' })
    rg_available = vim.v.shell_error == 0
  end
  return rg_available
end

---@class ChatToolsSearchTextAction
---@field pattern string
---@field directory? string
---@field file_types? string[]
---@field exclude_patterns? string[]
---@field ignore_case? boolean
---@field whole_word? boolean
---@field regex? boolean
---@field max_results? integer
---@field context_lines? integer

---@param action ChatToolsSearchTextAction
---@param ctx ChatContext
function M.search_text(action, ctx)
  -- Parameter validation (enhanced)
  if
    not action.pattern
    or type(action.pattern) ~= 'string'
    or action.pattern == ''
  then
    return {
      error = 'Pattern is required and must be a non-empty string.',
    }
  end

  -- Security check
  local search_directory = action.directory or ctx.cwd
  local is_allowed_path = false

  -- Verify search directory exists
  if vim.fn.isdirectory(search_directory) == 0 then
    return {
      error = string.format('Directory does not exist: %s', search_directory),
    }
  end

  if type(config.config.allowed_path) == 'table' then
    for _, v in ipairs(config.config.allowed_path) do
      if
        type(v) == 'string'
        and #v > 0
        and starts_with(search_directory, v)
      then
        is_allowed_path = true
        break
      end
    end
  elseif
    type(config.config.allowed_path) == 'string'
    and #config.config.allowed_path > 0
  then
    is_allowed_path =
      starts_with(search_directory, config.config.allowed_path)
  end

  if not is_allowed_path then
    return {
      error = string.format(
        'Cannot search in non-allowed path: %s',
        search_directory
      ),
    }
  end

  -- Check if rg is available (using cached version)
  if not is_rg_available() then
    return {
      error = 'ripgrep (rg) is not installed or not in PATH. Please install it first.',
    }
  end

  -- Build command
  local cmd = { 'rg' }

  -- Basic options
  if action.ignore_case then
    table.insert(cmd, '-i')
  end

  if action.whole_word then
    table.insert(cmd, '-w')
  end

  if action.regex == false then
    table.insert(cmd, '-F') -- Fixed string mode
  end

  -- Result limit
  local max_results = action.max_results or 100
  table.insert(cmd, '-m')
  table.insert(cmd, tostring(max_results))

  -- Context lines
  if action.context_lines and action.context_lines > 0 then
    table.insert(cmd, '-C')
    table.insert(cmd, tostring(action.context_lines))
  end

  -- File type filtering
  if action.file_types and type(action.file_types) == 'table' then
    for _, ft in ipairs(action.file_types) do
      table.insert(cmd, '-g')
      table.insert(cmd, ft)
    end
  end

  -- Exclusion patterns
  if action.exclude_patterns and type(action.exclude_patterns) == 'table' then
    for _, excl in ipairs(action.exclude_patterns) do
      table.insert(cmd, '--glob')
      table.insert(cmd, '!' .. excl)
    end
  end

  -- Output format
  table.insert(cmd, '--color=never')
  table.insert(cmd, '-n')
  table.insert(cmd, '--with-filename')
  table.insert(cmd, '--heading')
  table.insert(cmd, '--sort=path')

  -- Search pattern and directory
  table.insert(cmd, action.pattern)
  table.insert(cmd, search_directory)

  -- Execute search
  local result = vim.fn.system(cmd)
  local exit_code = vim.v.shell_error

  -- Process results
  if exit_code == 0 then
    local lines = vim.split(result:gsub('\r\n', '\n'), '\n')
    local match_count = 0
    local file_count = 0
    local current_file = nil

    -- More accurate match counting
    for _, line in ipairs(lines) do
      if #line > 0 then
        -- Check if line is a match line (rg output format: file:line:content)
        if line:match('^[^:]+:%d+[:%d]*:') then
          match_count = match_count + 1
          local file_name = line:match('^([^:]+):%d+')
          if file_name ~= current_file then
            current_file = file_name
            file_count = file_count + 1
          end
        end
      end
    end

    local summary = string.format(
      'Found %d matches in %d files for "%s" in directory "%s"\n',
      match_count,
      file_count,
      action.pattern,
      search_directory
    )

    if action.file_types then
      summary = summary
        .. string.format(
          'File types: %s\n',
          table.concat(action.file_types, ', ')
        )
    end

    if action.exclude_patterns then
      summary = summary
        .. string.format(
          'Excluded patterns: %s\n',
          table.concat(action.exclude_patterns, ', ')
        )
    end

    if #result > 0 then
      return {
        content = summary .. '\n' .. result,
      }
    else
      return {
        content = summary .. '\n(No specific match content)',
      }
    end
  elseif exit_code == 1 then
    return {
      content = string.format(
        'No matches found for "%s" in directory "%s"\n\n'
          .. 'Search parameters:\n'
          .. '  Directory: %s\n'
          .. '  Case sensitive: %s\n'
          .. '  Regex: %s\n'
          .. '  Max results: %d',
        action.pattern,
        search_directory,
        search_directory,
        action.ignore_case and 'no' or 'yes',
        action.regex == false and 'no' or 'yes',
        max_results
      ),
    }
  else
    return {
      error = string.format(
        'Search command failed (exit code: %d):\n\nCommand: %s\n\nOutput:\n%s',
        exit_code,
        table.concat(cmd, ' '),
        result
      ),
    }
  end
end

function M.scheme()
  return {
    type = 'function',
    ['function'] = {
      name = 'search_text',
      description = [[
      Advanced text search tool using ripgrep (rg) to search text content in directories.
      Supports regex, file type filtering, exclusion patterns, context lines, and other advanced features.

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
          pattern = {
            type = 'string',
            description = 'Text pattern to search for (supports regex)',
          },
          directory = {
            type = 'string',
            description = 'Directory path to search in (default: current working directory)',
          },
          file_types = {
            type = 'array',
            description = 'File type filter, e.g., ["*.py", "*.md", "*.txt"]',
            items = { type = 'string' },
          },
          exclude_patterns = {
            type = 'array',
            description = 'Exclude file patterns, e.g., ["*.log", "tmp/*"]',
            items = { type = 'string' },
          },
          ignore_case = {
            type = 'boolean',
            description = 'Whether to ignore case (default: false)',
          },
          whole_word = {
            type = 'boolean',
            description = 'Whether to match whole words only (default: false)',
          },
          regex = {
            type = 'boolean',
            description = 'Whether to use regex (default: true)',
          },
          max_results = {
            type = 'integer',
            description = 'Maximum number of results (default: 100)',
          },
          context_lines = {
            type = 'integer',
            description = 'Number of context lines to show around matches (default: 0)',
          },
        },
        required = { 'pattern' },
      },
    },
  }
end

function M.info(action, ctx)
  local ok, arguments = pcall(vim.json.decode, action)
  if ok then
    local info_parts = {
      string.format('search_text "%s"', arguments.pattern),
      string.format('in %s', arguments.directory or ctx.cwd),
    }

    local options = {}
    if arguments.ignore_case then
      table.insert(options, 'ignore_case')
    end
    if arguments.whole_word then
      table.insert(options, 'whole_word')
    end
    if arguments.regex == false then
      table.insert(options, 'no_regex')
    end
    if arguments.max_results then
      table.insert(options, 'max=' .. arguments.max_results)
    end
    if arguments.context_lines then
      table.insert(options, 'context=' .. arguments.context_lines)
    end

    if #options > 0 then
      table.insert(info_parts, '[' .. table.concat(options, ', ') .. ']')
    end

    return table.concat(info_parts, ' ')
  else
    return 'search_text'
  end
end

return M
