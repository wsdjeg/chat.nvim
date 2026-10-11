-- Session async tool management
local M = {}

M.pending_async_tools = {} ---@type table<string, table>
M.cancelled_sessions = {} ---@type table<string, boolean>

--- @class ChatAsyncToolContext
--- @field tool_call_id string Tool call id from the assistant message
--- @field tool_name string Tool name

-- Tool call contexts for pending async tools, keyed by jobid. Used to
-- recover when a tool's job callback crashes before invoking
-- ctx.callback: cancel_progress can append a placeholder tool result for
-- the dangling tool_call_id and release the pending entry.
-- pending_tool_contexts[session_id][jobid] = ChatAsyncToolContext
local pending_tool_contexts = {} ---@type table<string, table<integer, ChatAsyncToolContext>>

--- Registers an async tool call as pending for a session
--- Tracks tool calls that are running asynchronously (background jobs or MCP tools)
--- @param session_id string The session identifier
--- @param jobid integer The job ID for the async tool call (negative for MCP tools)
--- @param context ChatAsyncToolContext|nil Tool call context for crash recovery
function M.start_async_tool(session_id, jobid, context)
  M.pending_async_tools[session_id] = M.pending_async_tools[session_id] or {}
  table.insert(M.pending_async_tools[session_id], jobid)
  if context then
    pending_tool_contexts[session_id] = pending_tool_contexts[session_id] or {}
    pending_tool_contexts[session_id][jobid] = context
  end
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

  local contexts = pending_tool_contexts[session_id]
  if contexts then
    contexts[jobid] = nil
    if not next(contexts) then
      pending_tool_contexts[session_id] = nil
    end
  end
end

--- Gets the tool call context registered for a pending async tool
--- @param session_id string The session identifier
--- @param jobid integer The job ID (negative for MCP tools)
--- @return ChatAsyncToolContext|nil The context if registered, nil otherwise
function M.get_tool_context(session_id, jobid)
  local contexts = pending_tool_contexts[session_id]
  return contexts and contexts[jobid] or nil
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

