-- Session messages: append, get, request messages
local M = {}

local storage = require('chat.sessions.storage')

function M.append_message(session_id, message)
  if
    message.role == 'assistant'
    and message.content
    and message.content ~= ''
  then
    require('chat.integrations').on_response(session_id, message.content)
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

function M.get_request_messages(session_id)
  local message = {}
  if storage.sessions[session_id].prompt and #storage.sessions[session_id].prompt > 0 then
    table.insert(message, {
      role = 'system',
      content = storage.sessions[session_id].prompt,
    })
  end
  for _, m in ipairs(storage.sessions[session_id].messages) do
    if vim.tbl_contains({ 'user', 'assistant', 'tool' }, m.role) then
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

return M

