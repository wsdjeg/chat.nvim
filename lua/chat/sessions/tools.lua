-- Session tool call handling
local M = {}

local log = require('chat.log')
local tools = require('chat.tools')
local util = require('chat.util')
local storage = require('chat.sessions.storage')

local job_tool_calls = {} ---@type table<string, table>

function M.on_progress_tool_call(jobid, tool_call)
  job_tool_calls[jobid] = job_tool_calls[jobid] or {}

  -- Some streaming implementations may emit early deltas without index
  -- what the fuck anthropic tool_calls started with 1, and openai started with 0.
  if tool_call.index == nil then
    return
  end

  local idx = tool_call.index

  if not job_tool_calls[jobid][idx] then
    job_tool_calls[jobid][idx] = {
      id = tool_call.id,
      index = tool_call.index,
      type = tool_call.type,
      ['function'] = {
        name = nil,
        arguments = '',
      },
    }
  end

  local state = job_tool_calls[jobid][idx]

  -- function.name is not a delta, just overwrite when it appears
  if
    tool_call['function']
    and tool_call['function'].name ~= nil
    and tool_call['function'].name ~= vim.NIL
    and tool_call['function'].name ~= ''
  then
    state['function'].name = tool_call['function'].name
  end

  -- function.arguments is streamed as chunks, must be concatenated
  if
    tool_call['function']
    and tool_call['function'].arguments ~= nil
    and tool_call['function'].arguments ~= vim.NIL
  then
    state['function'].arguments = state['function'].arguments
      .. tool_call['function'].arguments
  end
end

--- Handles completion of streaming tool calls
--- @param jobid string The job identifier for the streaming request
function M.on_progress_tool_call_done(jobid)
  local progress = require('chat.sessions.progress')
  local session_id = progress.get_progress_session(jobid)
  local windows = require('chat.windows')

  local tool_calls = util.transform(job_tool_calls[jobid])

  progress.on_progress_done(jobid, {
    tool_calls = tool_calls,
  })

  windows.on_tool_call_start(session_id, {
    role = 'assistant',
    tool_calls = tool_calls,
    created = os.time(),
    session = session_id,
  })
  M.on_complete(session_id, jobid)

  for _, tool_call in ipairs(tool_calls) do
    -- Skip incomplete tool calls
    if not tool_call then
      log.warn('Skipping nil tool_call')
      goto continue
    end
    if not tool_call['function'] then
      log.warn(
        'Skipping tool_call without function field: '
          .. vim.inspect(tool_call)
      )
      goto continue
    end
    if not tool_call['function'].name then
      log.warn(
        'Skipping tool_call without function.name: ' .. vim.inspect(tool_call)
      )
      goto continue
    end

    local ok, arguments =
      pcall(vim.json.decode, tool_call['function'].arguments or '')
    if ok then
      local result = tools.call(tool_call['function'].name, arguments, {
        cwd = storage.sessions[session_id].cwd,
        session = session_id,
        callback = function(res)
          local tool_done_message = {
            role = 'tool',
            content = res.content
              or ('tool_call run failed, error is: \n' .. res.error),
            tool_call_id = tool_call.id,
            created = os.time(),
            tool_call_state = {
              name = tool_call['function'].name,
              error = res.error,
            },
          }
          require('chat.sessions.messages').append_message(session_id, tool_done_message)
          windows.on_tool_call_done(session_id, { tool_done_message })
          local async = require('chat.sessions.async')
          async.finish_async_tool(session_id, res.jobid or res.mcp_tool_call_id)
        end,
      })
      if result.jobid or result.mcp_tool_call_id then
        local async = require('chat.sessions.async')
        async.start_async_tool(session_id, result.jobid or result.mcp_tool_call_id)
      else
        local tool_done_message = {
          role = 'tool',
          content = result.content
            or ('tool_call run failed, error is: \n' .. result.error),
          tool_call_id = tool_call.id,
          created = os.time(),
          tool_call_state = {
            name = tool_call['function'].name,
            error = result.error,
          },
        }
        require('chat.sessions.messages').append_message(session_id, tool_done_message)
        windows.on_tool_call_done(session_id, { tool_done_message })
      end
    else
      local tool_done_message = {
        role = 'tool',
        content = 'can not run this tool, failed to decode arguments.',
        tool_call_id = tool_call.id,
        created = os.time(),
        tool_call_state = {
          name = tool_call['function'].name,
          error = 'failed to decode arguments.',
        },
      }
      require('chat.sessions.messages').append_message(session_id, tool_done_message)
      log.info('failed to decode arguments, error is:' .. arguments)
      log.info('arguments is:' .. (tool_call['function'].arguments or 'nil'))
      windows.on_tool_call_done(session_id, { tool_done_message })
    end
    ::continue::
  end

  -- clear job_tool_calls by id
  job_tool_calls[jobid] = nil
end

--- Handles completion of tool call processing
--- @param session_id string The session identifier
--- @param jobid string The job identifier
function M.on_complete(session_id, jobid)
  local progress = require('chat.sessions.progress')
  local usage = progress.get_progress_usage(jobid)
  local message = {
    on_complete = true,
    usage = usage,
    created = os.time(),
  }
  require('chat.sessions.messages').append_message(session_id, message)
  require('chat.sessions.storage').write_cache(session_id)
  require('chat.windows').on_message(session_id, message)
end

function M.send_tool_results(session_id)
  local async = require('chat.sessions.async')

  -- Check if session was cancelled
  if async.cancelled_sessions[session_id] then
    log.info('Session cancelled, skip sending tool results.')
    async.cancelled_sessions[session_id] = nil
    return
  end

  local msg = require('chat.sessions.messages').get_request_messages(session_id)
  if msg[#msg].role == 'tool' then
    local protocol = require('chat.protocol')
    log.info('send tool_call results to server.')
    local jobid = protocol.request({
      session = session_id,
      messages = require('chat.sessions.messages').get_request_messages(session_id),
    })
    log.info('curl request jobid is ' .. jobid)
    if session_id == require('chat.windows').current_session() then
      require('chat.spinners').start()
    end
  end
end

return M
