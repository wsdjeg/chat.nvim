-- lua/chat/context.lua
-- Context Window Management for chat.nvim

local M = {}

local log = require('chat.log')

-- Default configuration
M.DEFAULT_CONFIG = {
  trigger_threshold = 50,  -- Trigger truncation at this message count
  keep_recent = 10,        -- Don't include recent N messages in truncation search
}

function M.truncate_messages(messages, config)
  config = vim.tbl_extend('force', M.DEFAULT_CONFIG, config or {})
  
  if not messages or #messages < config.trigger_threshold then
    return messages, false
  end
  
  -- Separate system messages
  local system_messages = {}
  local other_messages = {}
  
  for _, msg in ipairs(messages) do
    if msg.role == 'system' then
      table.insert(system_messages, msg)
    else
      table.insert(other_messages, msg)
    end
  end
  
  -- Calculate position of the (keep_recent)-th message from the end
  -- Example: 50 messages, keep_recent=10, cutoff = 50 - 10 = 40
  local cutoff_idx = #other_messages - config.keep_recent
  
  -- If cutoff position is already user, start from here
  -- Otherwise, find the nearest user before cutoff
  local start_idx = cutoff_idx
  
  if other_messages[cutoff_idx].role ~= 'user' then
    -- Find nearest user going backward
    for i = cutoff_idx - 1, 1, -1 do
      if other_messages[i].role == 'user' then
        start_idx = i
        break
      end
    end
  end
  
  -- Build result: system messages + messages from start_idx
  local result = {}
  vim.list_extend(result, system_messages)
  
  -- Add context notice (after system messages)
  table.insert(result, {
    role = 'system',
    content = M._generate_context_notice(#messages, #other_messages - start_idx + 1,
      start_idx, #other_messages),
  })
  
  -- Keep only messages from start_idx
  for i = start_idx, #other_messages do
    table.insert(result, other_messages[i])
  end
  
  log.info(string.format('[Context] Truncated: %d -> %d messages (kept %d recent)',
    #messages, #result, #other_messages - start_idx + 1))
  
  return result, true
end

--- Generate context window notice message
--- @param total integer: Total messages before truncation
--- @param kept integer: Messages kept after truncation
--- @param start_idx integer: Starting index of kept messages
--- @param end_idx integer: Ending index
--- @return string: Notice content
function M._generate_context_notice(total, kept, start_idx, end_idx)
  return string.format([[
[Context Window Notice]

Due to context length limits, only the most recent messages are displayed.
Earlier messages (%d total, showing %d-%d) have been truncated.

To access earlier conversation history, use the `get_history` tool:
- get_history(offset=0, limit=20) — Get first 20 messages
- get_history(offset=20, limit=20) — Get next 20 messages

Current session has %d messages in total history. Current window shows %d messages.
]],
    total, start_idx, end_idx,
    total, kept
  )
end

--- Get context statistics for a session
--- @param messages table: Array of ChatMessage
--- @return table: Statistics
function M.get_stats(messages)
  if not messages then
    return { count = 0 }
  end
  
  local stats = {
    count = #messages,
    user_count = 0,
    assistant_count = 0,
    tool_count = 0,
    system_count = 0,
  }
  
  for _, msg in ipairs(messages) do
    if msg.role == 'user' then
      stats.user_count = stats.user_count + 1
    elseif msg.role == 'assistant' then
      stats.assistant_count = stats.assistant_count + 1
    elseif msg.role == 'tool' then
      stats.tool_count = stats.tool_count + 1
    elseif msg.role == 'system' then
      stats.system_count = stats.system_count + 1
    end
  end
  
  return stats
end

return M
