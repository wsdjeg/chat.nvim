local M = {}

local uv = vim.uv

local log = require('chat.log')

local timer = nil
local message_queue = {}
local retry_counts = {} -- Track consecutive send failures per session
local MAX_RETRIES = 3

--- One queued message.
---
--- The queue stores the entry itself, not a bare string: `origin` says who
--- asked for the message (local prompt keymap, HTTP client, IM integration,
--- scheduler), so the receiver can behave differently without guessing. The
--- entry travels untouched from `push()` through `pop()` back into the retry
--- slot, so a retried message keeps its origin.
---@class ChatQueueEntry
---@field content string message content
---@field origin? 'local'|'http'|'integration'|'scheduler' message source

-- Stop timer when no messages
local function stop_timer()
  if timer then
    timer:stop()
    timer:close()
    timer = nil
  end
end

-- Start timer for periodic polling (used when sessions are in progress)
local function start_timer()
  if not timer then
    timer = uv.new_timer()
    if timer then
      timer:start(5000, 5000, vim.schedule_wrap(M._process_queue))
    else
      log.error('Failed to start message queue timer')
    end
  end
end

-- Process queue (exported for internal use)
function M._process_queue()
  local has_messages = false
  local has_blocked = false

  for session, queue in pairs(message_queue) do
    if queue and #queue > 0 then
      has_messages = true
      if not require('chat.sessions').is_in_progress(session) then
        local entry = M.pop(session)
        local result = require('chat.windows').send_message(
          session,
          entry.content,
          entry
        )
        -- Skill commands return true (handled, no LLM request)
        if result then
          -- Skill dispatched, message fully handled
          retry_counts[session] = nil
        elseif not require('chat.sessions').is_in_progress(session) then
          -- LLM send failed (session didn't enter in_progress)
          retry_counts[session] = (retry_counts[session] or 0) + 1
          if retry_counts[session] >= MAX_RETRIES then
            log.error(
              'Message dropped after '
                .. MAX_RETRIES
                .. ' failed attempts for session: '
                .. session
            )
            retry_counts[session] = nil
          else
            -- Put the whole entry back at the front of the queue: origin and
            -- content are kept exactly as they were pushed.
            table.insert(message_queue[session], 1, entry)
          end
        else
          -- Send succeeded, reset retry counter
          retry_counts[session] = nil
        end
      else
        -- Session is busy, messages are blocked
        has_blocked = true
      end
    end
  end

  if not has_messages then
    -- No messages at all, stop timer
    stop_timer()
  elseif has_blocked then
    -- There are blocked messages waiting for sessions to become free
    -- Ensure timer is running to retry when it becomes free
    start_timer()
  end
end

--- Queue a message for a session.
--- @param session string session ID
--- @param entry ChatQueueEntry message entry, stored as-is
function M.push(session, entry)
  if type(entry) ~= 'table' or type(entry.content) ~= 'string' then
    log.error(
      'queue.push expects an entry table { content = string }: ' .. session
    )
    return
  end

  if not message_queue[session] then
    message_queue[session] = {}
  end

  table.insert(message_queue[session], entry)

  -- If session is not in progress, process immediately
  -- instead of waiting for the 5-second timer
  if not require('chat.sessions').is_in_progress(session) then
    vim.schedule(function()
      M._process_queue()
    end)
  else
    -- Session is busy, start polling timer to retry when it becomes free
    start_timer()
  end
end

--- Take the oldest entry of a session's queue.
--- @param session string session ID
--- @return ChatQueueEntry|nil entry exactly as it was pushed
function M.pop(session)
  if not message_queue[session] or #message_queue[session] == 0 then
    return nil
  end
  return table.remove(message_queue[session], 1)
end

-- Check if session has pending messages
function M.has_pending(session)
  return message_queue[session] and #message_queue[session] > 0
end

-- Optional: manual start (for backward compatibility)
function M.start()
  -- Timer starts on demand in push(), no need to start eagerly
end

-- Cleanup
function M.stop()
  stop_timer()
end

return M

