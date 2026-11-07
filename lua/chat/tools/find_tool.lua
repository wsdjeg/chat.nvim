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
---@field query string|string[] Tool name(s) or keyword(s)

--- Normalize a query: trim spaces, lowercase.
---@param q string
---@return string
local function normalize(q)
  q = tostring(q or ''):lower()
  q = q:gsub('^%s+', ''):gsub('%s+$', '')
  return q
end

--- True when every character of `needle` occurs in `haystack` in order.
--- Used as a fuzzy fallback for abbreviations such as "gcm" -> git_commit.
---@param needle string Normalized query
---@param haystack string Lowercase tool name
---@return boolean
local function is_subsequence(needle, haystack)
  local j = 1
  for i = 1, #needle do
    local c = needle:sub(i, i)
    local found = haystack:find(c, j, true)
    if not found then
      return false
    end
    j = found + 1
  end
  return true
end

--- Queries that mean "show me the catalog" instead of a tool name.
---@param q string Normalized query
---@return boolean
local function is_catalog_query(q)
  local q_name = q:gsub('%s+', '_')
  return q == ''
    or q == 'list'
    or q == 'all'
    or q == 'catalog'
    or q == 'tools'
    or q_name == 'find_tool'
end

--- Match one normalized query against the catalog.
--- Resolution order: exact name, substring (name or introduction), then a
--- subsequence fallback on the name only (needs >= 3 chars to avoid noise).
---@param q string Normalized query
---@param intros table[] Array of { name = string, introduction = string }
---@return table result { kind = 'exact'|'unique'|'many'|'none', names = string[] }
local function match_query(q, intros)
  local q_name = q:gsub('%s+', '_')

  -- 1. exact name match (case-insensitive, spaces normalized to underscores)
  for _, t in ipairs(intros) do
    local n = t.name:lower()
    if n == q or n == q_name then
      return { kind = 'exact', names = { t.name } }
    end
  end

  -- 2. partial matches: name or introduction contains the query
  local partial = {}
  for _, t in ipairs(intros) do
    local n = t.name:lower()
    local intro = (t.introduction or ''):lower()
    if
      n:find(q, 1, true)
      or (q_name ~= q and n:find(q_name, 1, true))
      or intro:find(q, 1, true)
    then
      table.insert(partial, t.name)
    end
  end

  -- 3. fuzzy fallback: subsequence of the tool name ("gcm" -> git_commit)
  local fuzzy = {}
  if #partial == 0 and #q >= 3 then
    for _, t in ipairs(intros) do
      if is_subsequence(q, t.name:lower()) then
        table.insert(fuzzy, t.name)
      end
    end
  end

  local candidates = #partial > 0 and partial or fuzzy
  if #candidates == 1 then
    return { kind = 'unique', names = candidates }
  end
  if #candidates > 1 then
    return { kind = 'many', names = candidates }
  end
  return { kind = 'none', names = {} }
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

Most tools are NOT sent with your current request to save tokens. Only the tools listed in the catalog below (plus a few essential tools already available to you) exist. When you need a tool that is not currently callable, look it up here.

How to use:
1. Find the tool you need in the catalog below.
2. Call find_tool with the tool name, e.g. query="git_log" (query="git log" also works).
3. To enable several tools at once, pass an array: query=["git_add", "git_commit"].
4. The result is a short confirmation like `Enabled tool "git_log".` - the tool then becomes callable in your next response, where its full description and parameter schema appear in the tools list. Activation lasts until you finish the turn with a plain-text reply; later turns need a new find_tool call.
5. If unsure about the name, query a keyword (e.g. query="git") and you get the matching tool names. Fuzzy matching also works: an abbreviation like "gcm" resolves to git_commit when it stays unambiguous.

Since the catalog below is already visible to you, find_tool never repeats it: unknown queries just report the names that matched.

Catalog of all available tools:
]] .. catalog .. [[

Calling find_tool with query="list" returns just a reminder that this catalog is above.]],
      parameters = {
        type = 'object',
        properties = {
          query = {
            anyOf = {
              { type = 'string' },
              {
                type = 'array',
                items = { type = 'string' },
              },
            },
            description = 'Tool name, keyword, or an array of them to search for (e.g. "git_log", "git log", "weather", "list", ["git_add", "git_commit"])',
          },
        },
        required = { 'query' },
      },
    },
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

--- Activate a tool for the session and report a terse confirmation.
--- Returns the plain schema instead when there is no session to activate in
--- (the tool would otherwise never become callable).
---@param session_id string|nil
---@param scheme table Full tool scheme
---@return string|nil message Confirmation text, nil when no session
---@return table|nil schema Full schema, only when there is no session
local function enable(session_id, scheme)
  local tools = require('chat.tools')
  local fn = scheme['function']
  local name = fn.name

  if session_id and type(tools.activate_tool) == 'function' then
    tools.activate_tool(session_id, name)
    return string.format('Enabled tool "%s".', name), nil
  end

  return nil, {
    name = name,
    description = fn.description,
    parameters = fn.parameters,
  }
end

--- Handle tool call
---@param action ChatToolsFindToolAction
---@param ctx ChatToolContext
---@return table Result { content } or { error }
function M.find_tool(action, ctx)
  action = action or {}

  -- query accepts a single string or an array of strings
  local queries = {}
  local raw = action.query
  if type(raw) == 'table' then
    for _, v in ipairs(raw) do
      if type(v) == 'string' then
        table.insert(queries, v)
      elseif type(v) == 'number' then
        table.insert(queries, tostring(v))
      end
    end
  elseif type(raw) == 'string' then
    table.insert(queries, raw)
  elseif raw ~= nil then
    table.insert(queries, tostring(raw))
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

  local intros = tools.available_introductions()
  local all = tools.available_tools()
  local scheme_by_name = {}
  for _, scheme in ipairs(all) do
    scheme_by_name[scheme['function'].name] = scheme
  end

  local session_id = ctx and ctx.session
  local lines = {}
  local schemas = {}
  local enabled = {}
  local catalog_hint = false

  for _, query in ipairs(queries) do
    local q = normalize(query)

    if is_catalog_query(q) then
      catalog_hint = true
      goto continue
    end

    local res = match_query(q, intros)

    if res.kind == 'exact' or res.kind == 'unique' then
      local name = res.names[1]
      local scheme = scheme_by_name[name]
      if scheme and not enabled[name] then
        enabled[name] = true
        local msg, schema = enable(session_id, scheme)
        if msg then
          table.insert(lines, msg)
        elseif schema then
          table.insert(schemas, schema)
        end
      end
    elseif res.kind == 'many' then
      table.insert(
        lines,
        string.format(
          '"%s" matched %d tools: %s. Call find_tool with one exact name to enable it.',
          query,
          #res.names,
          table.concat(res.names, ', ')
        )
      )
    else
      table.insert(
        lines,
        string.format(
          'No tool matched "%s". The catalog of available tools is in the find_tool description above; retry with an exact name from it.',
          query
        )
      )
    end

    ::continue::
  end

  -- No session to activate in: return the full schema(s) instead, otherwise
  -- the tools would never become callable.
  if #schemas > 0 then
    local payload = { found = true }
    if #queries == 1 and #schemas == 1 then
      payload.query = queries[1]
      payload.tool = schemas[1]
    else
      payload.queries = queries
      payload.tools = schemas
    end
    if #lines > 0 then
      payload.messages = lines
    end
    payload.note = 'No session to enable tools in, so the full schema is returned instead.'
    return { content = vim.json.encode(payload) }
  end

  if #lines == 0 then
    return catalog_response()
  end

  if catalog_hint then
    table.insert(
      lines,
      'The catalog of available tools is already in the find_tool description above.'
    )
  end

  return { content = table.concat(lines, '\n') }
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

  local query = arguments and arguments.query
  if type(query) == 'table' then
    local parts = {}
    for _, v in ipairs(query) do
      table.insert(parts, tostring(v))
    end
    query = table.concat(parts, ', ')
  elseif query == nil then
    query = ''
  else
    query = tostring(query)
  end

  return string.format('find_tool(query="%s")', query)
end

return M

