-- Session tool call handling
local M = {}

local log = require('chat.log')
local tools = require('chat.tools')
local util = require('chat.util')
local storage = require('chat.sessions.storage')

local job_tool_calls = {} ---@type table<string, table>

--- @class ChatToolCallFunction
--- @field name string
--- @field arguments string

--- @class ChatToolCall
--- @field id string
--- @field type string
--- @field function ChatToolCallFunction

--- Check whether a bare JSON value token is actually a literal
--- (number, boolean, null) that must NOT be quoted when repairing
--- damaged arguments.
--- @param v string Bare value token, e.g. "true", "42", "-1.5"
--- @return boolean
local function is_json_literal(v)
  return v:match('^%-?%d+%.?%d*$') ~= nil
    or v == 'true'
    or v == 'false'
    or v == 'null'
end

--- Quote bare (unquoted) string values in a damaged JSON arguments
--- string. Some models or relays strip quotes from argument values,
--- producing payloads like {"path": README.md} that fail strict JSON
--- decoding and would drop the whole tool call. Repair rules:
---   1. Top-level bare scalars:   {"path": README.md}    -> {"path": "README.md"}
---   2. Bare flat-array elements: {"path": [a.lua, b]}   -> {"path": ["a.lua", "b"]}
--- Numbers, booleans and null are never quoted. Arrays containing
--- nested objects/arrays are left untouched (only flat arrays are
--- rewritten), so valid nested structures cannot be corrupted.
--- @param s string Raw arguments string that already failed strict decode
--- @return string repaired Repaired string
local function repair_json_arguments(s)
  -- 1. Top-level bare scalar values ("key": value followed by , or })
  s = s:gsub('(:%s*)([^%s"%[%{][^,%}]*)(%s*[,}%]])', function(pre, val, post)
    if is_json_literal(val) then
      return pre .. val .. post
    end
    return pre .. '"' .. val .. '"' .. post
  end)

  -- 2. Bare elements of flat arrays (no nested {} or [] inside)
  s = s:gsub('(:%s*)(%[)([^%[%]%{%}]*)(%])', function(pre, lb, inner, rb)
    local fixed = {}
    for elem in inner:gmatch('[^,]+') do
      elem = elem:gsub('^%s+', ''):gsub('%s+$', '')
      if
        elem ~= ''
        and not is_json_literal(elem)
        and not elem:match('^"')
      then
        table.insert(fixed, '"' .. elem .. '"')
      else
        table.insert(fixed, elem)
      end
    end
    if #fixed == 0 then
      return pre .. lb .. inner .. rb
    end
    return pre .. lb .. ' ' .. table.concat(fixed, ', ') .. ' ' .. rb
  end)

  return s
end

--- Decode tool call arguments with tolerance for common damage.
--- Strict decode first; on failure, quote bare string values and retry
--- once. A parameter value shaped as a string or an array of strings
--- must survive even when upstream components stripped its quotes.
--- Returns nil when the arguments are not decodable to an object at
--- all (garbage, truncated, or a bare scalar like "123").
--- @param s string Raw arguments from the tool call
--- @return table|nil args Decoded arguments table, or nil when undecodable
function M.decode_arguments(s)
  if type(s) ~= 'string' or s == '' then
    return nil
  end

  local ok, args = pcall(vim.json.decode, s)
  if ok and type(args) == 'table' then
    return args
  end

  local repaired = repair_json_arguments(s)
  if repaired ~= s then
    local ok2, args2 = pcall(vim.json.decode, repaired)
    if ok2 and type(args2) == 'table' then
      log.warn(string.format(
        'arguments decoded only after repairing bare values:\n'
          .. '  raw:      %s\n'
          .. '  repaired: %s',
        s,
        repaired
      ))
      return args2
    end
  end

  return nil
end

--- Checks whether the session history already contains a tool result for
--- the given tool_call_id. Used to keep tool result callbacks idempotent:
--- when cancel_progress force-finished a dead job, a queued on_exit may
--- still invoke the callback afterwards and would otherwise append a
--- duplicate tool result message.
--- @param session_id string The session identifier
--- @param tool_call_id string The tool call id
--- @return boolean True if a tool result exists for tool_call_id
local function has_tool_result(session_id, tool_call_id)
  local session = storage.sessions[session_id]
  local messages = session and session.messages or {}
  for _, m in ipairs(messages) do
    if m.role == 'tool' and m.tool_call_id == tool_call_id then
      return true
    end
  end
  return false
end

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
  local messages = require('chat.sessions.messages')
  local raw_tool_calls = job_tool_calls[jobid]
  local tool_calls = util.transform(raw_tool_calls)

  -- Check if tool call parsing failed (nil or empty)
  if not tool_calls or #tool_calls == 0 then
    if not raw_tool_calls then
      log.warn('No tool calls received for job: ' .. jobid .. ' (finish_reason was tool_calls but no data)')
    else
      log.error('Tool call parsing failed or no valid tool calls found for job: ' .. jobid)
    end

    -- Append error message to notify user
    local error_message = {
      error = 'Tool call parsing failed. The AI model generated malformed tool call data. Please try again or check the logs.',
      created = os.time(),
      session = session_id,
    }
    messages.append_message(session_id, error_message)
    windows.on_message(session_id, error_message)

    progress.on_progress_done(jobid, {
      tool_calls = {},
    })
    M.on_complete(session_id, jobid)

    -- Clear job_tool_calls
    job_tool_calls[jobid] = nil
    return
  end

  progress.on_progress_done(jobid, {
    tool_calls = tool_calls,
  })

  -- Prepare assistant message for UI display (already saved by progress.on_progress_done)
  local assistant_tool_call_message = {
    role = 'assistant',
    tool_calls = tool_calls,
    created = os.time(),
  }
  windows.on_tool_call_start(session_id, assistant_tool_call_message)
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

    local arguments = M.decode_arguments(tool_call['function'].arguments or '')
    if arguments then
      local call_ok, result =
        pcall(tools.call, tool_call['function'].name, arguments, {
        cwd = storage.sessions[session_id].cwd,
        session = session_id,
        callback = function(res)
          local async = require('chat.sessions.async')

          -- Idempotency: if a tool result for this tool_call_id already
          -- exists (e.g. cancel_progress force-finished the dead job and
          -- a queued on_exit fired late), skip appending a duplicate
          -- message and just release the pending entry.
          if has_tool_result(session_id, tool_call.id) then
            async.finish_async_tool(session_id, res.jobid or res.mcp_tool_call_id)
            return
          end

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
          messages.append_message(session_id, tool_done_message)
          windows.on_tool_call_done(session_id, { tool_done_message })
          async.finish_async_tool(session_id, res.jobid or res.mcp_tool_call_id)
        end,
      })
      -- Handle error raised or nil result from tools.call
      if not call_ok or not result then
        local tool_done_message = {
          role = 'tool',
          content = not call_ok
              and ('tool_call raised an error: ' .. tostring(result))
            or 'tool_call returned no result',
          tool_call_id = tool_call.id,
          created = os.time(),
          tool_call_state = {
            name = tool_call['function'].name,
            error = not call_ok
                and ('raised: ' .. tostring(result))
              or 'no result returned from tool',
          },
        }
        messages.append_message(session_id, tool_done_message)
        windows.on_tool_call_done(session_id, { tool_done_message })
      elseif result.jobid or result.mcp_tool_call_id then
        local async = require('chat.sessions.async')
        async.start_async_tool(
          session_id,
          result.jobid or result.mcp_tool_call_id,
          {
            tool_call_id = tool_call.id,
            tool_name = tool_call['function'].name,
          }
        )
      else
        local tool_done_done_message = {
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
        messages.append_message(session_id, tool_done_done_message)
        windows.on_tool_call_done(session_id, { tool_done_done_message })
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
      messages.append_message(session_id, tool_done_message)
      log.warn('failed to decode arguments, raw is: '
        .. (tool_call['function'].arguments or 'nil'))
      windows.on_tool_call_done(session_id, { tool_done_message })
    end
    ::continue::
  end

  -- clear job_tool_calls by id
  job_tool_calls[jobid] = nil
end

--- Handles completion of tool call processing
--- @param session_id string The session identifier
--- @param jobid string The job identifier for the streaming request
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
    log.debug('Session cancelled, skip sending tool results.')
    async.cancelled_sessions[session_id] = nil
    return
  end

  local msg = require('chat.sessions.messages').get_request_messages(session_id)
  local last = msg and msg[#msg] or nil
  if last and last.role == 'tool' then
    -- Reset retry count for new tool result request
    require('chat.sessions.retry').reset_retry_count(session_id)
    local protocol = require('chat.protocol')
    log.debug('send tool_call results to server.')
    local jobid = protocol.request({
      session = session_id,
      messages = msg,
    })
    log.debug('curl request jobid is ' .. tostring(jobid))
    if jobid and jobid > 0 then
      if session_id == require('chat.windows').current_session() then
        require('chat.spinners').start()
      end
    else
      log.error('Failed to start request: jobid is nil or invalid')
    end
  end
end

return M

