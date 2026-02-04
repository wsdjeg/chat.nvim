local sessions = {}

---@class chat.session
---@field id string
---@field messages table

local cache_dir = vim.fn.stdpath('cache') .. '/chat.nvim/'

local M = {}

function M.write_cache(session)
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

function M.delete(session)
  vim.fn.delete(cache_dir .. session .. '.json')
  sessions[session] = nil
end

function M.get()
  local files = vim.fn.globpath(cache_dir, '*.json', 0, 1)
  for _, v in ipairs(files) do
    local file = io.open(v, 'r')
    if file then
      local context = file:read('*a')
      io.close(file)
      local obj = vim.json.decode(context)
      sessions[vim.fn.fnamemodify(v, ':t:r')] = obj
    end
  end
  return sessions
end

local jobid_session = {}

-- 以 session 为 key，存储未完成的消息
local progress_messages = {}

---@param jobid integer
---@return string
function M.on_progress_done(jobid, code, single)
  local session = M.get_progress_session(jobid)
  if code == 0 and single == 0 then
    table.insert(sessions[session], {
      role = 'assistant',
      content = progress_messages[session],
    })
    progress_messages[session] = nil
    jobid_session[jobid] = nil
    M.write_cache(session)
  else
    progress_messages[session] = nil
    jobid_session[jobid] = nil
  end
end

function M.is_in_progress(session)
  for _, v in pairs(jobid_session) do
    if v == session then
      return true
    end
  end
end

function M.cancel_progress(session)
  for jobid, v in pairs(jobid_session) do
    if v == session then
      -- 1. Ctrl-C 对应的信号
      --
      -- 在类 Unix 系统里：
      --
      -- 操作	信号名称	信号编号
      -- Ctrl-C	SIGINT	2
      -- kill -9	SIGKILL	9
      -- kill -15	SIGTERM	15
      --
      -- 所以，按 Ctrl-C 会发送 SIGINT，它对应的 数字是 2。
      require('job').stop(jobid, 2)
    end
  end
end

-- 不处理 role，AI 回复的 message role 都是 assistant
function M.on_progress(id, text)
  local session = jobid_session[id]
  if session then
    progress_messages[session] = (progress_messages[session] or '') .. text
  end
end

function M.get_progress_message(session)
  return progress_messages[session]
end

function M.get_progress_session(id)
  return jobid_session[id]
end

function M.set_session_jobid(session, jobid)
  if jobid > 0 then
    jobid_session[jobid] = session
  end
end

function M.get_messages(session)
  return sessions[session] or {}
end

function M.new()
  local NOTE_ID_STRFTIME_FORMAT = '%Y-%m-%d-%H-%M-%S'
  local id = os.date(NOTE_ID_STRFTIME_FORMAT, os.time())
  sessions[id] = {}

  return id, sessions[id]
end

return M
