-- lua/chat/tools/find_tool.lua
-- Tool discovery: search tools by name/keyword and enable them for this turn.
-- With lazy tool loading, only essential tools are sent with requests.
-- The full catalog of all other tools is embedded in this tool's description.
--
-- Responses are deliberately terse. Once a tool is enabled, its full
-- description and parameter schema appear in the tools list of the next
-- request, so echoing the schema (or the catalog already present in this
-- tool's description) back in the tool result only duplicates tokens.

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
      description = [[Search and discover tools by name or keyword, and enable them.

Most tools are NOT sent with your current request to save tokens. Only the tools listed in the catalog below (plus a few essential ones already available to you) exist. When you need a tool that is not currently callable, look it up here.

How to use:
1. Find the tool you need in the catalog below.
2. Call find_tool with the tool name, e.g. query="git_log" (query="git log" also works).
3. The result is a short confirmation like `Enabled tool "git_log".` - the tool then becomes callable in your next response, where its full description and parameter schema appear in the tools list. Activation lasts until you finish the turn with a plain-text reply; later turns need a new find_tool call.
4. If unsure about the name, query a keyword (e.g. query="git") and you get the matching tool names.

Since the catalog below is already visible to you, find_tool never repeats it: unknown queries just report the names that matched.

Catalog of all available tools:
]] .. catalog .. [[

Calling find_tool with query="list" returns just a reminder that this catalog is above.]],
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

--- Build the response for a matched tool and activate it for the session.
--- Terse on purpose: the schema reaches the model with the next request's
--- tools list, so returning it here would waste tokens.
--- Falls back to the full schema when there is no session to activate in
--- (the tool would otherwise never become callable).
---@param session_id string|nil
---@param scheme table Full tool scheme
---@param query string Original query for reference
---@return table
local function enabled_response(session_id, scheme, query)
  local tools = require('chat.tools')
  local fn = scheme['function']
  local name = fn.name

  if session_id and type(tools.activate_tool) == 'function' then
    tools.activate_tool(session_id, name)
    return {
      content = string.format('Enabled tool "%s".', name),
    }
  end

  return {
    content = vim.json.encode({
      query = query,
      found = true,
      tool = {
        name = name,
        description = fn.description,
        parameters = fn.parameters,
      },
      note = 'No session to enable tools in, so the full schema is returned instead.',
    }),
  }
end

--- Build the catalog response. The catalog already lives in the find_tool
--- description, so there is nothing to echo back.
---@return table
local function catalog_response()
  return {
    content = 'The catalog of available tools is already in the find_tool description above. Call find_tool with an exact tool name to enable it.',
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
    return catalog_response()
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
      return enabled_response(ctx and ctx.session, scheme_by_name[t.name], query)
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

  -- 3. unique candidate: enable it directly (saves a round trip)
  if #candidates == 1 then
    local name = candidates[1].name
    if scheme_by_name[name] then
      return enabled_response(ctx and ctx.session, scheme_by_name[name], query)
    end
  end

  -- 4. multiple candidates: names only, the introductions are in the catalog
  if #candidates > 1 then
    local names = vim.tbl_map(function(t)
      return t.name
    end, candidates)
    return {
      content = string.format(
        '"%s" matched %d tools: %s. Call find_tool with one exact name to enable it.',
        query, #names, table.concat(names, ', ')),
    }
  end

  -- 5. no match: the catalog above is the reference, no need to repeat it
  return {
    content = string.format(
      'No tool matched "%s". The catalog of available tools is in the find_tool description above; retry with an exact name from it.',
      query),
  }
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

