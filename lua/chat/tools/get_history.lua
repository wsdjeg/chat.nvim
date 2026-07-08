-- lua/chat/tools/get_history.lua
-- Tool for LLM to retrieve and search conversation history

local M = {}

local log = require('chat.log')

---@class ChatToolsGetHistoryAction
---@field offset? integer Starting index (0 = oldest message, default 0)
---@field limit? integer Number of messages to retrieve (default 20, max 50)
---@field search? string Keyword to filter messages (case-insensitive)

--- Get tool schema for LLM
--- @return table: Tool schema
function M.scheme()
  return {
    type = 'function',
    ['function'] = {
      name = 'get_history',
      description = [[
Get conversation history messages from the current session.

Use this tool when you need to reference earlier messages that are not in the current context window.

Returns the requested messages with their role, content, and timestamp.

When `search` is provided, only messages containing the keyword (case-insensitive) are returned. Offset and limit apply to the filtered results.

Examples:
- get_history(offset=0, limit=20) — Get the first 20 messages (oldest)
- get_history(offset=20, limit=20) — Get messages 21-40
- get_history(offset=0, limit=50) — Get first 50 messages (max)
- get_history(search="error") — Search for messages containing "error"
- get_history(search="config", offset=0, limit=10) — Search "config", first 10 matches
]],
      parameters = {
        type = 'object',
        properties = {
          offset = {
            type = 'integer',
            description = 'Starting index (0 = oldest message, default 0)',
          },
          limit = {
            type = 'integer',
            description = 'Number of messages to retrieve (default 20, max 50)',
          },
          search = {
            type = 'string',
            description = 'Keyword to filter messages (case-insensitive). When provided, only matching messages are returned.',
          },
        },
        required = {},
      },
    },
  }
end

--- Handle tool call
---@param action ChatToolsGetHistoryAction
---@param ctx ChatToolContext
---@return table: Result { content } or { error }
function M.get_history(action, ctx)
  local sessions = require('chat.sessions')

  if not ctx.session or not sessions.exists(ctx.session) then
    return { error = 'No active session' }
  end

  local messages = sessions.get_messages(ctx.session)
  if not messages or #messages == 0 then
    return { content = 'No messages in session history.' }
  end

  local offset = action.offset or 0
  local limit = math.min(action.limit or 20, 50)
  local search = action.search

  -- Validate offset
  if offset < 0 then
    offset = 0
  end

  -- Build the working set: all messages or filtered by search keyword
  local working_set = {}
  if search and search ~= '' then
    local search_lower = string.lower(search)
    for i, msg in ipairs(messages) do
      if
        msg.content
        and type(msg.content) == 'string'
        and string.find(string.lower(msg.content), search_lower, 1, true)
      then
        table.insert(working_set, {
          index = i - 1, -- 0-indexed for LLM
          role = msg.role,
          content = msg.content,
          created = msg.created,
        })
      end
    end
  else
    for i, msg in ipairs(messages) do
      table.insert(working_set, {
        index = i - 1, -- 0-indexed for LLM
        role = msg.role,
        content = msg.content,
        created = msg.created,
      })
    end
  end

  -- Check offset against working set size
  if offset >= #working_set then
    if search and search ~= '' then
      return {
        content = string.format(
          'Offset %d is beyond matched message count (%d). Search keyword: "%s"',
          offset,
          #working_set,
          search
        ),
      }
    else
      return {
        content = string.format(
          'Offset %d is beyond total message count (%d).',
          offset,
          #working_set
        ),
      }
    end
  end

  -- Extract messages from working set with offset and limit
  local result = {}
  for i = offset + 1, math.min(offset + limit, #working_set) do
    table.insert(result, working_set[i])
  end

  -- Build response
  local response = {
    total = #messages,
    offset = offset,
    limit = limit,
    returned = #result,
    messages = result,
  }

  if search and search ~= '' then
    response.search = search
    response.total_matched = #working_set
  end

  log.info(
    string.format(
      '[get_history] Retrieved %d messages (offset=%d, total=%d%s)',
      #result,
      offset,
      #messages,
      search
          and search ~= ''
          and (', search="' .. search .. '", matched=' .. #working_set)
        or ''
    )
  )

  return { content = vim.json.encode(response) }
end

--- Format tool info for display
---@param action string
---@return string: Formatted info
function M.info(action, _)
  local ok, arguments = pcall(vim.json.decode, action)
  if not ok then
    return 'get_history'
  end

  local offset = arguments.offset or 0
  local limit = arguments.limit or 20
  local search = arguments.search
  if search and search ~= '' then
    return string.format(
      'get_history(search="%s", offset=%d, limit=%d)',
      search,
      offset,
      limit
    )
  end
  return string.format('get_history(offset=%d, limit=%d)', offset, limit)
end

return M

