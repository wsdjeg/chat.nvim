-- lua/chat/tools/get_history.lua
-- Tool for LLM to retrieve conversation history

local M = {}

local log = require('chat.log')

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

Examples:
- get_history(offset=0, limit=20) — Get the first 20 messages (oldest)
- get_history(offset=20, limit=20) — Get messages 21-40
- get_history(offset=0, limit=50) — Get first 50 messages (max)
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
        },
        required = {},
      },
    },
  }
end

--- Handle tool call
--- @param arguments table: Tool arguments { offset?, limit? }
--- @param ctx table: Context { session, cwd, user }
--- @return table: Result { content } or { error }
function M.get_history(arguments, ctx)
  local sessions = require('chat.sessions')

  if not ctx.session or not sessions.exists(ctx.session) then
    return { error = 'No active session' }
  end

  local messages = sessions.get_messages(ctx.session)
  if not messages or #messages == 0 then
    return { content = 'No messages in session history.' }
  end

  local offset = arguments.offset or 0
  local limit = math.min(arguments.limit or 20, 50)

  -- Validate offset
  if offset < 0 then
    offset = 0
  end
  if offset >= #messages then
    return {
      content = string.format(
        'Offset %d is beyond total message count (%d).',
        offset,
        #messages
      ),
    }
  end

  -- Extract messages
  local result = {}
  for i = offset + 1, math.min(offset + limit, #messages) do
    local msg = messages[i]
    table.insert(result, {
      index = i - 1, -- 0-indexed for LLM
      role = msg.role,
      content = msg.content,
      created = msg.created,
    })
  end

  -- Build response
  local response = {
    total = #messages,
    offset = offset,
    limit = limit,
    returned = #result,
    messages = result,
  }

  log.info(
    string.format(
      '[get_history] Retrieved %d messages (offset=%d, total=%d)',
      #result,
      offset,
      #messages
    )
  )

  return { content = vim.json.encode(response) }
end

--- Format tool info for display
--- @param arguments table: Tool arguments
--- @param ctx table: Context
--- @return string: Formatted info
function M.info(arguments, ctx)
  local offset = arguments.offset or 0
  local limit = arguments.limit or 20
  return string.format('get_history(offset=%d, limit=%d)', offset, limit)
end

return M
