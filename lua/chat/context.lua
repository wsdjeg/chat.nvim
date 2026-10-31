-- lua/chat/context.lua
-- Context Window Management for chat.nvim

local M = {}

local log = require('chat.log')

-- Default configuration
M.DEFAULT_CONFIG = {
  trigger_threshold = 50, -- Trigger truncation at this message count
  keep_recent = 10, -- Don't include recent N messages in truncation search
  slide_step = 0, -- Advance the cutoff only every N messages (0/1 = every message)
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

  -- Calculate cutoff position. With slide_step > 1 the cutoff is
  -- floor-batched: it only advances once every slide_step messages, so the
  -- front of the kept window stays byte-identical while history grows and
  -- the provider's prefix cache keeps matching across requests instead of
  -- breaking on every message. The window then oscillates between
  -- keep_recent and keep_recent + slide_step messages.
  local raw_cutoff = #other_messages - config.keep_recent
  if raw_cutoff < 1 then
    return messages, false
  end
  local cutoff_idx = raw_cutoff
  local step = tonumber(config.slide_step) or 0
  if step > 1 then
    cutoff_idx = math.floor(raw_cutoff / step) * step
    if cutoff_idx < 1 then
      -- Not a full step accumulated yet: keep the whole window instead of
      -- sliding early. Truncation simply starts a bit later than
      -- trigger_threshold; the window cap is keep_recent + slide_step.
      return messages, false
    end
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
          log.debug(
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

  -- Build final result: static system messages + cleaned history, with the
  -- volatile notice ALWAYS as the very last message.
  --
  -- The notice embeds per-request numbers (total messages, window bounds),
  -- so its content changes on every request once truncation has fired.
  -- Anywhere in front of content that is supposed to stay cached it
  -- invalidates the provider's prefix cache at its position; the previous
  -- "before the newest user message" placement turned into a head-of-array
  -- poison whenever the window started at that user message (a single-turn
  -- window), breaking the cache on every request and leaving only the
  -- tools array cacheable. As the last entry the invalidation is confined
  -- to the suffix: every earlier message stays byte-identical to what the
  -- previous request already sent.
  --
  -- Flows that inspect the last request message (auto-continue resuming a
  -- truncated assistant, tool-result resend looking for a trailing tool
  -- message, the manual/UI retry gates) call M.strip_trailing_notice()
  -- first; they send the stripped list only when the last entry's shape is
  -- the contract (auto-continue).
  local result = {}
  vim.list_extend(result, system_messages)
  vim.list_extend(result, cleaned)

  table.insert(result, {
    role = 'system',
    content = M._generate_context_notice(
      #messages,
      #cleaned,
      start_idx,
      #other_messages
    ),
  })

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

--- Whether a message is the volatile context-window notice.
---
--- The notice embeds per-request numbers and is regenerated on every
--- truncated request; it is never part of the session history.
--- @param msg table|nil
--- @return boolean
function M.is_context_notice(msg)
  return type(msg) == 'table'
    and msg.role == 'system'
    and type(msg.content) == 'string'
    and msg.content:find('^%[Context Window Notice%]', 1) ~= nil
end

--- Return the message list without a trailing context-window notice.
---
--- The notice always sits at the very end of a truncated request, so flows
--- that inspect the last request message (auto-continue resuming the
--- trailing assistant, tool-result resend looking for a trailing tool
--- message, the manual and UI retry gates) must pass the request through
--- this helper first. A notice anywhere else is left untouched: only the
--- tail entry can be the current one.
--- @param messages table|nil
--- @return table The same table when there is nothing to strip, otherwise
---   a copy without the trailing notice
function M.strip_trailing_notice(messages)
  if not messages or #messages == 0 then
    return messages
  end
  if not M.is_context_notice(messages[#messages]) then
    return messages
  end
  local out = {}
  vim.list_extend(out, messages)
  table.remove(out)
  return out
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

