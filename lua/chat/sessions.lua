local sessions = {}

---@class chat.session
---@field id string
---@field messages table

local cache_dir = vim.fn.stdpath('cache') .. '/chat.nvim/'

function sessions.write_cache(session)
  if vim.fn.isdirectory(cache_dir) == 0 then
    vim.fn.mkdir(cache_dir, 'p')
  end
  local f_name = cache_dir .. session .. '.json'
  local file = io.open(f_name, 'w')
  if file then
    file:write(vim.json.encode(sessions[session]))
    io.close(file)
  end
end

function sessions.get()
  local files = vim.fn.globpath(cache_dir, '*.json')
  for _, v in ipairs(files) do
    local file = io.open(v, 'r')
    if file then
      local context = file:read('*a')
      io.close(file)
      local obj = vim.json.decode(context)
      sessions[vim.fn.fnamemodify(v, ':t:r')] = obj
    end
  end
end

function sessions.get_messages(session)
  return sessions[session]
end

function sessions.new()
  local NOTE_ID_STRFTIME_FORMAT = '%Y-%m-%d-%H-%M-%S'
  local id = os.date(NOTE_ID_STRFTIME_FORMAT, os.time())
  sessions[id] = {}

  return id, sessions[id]
end

return sessions
