-- Auto-retry for LLM requests on connection errors and timeouts
-- Tracks retry state per session and schedules delayed retries
local M = {}

local log = require('chat.log')

-- Per-session retry state
-- retry_counts[session_id] = number of retries attempted so far
local retry_counts = {}

-- Sessions currently waiting for auto-retry (during delay period)
-- retrying_sessions[session_id] = true
local retrying_sessions = {}

-- Pending retry timers per session
local timers = {}

-- Curl exit codes that are retryable (connection failures and timeouts)
local RETRYABLE_ERRORS = {
  [6] = true, -- Couldn't resolve host
  [7] = true, -- Failed to connect to host
  [28] = true, -- Operation timeout
  [35] = true, -- SSL/TLS handshake failure
  [52] = true, -- Empty reply from server
  [56] = true, -- Failure with receiving network data
}

--- Check if a curl exit code is retryable
--- @param code integer The curl exit code
--- @return boolean True if the error is retryable
function M.is_retryable_error(code)
  return RETRYABLE_ERRORS[code] == true
end

--- Check if a session is currently waiting for auto-retry
--- @param session_id string The session identifier
--- @return boolean True if session is in retry delay period
function M.is_retrying(session_id)
  return retrying_sessions[session_id] == true
end

--- Get the current retry count for a session
--- @param session_id string The session identifier
--- @return integer The number of retries attempted
function M.get_retry_count(session_id)
  return retry_counts[session_id] or 0
end

--- Reset retry count and cancel any pending retry for a session
--- Called when a new user message is sent or session is deleted
--- @param session_id string The session identifier
function M.reset_retry_count(session_id)
  if timers[session_id] then
    timers[session_id]:stop()
    timers[session_id] = nil
  end
  retrying_sessions[session_id] = nil
  retry_counts[session_id] = 0
end

--- Attempt to schedule an auto-retry for a session
--- Uses get_request_messages to re-send the same messages
--- @param session_id string The session identifier
--- @return string|nil Hint message if retryable, nil if not retryable
function M.schedule_retry(session_id)
  local config = require('chat.config')
  local max_retries = (config.config.retry and config.config.retry.max_retries) or 3
  local retry_delay = (config.config.retry and config.config.retry.retry_delay) or 2000

  local count = retry_counts[session_id] or 0
  if count >= max_retries then
    -- Max retries reached, reset state
    retry_counts[session_id] = 0
    retrying_sessions[session_id] = nil
    return string.format(
      'All %d auto-retries exhausted. Press r to retry manually.',
      max_retries
    )
  end

  count = count + 1
  retry_counts[session_id] = count
  retrying_sessions[session_id] = true

  -- Cancel any existing timer for this session
  if timers[session_id] then
    timers[session_id]:stop()
    timers[session_id] = nil
  end

  -- Keep spinner running for current session
  if session_id == require('chat.windows').current_session() then
    require('chat.spinners').start()
  end

  -- Schedule the retry after delay
  timers[session_id] = vim.defer_fn(function()
    timers[session_id] = nil
    retrying_sessions[session_id] = nil

    -- Check if session still exists
    local sessions = require('chat.sessions')
    if not sessions.exists(session_id) then
      retry_counts[session_id] = 0
      return
    end

    -- Re-send the request with current messages
    local messages = sessions.get_request_messages(session_id)
    local protocol = require('chat.protocol')
    local jobid = protocol.request({
      session = session_id,
      messages = messages,
    })

    if jobid and jobid > 0 then
      log.info(string.format(
        'Auto-retry %d/%d started, jobid: %d',
        count, max_retries, jobid
      ))
    else
      log.error('Auto-retry failed to start request')
      retry_counts[session_id] = 0
      if session_id == require('chat.windows').current_session() then
        require('chat.spinners').stop()
      end
    end
  end, retry_delay)

  local remaining = max_retries - count
  return string.format(
    'Auto-retry %d/%d (%d remaining).',
    count, max_retries, remaining
  )
end

--- Handle a curl exit error, potentially scheduling an auto-retry
--- @param session_id string The session identifier
--- @param code integer The curl exit code
--- @return string|nil Hint message if retryable, nil if not retryable
function M.handle_exit_error(session_id, code)
  if not M.is_retryable_error(code) then
    return nil
  end
  return M.schedule_retry(session_id)
end

--- Cancel any pending retry for a session
--- @param session_id string The session identifier
function M.cancel_retry(session_id)
  if timers[session_id] then
    timers[session_id]:stop()
    timers[session_id] = nil
  end
  retrying_sessions[session_id] = nil
  retry_counts[session_id] = 0
end

return M

