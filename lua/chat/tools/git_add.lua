local M = {}

local util = require('chat.util')
local job = require('job')

-- Cache git availability check
local git_available = nil
local function is_git_available()
  if git_available == nil then
    git_available = vim.fn.executable('git') == 1
  end
  return git_available
end

---Normalize path argument: handle string, stringified array, or table
---@param paths any
---@return string[]|nil result, string|nil error
local function normalize_paths(paths)
  if type(paths) == 'string' then
    -- LLM may pass array as string (e.g. '["a.lua", "b.lua"]')
    -- because many models don't support JSON Schema oneOf
    if vim.startswith(paths, '[') then
      local ok, parsed = pcall(vim.json.decode, paths)
      if ok and type(parsed) == 'table' then
        return parsed
      end
    end
    return { paths }
  elseif type(paths) == 'table' then
    return paths
  else
    return nil, 'path must be a string or array of strings.'
  end
end

---@class ChatToolsGitAddAction
---@field path? string|string[] File or directory path(s) to add
---@field all? boolean Add all changes (like git add -A)

---@param action ChatToolsGitAddAction
---@param ctx ChatToolContext
function M.git_add(action, ctx)
  if not util.is_allowed_path(ctx.cwd) then
    return {
      error = 'Cannot run git_add in non-allowed path.',
    }
  end

  if not is_git_available() then
    return {
      error = 'git is not installed or not in PATH.',
    }
  end

  -- Build git command
  local cmd = { 'git', '-C', ctx.cwd, 'add' }

  local resolved_paths = {}

  if action.all then
    -- Add all changes
    table.insert(cmd, '-A')
  elseif action.path then
    local paths, err = normalize_paths(action.path)
    if not paths then
      return { error = err }
    end

    -- Process each path
    for _, p in ipairs(paths) do
      if type(p) == 'string' then
        local resolved_path = util.resolve(p, ctx.cwd)

        -- Security: ensure resolved_path is within ctx.cwd
        if
          not vim.startswith(
            vim.fs.normalize(resolved_path),
            vim.fs.normalize(ctx.cwd)
          )
        then
          return {
            error = string.format(
              'Cannot access path outside working directory: %s',
              p
            ),
          }
        end

        table.insert(cmd, resolved_path)
        table.insert(resolved_paths, resolved_path)
      end
    end
  else
    -- Default: add all changes in current directory
    table.insert(cmd, '.')
  end

  local stdout = {}
  local stderr = {}

  local jobid = job.start(cmd, {
    on_stdout = function(_, data)
      vim.list_extend(stdout, data)
    end,
    on_stderr = function(_, data)
      vim.list_extend(stderr, data)
    end,
    on_exit = function(id, code, signal)
      if signal ~= 0 then
        ctx.callback({
          error = string.format('Git add cancelled (signal: %d)', signal),
          jobid = id,
        })
        return
      end

      local output = table.concat(stdout, '\n')
      if #stderr > 0 then
        output = output .. '\n' .. table.concat(stderr, '\n')
      end

      if code == 0 then
        local summary = 'Git add successful.\n\n'
        if action.all then
          summary = summary .. 'Added all changes to staging area.'
        elseif #resolved_paths > 0 then
          summary = summary .. 'Added files:\n'
          for _, p in ipairs(resolved_paths) do
            local rel_path = vim.fn.fnamemodify(p, ':.')
            summary = summary .. '  - ' .. rel_path .. '\n'
          end
        else
          summary = summary .. 'Added all changes in current directory.'
        end

        ctx.callback({
          content = summary,
          jobid = id,
        })
      else
        ctx.callback({
          error = string.format(
            'Failed to run git add (exit %d): %s\n%s',
            code,
            table.concat(cmd, ' '),
            output
          ),
          jobid = id,
        })
      end
    end,
  })

  if jobid > 0 then
    return { jobid = jobid }
  end
end

function M.scheme()
  return {
    type = 'function',
    ['function'] = {
      name = 'git_add',
      description = [[Stage file changes for commit.

This tool executes git add to stage changes for the next commit.

USAGE:
- @git_add                                # Add changes in current directory
- @git_add path="file.lua"                # Add single file
- @git_add path=["a.lua", "b.lua"]        # Add multiple files
- @git_add all=true                       # Add all changes (git add -A)
- @git_add path="./src"                   # Add all changes in directory

PARAMETER FORMAT:
- Single file:   path="src/main.lua"      (string)
- Multiple files: path=["a.lua", "b.lua"] (array of strings)

IMPORTANT: Do NOT wrap the array in quotes!
✅ Correct:   path=["file1.lua", "file2.lua"]
❌ Wrong:     path="["file1.lua", "file2.lua"]"

EXAMPLES:
@git_add path="src/main.lua"
@git_add path=["src/main.lua", "src/utils.lua", "README.md"]
@git_add all=true
@git_add path="./src"]],
      parameters = {
        type = 'object',
        properties = {
          path = {
            type = 'array',
            items = { type = 'string' },
            description = [[File or directory path(s) to add.
For a single file: ["src/main.lua"]
For multiple files: ["a.lua", "b.lua"]
NOTE: A single string like "src/main.lua" is also accepted.]],
          },
          all = {
            type = 'boolean',
            description = 'Add all changes (like git add -A)',
          },
        },
        required = {},
      },
    },
  }
end

function M.info(action, ctx)
  local ok, args = pcall(vim.json.decode, action)
  if ok then
    local parts = { 'git_add' }
    if args.all then
      table.insert(parts, 'all=true')
    elseif args.path then
      local paths = normalize_paths(args.path) or { tostring(args.path) }
      table.insert(
        parts,
        string.format('path=["%s"]', table.concat(paths, '", "'))
      )
    end
    return table.concat(parts, ' ')
  end
  return 'git_add'
end

return M

