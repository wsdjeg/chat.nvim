-- Session async tool management
local M = {}

M.pending_async_tools = {} ---@type table<string, table>
M.cancelled_sessions = {} ---@type table<string, boolean>

--- Registers an async tool call as pending for a session
--- Tracks tool calls that are running asynchronously (background jobs or MCP tools)
--- @param session_id string The session identifier
--- @param jobid integer The job ID for the async tool call (negative for MCP tools)
function M.start_async_tool(session_id, jobid)
  M.pending_async_tools[session_id] = M.pending_async_tools[session_id] or {}
  table.insert(M.pending_async_tools[session_id], jobid)
end

--- Marks an async tool call as completed and removes it from pending list
--- When all pending tools finish, triggers tool result sending to LLM
--- @param session_id string The session identifier
--- @param jobid integer The job ID for the async tool call being completed
function M.finish_async_tool(session_id, jobid)
  local pending = M.pending_async_tools[session_id]
  if pending then
    for i, id in ipairs(pending) do
      if id == jobid then
        table.remove(pending, i)
        break
      end
    end
    if #pending == 0 then
      M.pending_async_tools[session_id] = nil
      require('chat.sessions.storage').write_cache(session_id)
      require('chat.sessions.tools').send_tool_results(session_id)
    end
  end
end

--- Checks if a session has pending async tool calls
--- @param session_id string The session identifier
--- @return boolean True if there are pending async tools, false otherwise
function M.has_pending_async_tools(session_id)
  local pending = M.pending_async_tools[session_id]
  return pending and #pending > 0
end

--- Clear cancelled flag for a session
---@param session_id string
function M.clear_cancelled(session_id)
  M.cancelled_sessions[session_id] = nil
end

return M
