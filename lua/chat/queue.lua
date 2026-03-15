local M = {}

local id = -1
local timer_running = false
local message_queue = {}

-- Stop timer when no messages
local function stop_timer()
  if timer_running then
    pcall(vim.fn.timer_stop, id)
    timer_running = false
  end
end

-- Start timer when messages exist
local function start_timer()
  if not timer_running then
    timer_running = true
    id = vim.fn.timer_start(5000, function()
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
    end, { ['repeat'] = -1 })
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
  return table.remove(message_queue[session], #message_queue[session])
end

-- Optional: manual start (for backward compatibility)
function M.start()
  start_timer()
end

return M
