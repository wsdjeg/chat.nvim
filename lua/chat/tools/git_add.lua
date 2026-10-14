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

---Try to parse a string as JSON array, return parsed table or nil
---@param s string
---@return string[]|nil
local function try_parse_json_array(s)
  if type(s) == 'string' and vim.startswith(s, '[') then
    local ok, parsed = pcall(vim.json.decode, s)
    if ok and type(parsed) == 'table' then
      return parsed
    end
  end
  return nil
end

---Normalize path argument: handle string, stringified array, or table
---LLM may return path in various formats:
---  1. "file.lua"                         (plain string)
---  2. '["a.lua", "b.lua"]'               (stringified JSON array)
---  3. {"a.lua", "b.lua"}                  (proper array)
---  4. {'["a.lua", "b.lua"]'}              (array wrapping a stringified JSON array)
---@param paths any
---@return string[]|nil result, string|nil error
local function normalize_paths(paths)
  if type(paths) == 'string' then
    -- Case 2: LLM passes array as string (e.g. '["a.lua", "b.lua"]')
    local parsed = try_parse_json_array(paths)
    if parsed then
      return parsed
    end
    -- Case 1: plain string
    return { paths }
  elseif type(paths) == 'table' then
    -- Case 4: LLM wraps stringified JSON array in an array
    -- e.g. { '["a.lua", "b.lua"]' } instead of { "a.lua", "b.lua" }
    if #paths == 1 then
      local parsed = try_parse_json_array(paths[1])
      if parsed then
        return parsed
      end
    end
    -- Case 3: proper array
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

  -- path and all together are ambiguous: the scheme promises a rejection
  if action.all and action.path then
    return {
      error = 'Ambiguous parameters: provide either path or all, not both.',
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

Executes git add to stage changes for the next commit.

Parameters (JSON):
- path: a file or directory path, or an array of paths.
  e.g. {"path": "src/main.lua"} or {"path": ["a.lua", "b.lua"]}
- all: stage all changes, equivalent to git add -A.

Provide either path or all, not both. If neither is given, all changes
under the current directory are staged (git add .).

Notes:
- Requires git to be installed and in PATH.]],
      parameters = {
        type = 'object',
        properties = {
          path = {
            anyOf = {
              { type = 'string' },
              {
                type = 'array',
                items = { type = 'string' },
                minItems = 1,
              },
            },
            description = 'A file or directory path, or an array of paths.',
          },
          all = {
            type = 'boolean',
            description = 'Stage all changes, equivalent to git add -A.',
          },
        },
        additionalProperties = false,
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

