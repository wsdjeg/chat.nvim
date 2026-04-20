-- Session progress: streaming output and job tracking
local M = {}

local job = require('job')

local progress_reasoning_contents = {} ---@type table<string, string>
local progress_finish_reasons = {} ---@type table<string, string>
local progress_usage = {} ---@type table<string, table>
local jobid_session = {} ---@type table<integer, string>
local progress_messages = {} ---@type table<string, string>

--- Associates a session ID with a job ID for tracking streaming progress
--- @param session_id string The session identifier
--- @param jobid integer The job identifier for the streaming request
function M.set_session_jobid(session_id, jobid)
  if jobid > 0 then
    jobid_session[jobid] = session_id
  end
end

--- Retrieves the session ID associated with a job ID
--- @param jobid integer The job identifier
--- @return string|nil The session ID if found, nil otherwise
function M.get_progress_session(jobid)
  return jobid_session[jobid]
end

--- Stores usage statistics for a job
--- @param jobid integer The job identifier
--- @param usage table Usage statistics table (prompt_tokens, completion_tokens, etc.)
function M.set_progress_usage(jobid, usage)
  progress_usage[jobid] = usage
end

--- Retrieves usage statistics for a job
--- @param jobid integer The job identifier
--- @return table|nil Usage statistics table if available, nil otherwise
function M.get_progress_usage(jobid)
  return progress_usage[jobid]
end

--- Sets the finish reason for a streaming job
--- @param jobid integer The job identifier
--- @param reason string The finish reason (e.g., "stop", "length", "tool_calls")
function M.set_progress_finish_reason(jobid, reason)
  progress_finish_reasons[jobid] = reason
end

--- Gets the finish reason for a streaming job
--- @param jobid integer The job identifier
--- @return string|nil The finish reason if available, nil otherwise
function M.get_progress_finish_reason(jobid)
  return progress_finish_reasons[jobid]
end

--- Handles streaming text output from LLM response
--- Updates the progress message buffer and pushes text to the result window
--- @param jobid integer The job identifier for the streaming request
--- @param text string The text chunk received from the stream
function M.on_progress(jobid, text)
  local session_id = jobid_session[jobid]
  if session_id then
    local windows = require('chat.windows')

    if session_id == windows.current_session() then
      if
        not progress_messages[session_id]
        and not progress_reasoning_contents[session_id]
      then
        windows.push_text({
          is_start = true,
          content = text,
        })
      else
        if not progress_messages[session_id] then
          windows.push_text({
            content = '\n\n' .. text,
          })
        else
          windows.push_text({
            content = text,
          })
        end
      end
    end

    progress_messages[session_id] = (progress_messages[session_id] or '') .. text
  end
end

--- Handles streaming reasoning content from LLM response (for models with reasoning tokens)
--- Updates the reasoning content buffer and pushes to the result window
--- @param jobid integer The job identifier for the streaming request
--- @param text string The reasoning text chunk received from the stream
function M.on_progress_reasoning_content(jobid, text)
  local session_id = jobid_session[jobid]
  if session_id then
    local windows = require('chat.windows')

    if session_id == windows.current_session() then
      if
        not progress_messages[session_id]
        and not progress_reasoning_contents[session_id]
      then
        windows.push_text({
          is_start = true,
          reasoning_content = text,
        })
      else
        windows.push_text({
          reasoning_content = text,
        })
      end
    end

    progress_reasoning_contents[session_id] = (
      progress_reasoning_contents[session_id] or ''
    ) .. text
  end
end

--- @class ChatProgressDoneOpt
--- @field tool_calls? ChatToolCall[]

--- Finalizes the streaming response and saves the complete message
--- @param jobid integer The job identifier for the streaming request
--- @param opts ChatProgressDoneOpt Optional parameters including tool_calls
function M.on_progress_done(jobid, opts)
  local session_id = M.get_progress_session(jobid)
  if progress_messages[session_id] then
    local reasoning_content
    if progress_reasoning_contents[session_id] then
      reasoning_content = progress_reasoning_contents[session_id]
      progress_reasoning_contents[session_id] = nil
    end
    local message = {
      role = 'assistant',
      reasoning_content = reasoning_content,
      content = progress_messages[session_id],
      created = os.time(),
    }
    if opts and opts.tool_calls then
      message.tool_calls = opts.tool_calls
    end
    require('chat.sessions.messages').append_message(session_id, message)
    progress_messages[session_id] = nil
  else
    progress_reasoning_contents[session_id] = nil
    progress_messages[session_id] = nil
  end
  require('chat.sessions.storage').write_cache(session_id)
end

--- Handles job exit/cleanup when streaming ends or is interrupted
--- Clears all progress tracking data for the job
--- @param jobid integer The job identifier
--- @param code integer The exit code from the job
--- @param signal integer The signal that caused the exit (if any)
function M.on_progress_exit(jobid, code, signal)
  local session_id = M.get_progress_session(jobid)
  progress_reasoning_contents[session_id] = nil
  progress_messages[session_id] = nil
  jobid_session[jobid] = nil
end

--- Gets the current streaming message content for a session
--- @param session_id string The session identifier
--- @return string|nil The current message content being streamed, nil if none
function M.get_progress_message(session_id)
  return progress_messages[session_id]
end

--- Gets the current reasoning content for a session
--- @param session_id string The session identifier
--- @return string|nil The current reasoning content being streamed, nil if none
function M.get_progress_reasoning_content(session_id)
  return progress_reasoning_contents[session_id]
end

--- Checks if a session has an active streaming request or pending async tools
--- @param session_id string The session identifier
--- @return boolean True if the session has active progress, false otherwise
function M.is_in_progress(session_id)
  -- Check if there's an active job for this session
  for _, v in pairs(jobid_session) do
    if v == session_id then
      return true
    end
  end

  -- Also check if there are pending async tools
  local async = require('chat.sessions.async')
  if async.has_pending_async_tools(session_id) then
    return true
  end

  return false
end

--- Cancels any active streaming request or async tool calls for a session
--- Stops LLM streaming jobs and cancels pending MCP tool requests
--- @param session_id string The session identifier
function M.cancel_progress(session_id)
  --- if the llm progress is running, stop llm progress and return
  for jobid, v in pairs(jobid_session) do
    if v == session_id then
      job.stop(jobid, 2)
      return
    end
  end

  local async = require('chat.sessions.async')
  local pending = async.pending_async_tools[session_id]

  -- Cancel MCP tool calls
  if pending then
    async.cancelled_sessions[session_id] = true
    local ok, mcp = pcall(require, 'chat.mcp')
    if ok and mcp then
      for _, id in ipairs(pending) do
        if id < 0 then
          mcp.cancel_request(id)
        else
          job.stop(id, 2)
        end
      end
    end

    -- Stop spinner
    if session_id == require('chat.windows').current_session() then
      require('chat.spinners').stop()
    end
  end
end

return M
