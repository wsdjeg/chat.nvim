local M = {}

local util = require('chat.util')
local job = require('job')
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
    rg_available = vim.fn.executable('rg') == 1
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
---@param ctx ChatToolContext
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
  local search_directory = vim.fs.normalize(action.directory or ctx.cwd)

  -- Verify search directory exists
  if vim.fn.isdirectory(search_directory) == 0 then
    return {
      error = string.format('Directory does not exist: %s', search_directory),
    }
  end

  -- Security check: verify path is allowed
  if not util.is_allowed_path(search_directory) then
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

  -- Output format: JSON for better parsing
  table.insert(cmd, '--json')
  table.insert(cmd, '--sort=path')

  -- Search pattern and directory
  table.insert(cmd, action.pattern)
  table.insert(cmd, search_directory)

  local stdout = {}
  local stderr = {}

  local jobid = job.start(cmd, {
    on_stdout = function(_, data)
      for _, v in ipairs(data) do
        table.insert(stdout, v)
      end
    end,
    on_stderr = function(_, data)
      for _, v in ipairs(data) do
        table.insert(stderr, v)
      end
    end,
    on_exit = function(id, code, signal)
      if signal ~= 0 then
        ctx.callback({
          error = string.format(
            'search_text cancelled by user (signal: %d)',
            signal
          ),
          jobid = id,
        })
        return
      end
      if code == 0 and signal == 0 then
        -- Parse JSON output from ripgrep
        local matches = {}
        local file_set = {}

        for _, line in ipairs(stdout) do
          if #line > 0 then
            local ok, json_obj = pcall(vim.json.decode, line)
            if ok and json_obj then
              if json_obj.type == 'match' then
                local data = json_obj.data
                if data and data.path and data.path.text then
                  local file_path = data.path.text
                  local line_number = data.line_number or 1
                  local line_text = data.lines and data.lines.text or ''
                  -- Extract match info
                  local column = 1
                  if data.submatches and #data.submatches > 0 then
                    column = (data.submatches[1].start or 0) + 1
                  end
                  table.insert(matches, {
                    file = file_path,
                    lnum = line_number,
                    col = column,
                    text = line_text:gsub('\n$', ''), -- Remove trailing newline
                  })
                  file_set[file_path] = true
                end
              end
            end
          end
        end

        local match_count = #matches
        local file_count = vim.tbl_count(file_set)

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

        if match_count > 0 then
          -- Format output similar to rg default format
          local output_lines = {}
          for _, match in ipairs(matches) do
            table.insert(
              output_lines,
              string.format(
                '%s:%d:%d:%s',
                match.file,
                match.lnum,
                match.col,
                match.text
              )
            )
          end
          ctx.callback({
            content = summary .. '\n' .. table.concat(output_lines, '\n'),
            jobid = id,
          })
        else
          ctx.callback({
            content = summary .. '\n(No specific match content)',
            jobid = id,
          })
        end
      elseif code == 1 then
        ctx.callback({
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
          jobid = id,
        })
      else
        ctx.callback({
          error = string.format(
            'Search command failed (exit code: %d):\n\nCommand: %s\n\nOutput:\n%s',
            code,
            table.concat(cmd, ' '),
            table.concat(stderr, '\n')
          ),
          jobid = id,
        })
      end
    end,
  })
  return {
    jobid = jobid,
  }
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
      string.format(
        'in %s',
        vim.fs.normalize(arguments.directory or ctx.cwd)
      ),
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
