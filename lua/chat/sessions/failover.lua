-- Auto-failover for api-key errors (multi-token support).
--
-- When an LLM request dies on an api-key error (rate limit, quota
-- exhausted, server error) BEFORE any content has streamed, the request is
-- transparently re-sent with the next api key:
--
--   * nothing about the keys is sent to the model: the rotation is
--     surfaced as a UI-only `notice` message in the chat window
--     ("API key #1 hit its quota, retrying with the next api key..."),
--     stored with the session but excluded from the request messages
--   * the failed key is cooled down by the tokens module, so the retry
--     naturally picks another key
--   * at most (#keys - 1) rotations per request; once the budget is gone
--     the plain error message is shown as before
--
-- A rotation only happens while the failed job is fully exited: the error
-- handler marks the job, the exit handler consumes the mark after cleanup
-- and starts the new request on a short timer (avoids racing the spinner
-- / job bookkeeping of the dying job). If the user cancels the request
-- (ctrl-c) or takes over the turn during the delay window, the rotation is
-- dropped and no notice is shown.
local M = {}

local log = require('chat.log')
local tokens = require('chat.tokens')

-- session_id -> number of rotations used for the current request chain
local attempts = {}

-- jobid -> session_id: an api-key error was seen on this job, waiting for
-- the job's exit handler to start the rotation
local pending = {}

-- jobid -> { session, provider, key_index, class }: why the rotation was
-- triggered, stashed by mark() while the job -> key binding is still
-- alive. Consumed by the rotated request to build the UI notice.
local reasons = {}

-- session_id -> timer handle of a scheduled (not yet started) rotation
local timers = {}

-- Injectable scheduler for tests
M._defer = function(fn, delay)
  return vim.defer_fn(fn, delay)
end

-- Delay before the rotated request starts, so the failed job's exit
-- handler (progress cleanup, spinner stop) fully settles first
local DELAY = 300 -- ms

--- Rotation budget for a provider: with N keys at most N-1 rotations make
--- sense (rotating into a key that already failed this turn is pointless).
--- @param provider string Provider name
--- @return integer
local function max_attempts(provider)
  local keys = tokens.normalize(provider)
  if not keys or #keys == 0 then
    return 0
  end
  return math.max(#keys - 1, 0)
end

--- Decide whether an api-key error should trigger a transparent rotation
--- instead of being shown to the user. Called by protocol error handlers
--- BEFORE tokens.report_error() (which consumes the job -> key binding).
--- @param jobid integer The failing job id
--- @param session string|nil Session id of the failing job
--- @param code number|string|nil Error code from the API response
--- @param msg string|nil Error message from the API response
--- @param streamed boolean True when any content / tool delta was already
---   received for this job (rotating then would duplicate visible output)
--- @return boolean True when the caller should mark the job for rotation
---   and swallow the error message
function M.should(jobid, session, code, msg, streamed)
  if streamed or session == nil then
    return false
  end
  if not tokens.is_token_error(code, msg) then
    return false
  end
  local binding = tokens.get_binding(jobid)
  if not binding then
    return false
  end
  if (attempts[session] or 0) >= max_attempts(binding.provider) then
    return false
  end
  return true
end

--- Mark a job for rotation. The exit handler later consumes the mark.
--- Must be called BEFORE tokens.report_error(): the job -> key binding is
--- read here to remember which key failed, for the UI notice shown when
--- the rotated request starts. `code` / `msg` are optional; without them
--- no notice is emitted (mark-only callers keep working).
--- @param jobid integer The failing job id
--- @param session string Session id of the failing job
--- @param code number|string|nil Error code from the API response
--- @param msg string|nil Error message from the API response
function M.mark(jobid, session, code, msg)
  pending[jobid] = session
  local binding = tokens.get_binding(jobid)
  if binding and code ~= nil then
    local class = tokens.classify_error(code, msg)
    if class then
      reasons[jobid] = {
        session = session,
        provider = binding.provider,
        key_index = binding.key_index,
        class = class,
      }
    end
  end
end

--- Check whether a job is marked for rotation.
--- @param jobid integer
--- @return boolean
function M.is_pending(jobid)
  return pending[jobid] ~= nil
end

--- Get the rotation reason stashed for a job (for tests).
--- @param jobid integer
--- @return table|nil { session, provider, key_index, class }
function M.get_reason(jobid)
  return reasons[jobid]
end

--- Build the UI notice text for a rotation reason.
--- @param reason table { provider = string, key_index = integer, class = string }
--- @return string
function M.notice_text(reason)
  local why = ({
    quota = 'hit its quota',
    rate_limit = 'hit a rate limit',
    server = 'hit a server error',
  })[reason.class] or 'failed'
  return string.format(
    'API key #%d (%s) %s, retrying with the next api key...',
    reason.key_index,
    reason.provider,
    why
  )
end

--- Show the rotation in the chat window as a UI-only notice message:
--- stored in the session history but never sent to the model (messages
--- without a user / assistant / tool role are excluded from
--- get_request_messages).
--- @param session_id string Session identifier
--- @param reason table { provider, key_index, class }
local function show_notice(session_id, reason)
  local sessions = require('chat.sessions')
  if not sessions.exists(session_id) then
    return
  end
  local message = {
    notice = M.notice_text(reason),
    created = os.time(),
  }
  sessions.append_message(session_id, message)
  require('chat.windows').on_message(session_id, message)
  require('chat.sessions.storage').write_cache(session_id)
end

--- Start the rotated request (called on a timer after the old job exited).
--- @param session_id string Session identifier
--- @param reason table|nil Stashed rotation reason, shown as a UI notice
---   once the retry is really running
local function start_request(session_id, reason)
  local sessions = require('chat.sessions')
  if not sessions.exists(session_id) then
    attempts[session_id] = 0
    return
  end

  -- The user may have taken over the turn during the delay window
  -- (manual retry, new message): never race a second request into it.
  if require('chat.sessions.progress').is_in_progress(session_id) then
    return
  end

  local messages = sessions.get_request_messages(session_id)
  local jobid = require('chat.protocol').request({
    session = session_id,
    messages = messages,
  })

  if jobid and jobid > 0 then
    -- The retry is really running: now the rotation is worth showing
    if reason then
      show_notice(session_id, reason)
    end
    if session_id == require('chat.windows').current_session() then
      require('chat.spinners').start()
    end
    log.info(string.format(
      'Api key failover request started, jobid: %d',
      jobid
    ))
  else
    -- Rotation could not start: surface the failure instead of a
    -- silently dropped turn
    attempts[session_id] = 0
    local message = {
      error = 'Api key rotation failed to start the request. Press r to retry.',
      created = os.time(),
    }
    sessions.append_message(session_id, message)
    require('chat.windows').on_message(session_id, message)
  end
end

--- Consume a job's rotation mark and schedule the rotated request.
--- Called at the very end of the job's exit handler, after cleanup.
--- @param jobid integer The failing job id
--- @param session string Session id of the failing job
--- @return boolean True when a rotation was scheduled
function M.consume(jobid, session)
  if pending[jobid] ~= session then
    reasons[jobid] = nil
    return false
  end
  pending[jobid] = nil
  local reason = reasons[jobid]
  reasons[jobid] = nil
  attempts[session] = (attempts[session] or 0) + 1

  if timers[session] then
    timers[session]:stop()
    timers[session] = nil
  end
  timers[session] = M._defer(function()
    timers[session] = nil
    start_request(session, reason)
  end, DELAY)
  return true
end

--- Reset the rotation budget for a session. Called when a request chain
--- ends successfully (the next turn starts with a fresh budget), and for
--- every brand-new request (manual retry, nudge, continuation).
--- @param session_id string Session identifier
function M.reset(session_id)
  attempts[session_id] = 0
end

--- Get the rotation attempts used for a session (for tests).
--- @param session_id string Session identifier
--- @return integer
function M.get_attempts(session_id)
  return attempts[session_id] or 0
end

--- Cancel any pending rotation for a session: stop the scheduled request,
--- drop pending job marks and clear the budget. Called on user cancel
--- (ctrl-c) and session deletion.
--- @param session_id string Session identifier
function M.cancel(session_id)
  if timers[session_id] then
    timers[session_id]:stop()
    timers[session_id] = nil
  end
  attempts[session_id] = 0
  for jobid, sid in pairs(pending) do
    if sid == session_id then
      pending[jobid] = nil
      reasons[jobid] = nil
    end
  end
end

--- Drop a job's rotation mark (user cancelled, or session vanished).
--- @param jobid integer
function M.clear(jobid)
  pending[jobid] = nil
  reasons[jobid] = nil
end

return M

