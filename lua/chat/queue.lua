local M = {}

local id = -1

local message_queue = {}

function M.push(session, content)
  if not message_queue[session] then
    message_queue[session] = {}
  end

  table.insert(message_queue[session], content)
end

function M.pop(session)
  if not message_queue[session] or #message_queue[session] == 0 then
    return nil
  end
  return table.remove(message_queue[session], #message_queue[session])
end

function M.start()
  pcall(vim.fn.timer_stop, id)
  id = vim.fn.timer_start(5000, function(...)
    for session, _ in pairs(message_queue) do
      if not require('chat.sessions').is_in_progress(session) then
        require('chat.windows').send_message(session, M.pop(session))
      end
    end
  end, { ['repeat'] = -1 })
end

return M
