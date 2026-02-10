local sessions = {}

-- 保存请求返回的 reasoning_content

local progress_reasoning_contents = {}

local tools = require('chat.tools')

---@class ChatMessage
---@field role string
---@field content string
---@field created integer

---@class ChatSession
---@field id string
---@field messages table<ChatMessage>
---@field provider? string
---@field model? string

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

function M.previous()
  local s = {}
  for session, _ in pairs(sessions) do
    table.insert(s, session)
  end
  table.sort(s)
  local current_session = require('chat.windows').current_session()
  if not current_session then
    return s[#s] or M.new()
  else
    for i = 1, #s do
      if s[i] == current_session then
        if i == 1 then
          return s[#s]
        else
          return s[i - 1]
        end
      end
    end
  end
end

function M.next()
  local s = {}
  for session, _ in pairs(sessions) do
    table.insert(s, session)
  end
  table.sort(s)
  local current_session = require('chat.windows').current_session()
  if not current_session then
    return s[1] or M.new()
  else
    for i = 1, #s do
      if s[i] == current_session then
        if i == #s then
          return s[1]
        else
          return s[i + 1]
        end
      end
    end
  end
end

function M.get()
  if not vim.tbl_isempty(sessions) then
    return sessions
  end
  local files = vim.fn.globpath(cache_dir, '*.json', false, true)
  for _, v in ipairs(files) do
    local file = io.open(v, 'r')
    if file then
      local context = file:read('*a')
      io.close(file)
      local obj = vim.json.decode(context)
      -- 兼容老版本 session
      if not obj.id then
        sessions[vim.fn.fnamemodify(v, ':t:r')] = {
          id = vim.fn.fnamemodify(v, ':t:r'),
          messages = obj,
          provider = require('chat.config').config.provider,
          model = require('chat.config').config.model,
        }
      else
        sessions[vim.fn.fnamemodify(v, ':t:r')] = obj
      end
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
  if code == 0 and single == 0 and progress_messages[session] then
    local reasoning_content
    if progress_reasoning_contents[session] then
      reasoning_content = progress_reasoning_contents[session]
      progress_reasoning_contents[session] = nil
    end
    M.append_message(session, {
      role = 'assistant',
      reasoning_content = reasoning_content,
      content = progress_messages[session],
      create = os.time(),
    })
    progress_messages[session] = nil
    jobid_session[jobid] = nil
    M.write_cache(session)
  else
    progress_reasoning_contents[session] = nil
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

function M.on_progress_reasoning_content(id, reasoning_content)
  local session = jobid_session[id]
  if session then
    progress_reasoning_contents[session] = (
      progress_reasoning_contents[session] or ''
    ) .. reasoning_content
  end
end

function M.get_progress_message(session)
  return progress_messages[session]
end

function M.get_progress_reasoning_content(session)
  return progress_reasoning_contents[session]
end

function M.get_progress_session(id)
  return jobid_session[id]
end

local progress_usage = {}

function M.set_progress_usage(id, usage)
  progress_usage[id] = usage
end

function M.get_progress_usage(id)
  return progress_usage[id]
end

function M.set_session_jobid(session, jobid)
  if jobid > 0 then
    jobid_session[jobid] = session
  end
end

function M.get_messages(session)
  local message = {}
  for _, m in ipairs(sessions[session].messages) do
    table.insert(message, {
      role = m.role,
      content = m.content,
      reasoning_content = m.reasoning_content,
      tool_calls = m.tool_calls,
    })
  end
  return message
end

function M.new()
  local NOTE_ID_STRFTIME_FORMAT = '%Y-%m-%d-%H-%M-%S'
  local id = os.date(NOTE_ID_STRFTIME_FORMAT, os.time())
  local config = require('chat.config')
  sessions[id] = {
    id = id,
    messages = {},
    provider = config.config.provider,
    model = config.config.model,
  }
  return id
end

--
-- ```json
-- {
--   "tool_calls": [
--     {
--       "id": "unique_call_id_1",
--       "type": "function",
--       "function": {
--         "name": "function_name",
--         "arguments": "{ \"arg1\": \"value1\", \"arg2\": 2 }" // arguments 字段是字符串格式的 JSON 参数
--       }
--     },
--     {
--       "id": "unique_call_id_2",
--       "type": "function",
--       "function": {
--         "name": "another_function",
--         "arguments": "{ \"param\": \"foo\" }"
--       }
--     }
--   ]
-- }
-- ```

local tool_calls = {}

function M.on_progress_tool_call(id, tool_call)
  if not tool_calls[id] then
    tool_calls[id] = tool_call
  else
    tool_calls[id]['function'].arguments = tool_calls[id]['function'].arguments
      .. tool_call['function'].arguments
  end
end

function M.on_progress_tool_call_done(id)
  local session = M.get_progress_session(id)
  local windows = require('chat.windows')
  local tool_call = tool_calls[id]
  local ok, arguments =
    pcall(vim.json.decode, tool_call['function'].arguments)
  if ok then
    windows.on_tool_call_start(session, tool_call['function'].name)
    local result = tools.call(tool_call['function'].name, arguments)
    if result.error then
      windows.on_tool_call_error(session, result.error)
      M.append_message(session, {
        role = 'assistant',
        reasoning_content = progress_reasoning_contents[session],
        tool_calls = {
          tool_call,
        },
      })
      progress_reasoning_contents[session] = nil
      M.append_message(session, {
        role = 'tool',
        content = 'tool_call run failed, error is: \n' .. result.error,
        tool_call_id = tool_call.id,
      })
      windows.on_tool_call_done(
        session,
        tool_call['function'].name,
        result.error
      )
    else
      M.append_message(session, {
        role = 'assistant',
        reasoning_content = progress_reasoning_contents[session],
        tool_calls = {
          tool_call,
        },
      })
      progress_reasoning_contents[session] = nil
      M.append_message(session, {
        role = 'tool',
        content = result.content,
        tool_call_id = tool_call.id,
      })
      windows.on_tool_call_done(session, tool_call['function'].name)
    end
  else
    print(arguments)
  end
end

function M.append_message(session, message)
  table.insert(sessions[session].messages, message)
end

function M.get_session_provider(session)
  return sessions[session].provider
end

function M.set_session_provider(session, provider)
  sessions[session].provider = provider
  -- when set provider, set_session_model function will be called too
  -- so, only need to update window title in model function
end

function M.get_session_model(session)
  return sessions[session].model
end

function M.set_session_model(session, model)
  sessions[session].model = model
  if session == require('chat.windows').current_session() then
    require('chat.windows').redraw_title()
  end
end

M.get()

return M
