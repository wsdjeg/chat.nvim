local M = {}

local uv = vim.uv

local timer = nil
local message_queue = {}

-- Stop timer when no messages
local function stop_timer()
  if timer then
    timer:stop()
    timer:close()
    timer = nil
  end
end

-- Process queue
local function process_queue()
  local has_messages = false

  for session, queue in pairs(message_queue) do
    if queue and #queue > 0 then
      has_messages = true
      if not require('chat.sessions').is_in_progress(session) then
        require('chat.windows').send_message(session, M.pop(session))
      end
    end
  end

  -- Stop timer if no messages
  if not has_messages then
    stop_timer()
  end
end

-- Start timer when messages exist
local function start_timer()
  if not timer then
    timer = uv.new_timer()
    timer:start(5000, 5000, vim.schedule_wrap(process_queue))
  end
end

function M.push(session, content)
  if not message_queue[session] then
    message_queue[session] = {}
  end

  table.insert(message_queue[session], content)
  -- Start timer when message arrives
  start_timer()
end

function M.pop(session)
  if not message_queue[session] or #message_queue[session] == 0 then
    return nil
  end
  return table.remove(message_queue[session], 1)
end

-- Optional: manual start (for backward compatibility)
function M.start()
  start_timer()
end

-- Cleanup
function M.stop()
  stop_timer()
end

return M
