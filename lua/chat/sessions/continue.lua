-- Auto-continuation for responses truncated by max_tokens (finish_reason ==
-- "length"). Tracks a per-session continuation budget and the in-flight
-- assistant message being extended, so a truncated reply keeps being merged
-- into a single assistant message across continuation requests.
local M = {}

local counts = {}

-- Pending assistant message of an active continuation chain, keyed by session.
-- New fragments (including the final fragment on a successful "stop") are
-- appended to this message instead of starting a new one. This keeps the
-- history valid for Anthropic's strict user/assistant role alternation.
local pending = {}

--- Get the number of auto-continuations already issued for a session.
--- @param session_id string The session identifier
--- @return integer
function M.get_count(session_id)
  return counts[session_id] or 0
end

--- Get the in-flight assistant message of an active continuation chain.
--- @param session_id string The session identifier
--- @return table|nil
function M.get_pending(session_id)
  return pending[session_id]
end

--- Mark a message as the in-flight continuation target.
--- @param session_id string The session identifier
--- @param message table The assistant message being extended
function M.set_pending(session_id, message)
  pending[session_id] = message
end

--- Reset the continuation budget and pending message for a session.
--- @param session_id string The session identifier
function M.reset(session_id)
  counts[session_id] = 0
  pending[session_id] = nil
end

--- Attempt to continue a truncated response.
--
-- Sends the current request messages as-is: the truncated assistant message is
-- already the last entry, so the model resumes it directly. No synthetic user
-- message is added (matching Anthropic's and aider's continuation approach).
--
--- @param session_id string The session identifier
--- @return integer|nil jobid on success, or nil on failure
--- @return string|nil hint User-facing hint when the continuation budget is exhausted
function M.continue(session_id)
  local config = require('chat.config')
  local c = config.config.continuation or {}
  if c.enable == false then
    return nil
  end

  local max = c.max_continuations or 3
  local count = counts[session_id] or 0

  if count >= max then
    M.reset(session_id)
    return nil, string.format('Auto-continue limit reached (%d).', max)
  end

  local new_count = count + 1
  counts[session_id] = new_count

  -- A continuation is a brand-new request, so connection retries start fresh.
  require('chat.sessions.retry').reset_retry_count(session_id)

  local messages =
    require('chat.sessions.messages').get_request_messages(session_id)
  local protocol = require('chat.protocol')
  local jobid = protocol.request({
    session = session_id,
    messages = messages,
  })

  if jobid and jobid > 0 then
    require('chat.log').info(string.format(
      'Auto-continue %d/%d started, jobid: %d',
      new_count, max, jobid
    ))
    return jobid
  end

  -- Roll back so a failed request doesn't consume the budget.
  counts[session_id] = count
  require('chat.log').error('Auto-continue failed to start request')
  return nil
end

return M
