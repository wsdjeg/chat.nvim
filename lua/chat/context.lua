-- lua/chat/context.lua
-- Context Window Management for chat.nvim

local M = {}

local log = require('chat.log')

-- Default configuration
M.DEFAULT_CONFIG = {
  trigger_threshold = 50, -- Trigger truncation at this message count
  keep_recent = 10, -- Don't include recent N messages in truncation search
}

--- Truncate conversation messages to fit context window
--- Ensures tool_call/tool_result pairs are not broken by truncation
--- @param messages table Array of messages (system, user, assistant, tool)
--- @param config? table Configuration override
--- @return table, boolean Truncated messages, whether truncation occurred
function M.truncate_messages(messages, config)
  config = vim.tbl_extend('force', M.DEFAULT_CONFIG, config or {})

  if not messages or #messages < config.trigger_threshold then
    return messages, false
  end

  -- Separate system messages from conversation messages
  local system_messages = {}
  local other_messages = {}

  for _, msg in ipairs(messages) do
    if msg.role == 'system' then
      table.insert(system_messages, msg)
    else
      table.insert(other_messages, msg)
    end
  end

  -- Calculate cutoff position
  local cutoff_idx = #other_messages - config.keep_recent

  if cutoff_idx < 1 then
    return messages, false
  end

  -- Find nearest user message at or before cutoff.
  -- Starting from a user message ensures we don't begin mid-conversation
  -- (e.g., at an orphaned tool result or an assistant continuation).
  local start_idx = nil
  for i = cutoff_idx, 1, -1 do
    if other_messages[i].role == 'user' then
      start_idx = i
      break
    end
  end

  -- If no user message found before cutoff, don't truncate (safety fallback)
  if not start_idx then
    return messages, false
  end

  -- Collect kept messages (from start_idx to end)
  local kept = {}
  for i = start_idx, #other_messages do
    table.insert(kept, other_messages[i])
  end

  -- ── Validate tool_call/tool_result pairing ──────────────
  --
  -- After truncation, two kinds of orphans can appear:
  --   1. tool result whose assistant tool_call was truncated away
  --   2. assistant with tool_calls whose results were truncated away
  --
  -- Both cause API errors (OpenAI requires matching pairs, Anthropic
  -- requires tool_result to follow tool_use in the same turn).

  -- Build set of tool_call_ids declared by assistant messages
  local declared_tool_call_ids = {}
  for _, msg in ipairs(kept) do
    if msg.role == 'assistant' and msg.tool_calls then
      for _, tc in ipairs(msg.tool_calls) do
        if tc.id then
          declared_tool_call_ids[tc.id] = true
        end
      end
    end
  end

  -- Filter: remove orphaned tool results (their assistant tool_call was truncated)
  local cleaned = {}
  local removed_count = 0

  for _, msg in ipairs(kept) do
    if msg.role == 'tool' and msg.tool_call_id then
      -- tool result without matching assistant tool_call
      if not declared_tool_call_ids[msg.tool_call_id] then
        removed_count = removed_count + 1
        goto continue
      end
    end
    table.insert(cleaned, msg)
    ::continue::
  end

  -- Build set of tool_call_ids that have matching tool results
  local answered_tool_call_ids = {}
  for _, msg in ipairs(cleaned) do
    if msg.role == 'tool' and msg.tool_call_id then
      answered_tool_call_ids[msg.tool_call_id] = true
    end
  end

  -- Second pass: remove orphaned tool_calls from assistant messages
  -- (assistant has tool_calls but corresponding results were truncated away)
  local cleaned2 = {}
  for _, msg in ipairs(cleaned) do
    if msg.role == 'assistant' and msg.tool_calls then
      local valid_tool_calls = {}
      for _, tc in ipairs(msg.tool_calls) do
        if tc.id and answered_tool_call_ids[tc.id] then
          table.insert(valid_tool_calls, tc)
        else
          removed_count = removed_count + 1
          log.warn(
            '[Context] Removing orphaned tool_call: ' .. tostring(tc.id)
          )
        end
      end
      if #valid_tool_calls == 0 then
        -- No valid tool_calls remain; keep message only if it has text content
        if
          msg.content
          and type(msg.content) == 'string'
          and #msg.content > 0
        then
          msg.tool_calls = nil
          table.insert(cleaned2, msg)
        end
        -- else: remove message entirely (only had tool_calls, no text)
      else
        msg.tool_calls = valid_tool_calls
        table.insert(cleaned2, msg)
      end
    else
      table.insert(cleaned2, msg)
    end
  end
  cleaned = cleaned2

  -- Build final result: system messages + context notice + cleaned messages
  local result = {}
  vim.list_extend(result, system_messages)

  table.insert(result, {
    role = 'system',
    content = M._generate_context_notice(
      #messages,
      #cleaned,
      start_idx,
      #other_messages
    ),
  })

  vim.list_extend(result, cleaned)

  log.info(
    string.format(
      '[Context] Truncated: %d -> %d messages (kept %d, removed %d orphaned)',
      #messages,
      #result,
      #cleaned,
      removed_count
    )
  )

  return result, true
end

--- Generate context window notice message
--- @param total integer: Total messages before truncation
--- @param kept integer: Messages kept after truncation
--- @param start_idx integer: Starting index of kept messages
--- @param end_idx integer: Ending index
--- @return string: Notice content
function M._generate_context_notice(total, kept, start_idx, end_idx)
  return string.format(
    [[
[Context Window Notice]

Due to context length limits, only the most recent messages are displayed.
Earlier messages (%d total, showing %d-%d) have been truncated.

To access earlier conversation history, use the `get_history` tool:
- get_history(offset=0, limit=20) — Get first 20 messages
- get_history(offset=20, limit=20) — Get next 20 messages

Current session has %d messages in total history. Current window shows %d messages.
]],
    total,
    start_idx,
    end_idx,
    total,
    kept
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

