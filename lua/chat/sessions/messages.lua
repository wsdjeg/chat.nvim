-- Session messages: append, get, request messages
local M = {}

local storage = require('chat.sessions.storage')
local util = require('chat.util')

-- Messages already sanitized in this process, keyed weakly by table
-- reference.
--
-- Tool outputs (git commands, file reads) may contain bytes that are not
-- valid UTF-8 (e.g. GBK-encoded filenames), and vim.json.encode passes them
-- through, so strict providers reject the request body with
-- InvalidParameter.NonUTF8Body. Every message entering the history is
-- sanitized once; the registry avoids re-scanning all messages on every
-- request while still repairing caches written by older versions.
local sanitized = setmetatable({}, { __mode = 'k' })

--- Sanitize a string to valid UTF-8, replacing invalid byte sequences with
--- U+FFFD. Non-string values pass through unchanged.
---@param value any
---@return any
local function sanitize_value(value)
  if type(value) == 'string' then
    return util.sanitize_utf8(value)
  end
  return value
end

--- Sanitize a message's string fields in place: content, reasoning_content
--- and tool_calls arguments. Runs at most once per message table.
---@param message table
local function ensure_sanitized(message)
  if sanitized[message] then
    return
  end
  message.content = sanitize_value(message.content)
  message.reasoning_content = sanitize_value(message.reasoning_content)
  if type(message.tool_calls) == 'table' then
    for _, tool_call in ipairs(message.tool_calls) do
      if
        type(tool_call) == 'table'
        and type(tool_call['function']) == 'table'
        and type(tool_call['function'].arguments) == 'string'
      then
        tool_call['function'].arguments =
          sanitize_value(tool_call['function'].arguments)
      end
    end
  end
  sanitized[message] = true
end

--- Appends a message to a session's message history
--- Updates usage statistics if provided and notifies integrations for assistant responses
--- @param session_id string The session identifier
--- @param message ChatMessage The message object to append
function M.append_message(session_id, message)
  -- Sanitize to valid UTF-8 before storing, so invalid bytes from tool
  -- output never enter the request history or the session cache.
  ensure_sanitized(message)

  if
    message.role == 'assistant'
    and message.content
    and message.content ~= ''
  then
    require('chat.integrations').on_response(session_id, message.content)
  end

  -- Record the time when user sends a message
  if message.role == 'user' then
    storage.sessions[session_id].last_user_message_time = os.time()
    -- A new user turn breaks any auto-continuation chain from a previous
    -- truncated response, so the continuation budget resets.
    require('chat.sessions.continue').reset(session_id)
  end

  table.insert(storage.sessions[session_id].messages, message)

  if message.usage then
    local s = storage.sessions[session_id]
    if not s.usage then
      local total = 0
      local prompt = 0
      local completion = 0
      for _, msg in ipairs(s.messages) do
        if msg.usage then
          total = total + (msg.usage.total_tokens or 0)
          prompt = prompt + (msg.usage.prompt_tokens or 0)
          completion = completion + (msg.usage.completion_tokens or 0)
        end
      end
      s.usage = {
        total_tokens = total,
        prompt_tokens = prompt,
        completion_tokens = completion,
      }
    else
      s.usage = {
        total_tokens = s.usage.total_tokens
          + (message.usage.total_tokens or 0),
        prompt_tokens = s.usage.prompt_tokens
          + (message.usage.prompt_tokens or 0),
        completion_tokens = s.usage.completion_tokens
          + (message.usage.completion_tokens or 0),
      }
    end
  end
end

--- Retrieves all messages from a session's history
--- Returns a copy of the messages array with all message fields
--- @param session_id string The session identifier
--- @return table Array of message objects with all fields preserved
function M.get_messages(session_id)
  local message = {}
  for _, m in ipairs(storage.sessions[session_id].messages) do
    table.insert(message, {
      role = m.role,
      content = m.content,
      reasoning_content = m.reasoning_content,
      tool_calls = m.tool_calls,
      tool_call_id = m.tool_call_id,
      created = m.created,
      on_complete = m.on_complete,
      usage = m.usage,
      error = m.error,
      tool_call_state = m.tool_call_state,
    })
  end
  return message
end

--- Deletes a message at the given index from a session's history
--- Forces usage statistics recalculation on next access
--- @param session_id string The session identifier
--- @param index integer The 1-based index of the message to delete
--- @return boolean True if deleted successfully, false if index is out of range
function M.delete_message(session_id, index)
  local messages = storage.sessions[session_id].messages
  if index < 1 or index > #messages then
    return false
  end
  table.remove(messages, index)
  -- Force usage recalculation on next access
  storage.sessions[session_id].usage = nil
  return true
end

--- Gets messages formatted for LLM API request
--- Prepends system prompt and user profile if configured, applies context truncation
--- All string content is sanitized to valid UTF-8, which also repairs history
--- polluted by non-UTF-8 tool output in legacy caches
--- @param session_id string The session identifier
--- @return table Array of messages formatted for API request (system, user, assistant, tool roles only)
function M.get_request_messages(session_id)
  local message = {}
  local session = storage.sessions[session_id]

  if session.prompt and #session.prompt > 0 then
    -- A prompt loaded from a non-UTF-8 encoded file would break every
    -- request in this session; sanitize in place so the next cache write
    -- persists valid UTF-8.
    session.prompt = sanitize_value(session.prompt)
    table.insert(message, {
      role = 'system',
      content = session.prompt,
    })
  end

  -- Inject user profile as system context
  local profile_msg = require('chat.user').get_profile_system_message()
  if profile_msg then
    table.insert(message, {
      role = 'system',
      content = sanitize_value(profile_msg),
    })
  end

  for _, m in ipairs(session.messages) do
    if vim.tbl_contains({ 'user', 'assistant', 'tool' }, m.role) then
      -- Sanitize in place: repairs history polluted by non-UTF-8 tool
      -- output (e.g. git output with GBK-encoded filenames), healing
      -- legacy caches on the first request.
      ensure_sanitized(m)
      table.insert(message, {
        role = m.role,
        content = m.content,
        reasoning_content = m.reasoning_content,
        tool_calls = m.tool_calls,
        tool_call_id = m.tool_call_id,
      })
    end
  end

  -- Apply context truncation
  local cfg = require('chat.config').config.context or {}
  if cfg.enable ~= false then
    local context = require('chat.context')
    message = context.truncate_messages(message, cfg)
  end

  return message
end

--- Extract a context snippet around the first match position for hit preview.
--- @param text string
--- @param pos integer 1-based position of the match
--- @return string Snippet with leading/trailing ellipsis when truncated
local function build_snippet(text, pos)
  local SNIPPET_LEN = 160
  local pre = pos > 1 and text:sub(math.max(1, pos - SNIPPET_LEN), pos - 1) or ''
  local tail = text:sub(pos, pos + SNIPPET_LEN - 1)
  local prefix = (pos - SNIPPET_LEN > 1) and '…' or ''
  local suffix = (pos + SNIPPET_LEN - 1 < #text) and '…' or ''
  return prefix .. pre .. tail .. suffix
end

--- Search a session's messages for a text query.
---
--- Matches are case-insensitive literal substring matches against `content`
--- and `reasoning_content`. Returns the total message count plus the list of
--- matching messages with their 1-based index and a context snippet.
--- @param session_id string The session identifier
--- @param query string Non-empty search text
--- @return table|nil Result table { total, count, matches } or nil when the
---   session does not exist
function M.search_messages(session_id, query)
  local session = storage.sessions[session_id]
  if not session then
    return nil
  end

  -- Case-insensitive lookup via lowercased copy is byte-length stable for
  -- ASCII and CJK content (the common cases in chat history).
  local q = query:lower()
  local result = { total = #session.messages, count = 0, matches = {} }

  for i, m in ipairs(session.messages) do
    local hit_field, hit_text, hit_pos = nil, nil, nil

    for _, field in ipairs({ 'content', 'reasoning_content' }) do
      local v = m[field]
      if type(v) == 'string' and v ~= '' then
        local pos = v:lower():find(q, 1, true)
        if pos then
          hit_field, hit_text, hit_pos = field, v, pos
          break
        end
      end
    end

    if hit_field then
      result.count = result.count + 1
      table.insert(result.matches, {
        index = i,
        role = m.role,
        field = hit_field,
        content = build_snippet(hit_text, hit_pos),
        created = m.created,
      })
    end
  end

  return result
end

return M
