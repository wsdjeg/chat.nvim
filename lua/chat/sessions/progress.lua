-- Session progress: streaming output and job tracking
local M = {}

local job = require('job')
local storage = require('chat.sessions.storage')

local progress_reasoning_contents = {} ---@type table<string, string>
local progress_finish_reasons = {} ---@type table<string, string>
local progress_usage = {} ---@type table<string, table>
local jobid_session = {} ---@type table<integer, string>
local progress_messages = {} ---@type table<string, string>

function M.set_session_jobid(session_id, jobid)
  if jobid > 0 then
    jobid_session[jobid] = session_id
  end
end

function M.get_progress_session(jobid)
  return jobid_session[jobid]
end

function M.set_progress_usage(jobid, usage)
  progress_usage[jobid] = usage
end

function M.get_progress_usage(jobid)
  return progress_usage[jobid]
end

function M.set_progress_finish_reason(jobid, reason)
  progress_finish_reasons[jobid] = reason
end

function M.get_progress_finish_reason(jobid)
  return progress_finish_reasons[jobid]
end

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

function M.on_progress_done(jobid)
  local session_id = M.get_progress_session(jobid)
  if progress_messages[session_id] then
    local reasoning_content
    if progress_reasoning_contents[session_id] then
      reasoning_content = progress_reasoning_contents[session_id]
      progress_reasoning_contents[session_id] = nil
    end
    require('chat.sessions.messages').append_message(session_id, {
      role = 'assistant',
      reasoning_content = reasoning_content,
      content = progress_messages[session_id],
      created = os.time(),
    })
    progress_messages[session_id] = nil
  else
    progress_reasoning_contents[session_id] = nil
    progress_messages[session_id] = nil
  end
  require('chat.sessions.storage').write_cache(session_id)
end

function M.on_progress_exit(jobid, code, signal)
  local session_id = M.get_progress_session(jobid)
  progress_reasoning_contents[session_id] = nil
  progress_messages[session_id] = nil
  jobid_session[jobid] = nil
end

function M.get_progress_message(session_id)
  return progress_messages[session_id]
end

function M.get_progress_reasoning_content(session_id)
  return progress_reasoning_contents[session_id]
end

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

