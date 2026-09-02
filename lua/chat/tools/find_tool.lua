-- lua/chat/tools/find_tool.lua
-- Tool discovery: search tools by name/keyword and get full parameter schemas.
-- With lazy tool loading, only essential tools are sent with requests.
-- The full catalog of all other tools is embedded in this tool's description.

local M = {}

-- Recursion guard: chat.tools excludes this module when collecting
-- schemes/introductions, because our description embeds the catalog.
M.is_find_tool = true

---@class ChatToolsFindToolAction
---@field query string Tool name or keyword (e.g. "git_log", "git log", "weather")

--- Normalize a query: trim spaces, lowercase.
---@param q string
---@return string
local function normalize(q)
  q = tostring(q or ''):lower()
  q = q:gsub('^%s+', ''):gsub('%s+$', '')
  return q
end

--- Get tool scheme for LLM. The description embeds a live catalog of all
--- available tools (name + one-line introduction) so the model knows what
--- exists without receiving every full schema.
---@return table Tool schema
function M.scheme()
  local tools_mod = require('chat.tools')
  local catalog
  if type(tools_mod.catalog_lines) == 'function' then
    catalog = table.concat(tools_mod.catalog_lines(), '\n')
  else
    -- Stale chat.tools module (mixed old/new code after a live update).
    -- Degrade gracefully instead of raising.
    catalog = '(catalog temporarily unavailable: chat.tools module is outdated, restart Neovim to rebuild the tool catalog)'
  end

  return {
    type = 'function',
    ['function'] = {
      name = 'find_tool',
      description = [[Search and discover tools by name or keyword, and get the full parameter schema.

Most tools are NOT sent with your current request to save tokens. Only the tools listed in the catalog below (plus a few essential ones already available to you) exist. When you need a tool that is not currently callable, look it up here.

How to use:
1. Find the tool you need in the catalog below.
2. Call find_tool with the tool name, e.g. query="git_log" (query="git log" also works).
3. You receive its full parameter schema, and the tool becomes callable in your next response.
4. If unsure about the name, query a keyword (e.g. query="git") and you will get matching candidates.

Catalog of all available tools:
]] .. catalog .. [[

Calling find_tool with query="list" returns this catalog with introductions.]],
      parameters = {
        type = 'object',
        properties = {
          query = {
            type = 'string',
            description = 'Tool name or keyword to search for (e.g. "git_log", "git log", "weather", "list")',
          },
        },
        required = { 'query' },
      },
    },
  }
end

--- Build the full-schema response and activate the tool for the session.
---@param session_id string|nil
---@param scheme table Full tool scheme
---@param query string Original query for reference
---@return table
local function schema_response(session_id, scheme, query)
  local tools = require('chat.tools')
  if session_id and type(tools.activate_tool) == 'function' then
    tools.activate_tool(session_id, scheme['function'].name)
  end
  return {
    content = vim.json.encode({
      query = query,
      found = true,
      tool = {
        name = scheme['function'].name,
        description = scheme['function'].description,
        parameters = scheme['function'].parameters,
      },
      note = 'This tool is now available for tool calls in your next response. Call it with the parameters described above.',
    }),
  }
end

--- Build the catalog response (names + introductions only).
---@param query string Original query for reference
---@return table
local function catalog_response(query)
  local tools = require('chat.tools')
  return {
    content = vim.json.encode({
      query = query,
      found = false,
      action = 'catalog',
      tools = tools.available_introductions(),
      hint = 'Call find_tool again with an exact tool name (e.g. query="git_log") to get its full parameter schema and make it callable.',
    }),
  }
end

--- Handle tool call
---@param action ChatToolsFindToolAction
---@param ctx ChatToolContext
---@return table Result { content } or { error }
function M.find_tool(action, ctx)
  action = action or {}
  local query = action.query or action.name or ''
  if type(query) ~= 'string' then
    query = tostring(query)
  end

  local tools = require('chat.tools')
  if
    type(tools.available_introductions) ~= 'function'
    or type(tools.available_tools) ~= 'function'
  then
    return {
      error = 'chat.tools module is outdated (mixed plugin versions loaded). Restart Neovim to enable tool discovery.',
    }
  end

  local q = normalize(query)
  local q_name = q:gsub('%s+', '_') -- "git log" -> "git_log"

  -- catalog request
  if
    q == ''
    or q == 'list'
    or q == 'all'
    or q == 'catalog'
    or q == 'tools'
    or q_name == 'find_tool'
  then
    return catalog_response(query)
  end

  local intros = tools.available_introductions()
  local all = tools.available_tools()
  local scheme_by_name = {}
  for _, scheme in ipairs(all) do
    scheme_by_name[scheme['function'].name] = scheme
  end

  -- 1. exact name match (case-insensitive, spaces normalized to underscores)
  for _, t in ipairs(intros) do
    local n = t.name:lower()
    if n == q or n == q_name then
      return schema_response(ctx and ctx.session, scheme_by_name[t.name], query)
    end
  end

  -- 2. partial matches: name or introduction contains the query
  local candidates = {}
  for _, t in ipairs(intros) do
    local n = t.name:lower()
    local intro = (t.introduction or ''):lower()
    if
      n:find(q, 1, true)
      or (q_name ~= q and n:find(q_name, 1, true))
      or intro:find(q, 1, true)
    then
      table.insert(candidates, t)
    end
  end

  -- 3. unique candidate: return its full schema directly (saves a round trip)
  if #candidates == 1 then
    local name = candidates[1].name
    if scheme_by_name[name] then
      return schema_response(ctx and ctx.session, scheme_by_name[name], query)
    end
  end

  if #candidates > 1 then
    return {
      content = vim.json.encode({
        query = query,
        found = false,
        candidates = vim.tbl_map(function(t)
          return { name = t.name, introduction = t.introduction }
        end, candidates),
        hint = 'Multiple tools matched. Call find_tool again with an exact tool name from the candidates above to get its full parameter schema.',
      }),
    }
  end

  -- 4. no match: return the full catalog to help the model refine
  local res = catalog_response(query)
  local decoded = vim.json.decode(res.content)
  decoded.note = 'No tool matched the query. See the full catalog below and try again with an exact tool name.'
  res.content = vim.json.encode(decoded)
  return res
end

--- Format tool info for display
---@param action string|table
---@return string Formatted info
function M.info(action, _)
  local arguments = action
  if type(action) == 'string' then
    local ok, decoded = pcall(vim.json.decode, action)
    if ok then
      arguments = decoded
    else
      return 'find_tool'
    end
  end

  local query = (arguments and arguments.query) or ''
  return string.format('find_tool(query="%s")', query)
end

return M

