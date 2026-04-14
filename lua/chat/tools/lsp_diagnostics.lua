local M = {}

local util = require('chat.util')

---@class ChatToolsLspDiagnosticsAction
---@field filepath string
---@field severity? 'Error' | 'Warn' | 'Info' | 'Hint' | 'All'
---@field line_start? integer
---@field line_to? integer

---@param action ChatToolsLspDiagnosticsAction
---@param ctx ChatToolContext
function M.lsp_diagnostics(action, ctx)
  -- Security check for ctx.cwd
  if not util.is_allowed_path(ctx.cwd) then
    return {
      error = string.format(
        'Access denied: cwd (%s) is outside allowed paths',
        ctx.cwd
      ),
    }
  end

  -- filepath is required
  if not action.filepath then
    return {
      error = 'filepath parameter is required',
    }
  end

  -- Resolve and validate filepath
  local resolved_path = util.resolve(action.filepath, ctx.cwd)
  if not resolved_path then
    return {
      error = string.format('failed to resolve filepath: %s', action.filepath),
    }
  end

  -- Security: ensure resolved_path is within ctx.cwd
  local normalized_resolved = vim.fs.normalize(resolved_path)
  local normalized_cwd = vim.fs.normalize(ctx.cwd)
  if not vim.startswith(normalized_resolved, normalized_cwd) then
    return {
      error = string.format(
        'Security error: filepath (%s) is outside cwd (%s)',
        resolved_path,
        ctx.cwd
      ),
    }
  end

  -- Security: check if path is allowed
  if not util.is_allowed_path(resolved_path) then
    return {
      error = string.format(
        'Access denied: filepath (%s) is outside allowed paths',
        resolved_path
      ),
    }
  end

  -- Get the target buffer
  local bufnr = vim.fn.bufnr(vim.fn.fnameescape(resolved_path))
  if bufnr == -1 then
    return {
      error = string.format('Buffer not found for file: %s', resolved_path),
    }
  end

  -- Check if LSP is attached to this buffer
  local clients = vim.lsp.get_clients({ bufnr = bufnr })
  if #clients == 0 then
    return {
      error = string.format(
        'No LSP client attached to %s. Ensure a language server is running.',
        resolved_path
      ),
    }
  end

  -- Get severity filter
  local severity_map = {
    Error = vim.diagnostic.severity.ERROR,
    Warn = vim.diagnostic.severity.WARN,
    Info = vim.diagnostic.severity.INFO,
    Hint = vim.diagnostic.severity.HINT,
    All = nil,
  }

  local severity_filter = nil
  if action.severity and severity_map[action.severity] then
    severity_filter = severity_map[action.severity]
  end

  -- Get diagnostics
  local opts = {
    bufnr = bufnr,
  }
  if severity_filter then
    opts.severity = severity_filter
  end

  local diagnostics = vim.diagnostic.get(bufnr, opts)

  -- Filter by line range if specified
  if action.line_start or action.line_to then
    local start_line = action.line_start and (action.line_start - 1) or 0
    local end_line = action.line_to and (action.line_to - 1) or math.huge

    local filtered = {}
    for _, diag in ipairs(diagnostics) do
      if diag.lnum >= start_line and diag.lnum <= end_line then
        table.insert(filtered, diag)
      end
    end
    diagnostics = filtered
  end

  -- Format output
  if #diagnostics == 0 then
    local msg = 'No diagnostics found'
    if action.severity then
      msg = msg .. string.format(' with severity: %s', action.severity)
    end
    if action.line_start or action.line_to then
      local start_line = action.line_start or 1
      local end_line = action.line_to or 'end'
      msg = msg .. string.format(' in lines %s-%s', start_line, end_line)
    end
    return {
      content = msg,
    }
  end

  -- Format diagnostics
  local lines = {
    string.format('Found %d diagnostic(s) in %s:', #diagnostics, resolved_path),
    '',
  }

  local severity_names = {
    [vim.diagnostic.severity.ERROR] = 'Error',
    [vim.diagnostic.severity.WARN] = 'Warn',
    [vim.diagnostic.severity.INFO] = 'Info',
    [vim.diagnostic.severity.HINT] = 'Hint',
  }

  for _, diag in ipairs(diagnostics) do
    local severity = severity_names[diag.severity] or 'Unknown'
    local line = diag.lnum + 1 -- Convert to 1-indexed
    local col = diag.col + 1   -- Convert to 1-indexed
    local message = diag.message:gsub('%s+', ' ') -- Normalize whitespace

    table.insert(
      lines,
      string.format('  [%s] Line %d, Col %d: %s', severity, line, col, message)
    )

    -- Add source and code if available
    local details = {}
    if diag.source then
      table.insert(details, string.format('source: %s', diag.source))
    end
    if diag.code then
      table.insert(details, string.format('code: %s', diag.code))
    end
    if #details > 0 then
      table.insert(lines, string.format('    (%s)', table.concat(details, ', ')))
    end
  end

  return {
    content = table.concat(lines, '\n'),
  }
end

function M.scheme()
  return {
    type = 'function',
    ['function'] = {
      name = 'lsp_diagnostics',
      description = [[
      Get LSP diagnostics (errors, warnings, hints) for a file.

      This tool uses Neovim's built-in LSP diagnostic system to retrieve
      diagnostic messages from attached language servers.

      Examples:
      - @lsp_diagnostics filepath="./src/main.lua"                  - Get all diagnostics
      - @lsp_diagnostics filepath="./src/main.lua" severity=Error   - Get only errors
      - @lsp_diagnostics filepath="./src/main.lua" severity=Warn    - Get only warnings
      - @lsp_diagnostics filepath="./src/main.lua" line_start=10 line_to=20  - Get diagnostics for lines 10-20

      Notes:
      - Requires an LSP client to be attached to the file
      - Line numbers are 1-indexed
      - Severities: Error, Warn, Info, Hint, All (default: All)
      - filepath must be within the current working directory (required)
      ]],
      parameters = {
        type = 'object',
        properties = {
          filepath = {
            type = 'string',
            description = 'File path to get diagnostics for (must be within cwd)',
          },
          severity = {
            type = 'string',
            description = 'Filter by severity level: Error, Warn, Info, Hint, or All (default: All)',
            enum = { 'Error', 'Warn', 'Info', 'Hint', 'All' },
          },
          line_start = {
            type = 'integer',
            description = 'Starting line number (1-indexed, inclusive)',
            minimum = 1,
          },
          line_to = {
            type = 'integer',
            description = 'Ending line number (1-indexed, inclusive)',
            minimum = 1,
          },
        },
        required = { 'filepath' },
      },
    },
  }
end

function M.info(action, ctx)
  local ok, arguments = pcall(vim.json.decode, action)
  if ok then
    local parts = { 'lsp_diagnostics' }
    if arguments.filepath then
      table.insert(parts, string.format('filepath=%s', arguments.filepath))
    end
    if arguments.severity then
      table.insert(parts, string.format('severity=%s', arguments.severity))
    end
    if arguments.line_start or arguments.line_to then
      local start_line = arguments.line_start or 1
      local end_line = arguments.line_to or 'end'
      table.insert(parts, string.format('lines=%s-%s', start_line, end_line))
    end
    return table.concat(parts, ' ')
  else
    return 'lsp_diagnostics'
  end
end

return M

