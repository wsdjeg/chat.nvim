-- Session core: create, delete, switch, clear
local M = {}

local log = require('chat.log')
local storage = require('chat.sessions.storage')

local function get_config_system_prompt()
  local config = require('chat.config')
  local prompt = config.config.system_prompt

  if type(prompt) == 'function' then
    local ok, result = pcall(prompt)
    if ok then
      if type(result) == 'string' then
        return result
      else
        log.warn(
          'system_prompt function should return string, got ' .. type(result)
        )
        return tostring(result or '')
      end
    else
      log.warn(
        string.format('Failed to call system_prompt function: %s', result)
      )
      return ''
    end
  end

  return prompt or ''
end

function M.get()
  if not vim.tbl_isempty(storage.sessions) then
    return storage.sessions
  end
  for _ in require('chat.sessions.storage').iter_sessions() do
  end
  return storage.sessions
end

function M.new()
  local NOTE_ID_STRFTIME_FORMAT = '%Y-%m-%d-%H-%M-%S'
  local id = os.date(NOTE_ID_STRFTIME_FORMAT, os.time())
  local config = require('chat.config')
  storage.sessions[id] = {
    id = id,
    messages = {},
    provider = config.config.provider,
    model = config.config.model,
    prompt = get_config_system_prompt(),
    cwd = vim.fs.normalize(vim.fn.getcwd()),
  }
  return id
end

function M.delete(session_id)
  local current_session = require('chat.windows').current_session()
  if not session_id then
    session_id = current_session
  end
  if not session_id then
    return
  end

  -- Check if session is in progress
  local progress = require('chat.sessions.progress')
  if progress.is_in_progress(session_id) then
    progress.cancel_progress(session_id)
  end

  local s = {}
  for id, _ in pairs(storage.sessions) do
    table.insert(s, id)
  end
  table.sort(s)

  vim.fn.delete(storage.cache_dir or (vim.fn.stdpath('cache') .. '/chat.nvim/') .. session_id .. '.json')
  storage.sessions[session_id] = nil

  local memories = require('chat.memory').get_memories()
  for _, m in ipairs(memories) do
    if m.session == session_id then
      require('chat.memory').delete(m.id)
    end
  end

  require('chat.integrations').on_session_deleted(session_id)

  if current_session == session_id then
    for i = 1, #s do
      if s[i] == session_id then
        if i == #s then
          return M.new()
        else
          return s[i + 1]
        end
      end
    end
  end
end

function M.previous()
  local s = {}
  for session, _ in pairs(storage.sessions) do
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
  for session, _ in pairs(storage.sessions) do
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

function M.exists(session_id)
  return storage.sessions[session_id] ~= nil
end

function M.clear(session_id)
  local windows = require('chat.windows')
  session_id = session_id or windows.current_session()

  if session_id and storage.sessions[session_id] then
    local progress = require('chat.sessions.progress')
    if progress.is_in_progress(session_id) then
      log.notify({
        'session is in progress',
        'Press Ctrl-C to cancel before clear session',
      }, 'WarningMsg')
      return false
    else
      storage.sessions[session_id].messages = {}
      storage.sessions[session_id].usage = {
        total_tokens = 0,
        prompt_tokens = 0,
        completion_tokens = 0,
      }
      require('chat.sessions.storage').write_cache(session_id)
      if session_id == windows.current_session() then
        windows.render_result_buf()
        windows.set_result_win_title(' chat.nvim ')
      end
      return true
    end
  end
end

function M.set_session_prompt(session_id, prompt)
  if type(prompt) ~= 'string' then
    return false
  end
  if not session_id then
    return false
  end
  if not storage.sessions[session_id] then
    return false
  end
  storage.sessions[session_id].prompt = prompt
  return true
end

function M.get_session_provider(session_id)
  return storage.sessions[session_id].provider
end

function M.set_session_provider(session_id, provider)
  local progress = require('chat.sessions.progress')
  if progress.is_in_progress(session_id) then
    log.notify(
      'session is in progress, can not change provider.',
      'WarningMsg'
    )
    return
  end
  storage.sessions[session_id].provider = provider
  return true
end

function M.get_session_model(session_id)
  return storage.sessions[session_id].model
end

function M.set_session_model(session_id, model)
  local progress = require('chat.sessions.progress')
  if progress.is_in_progress(session_id) then
    log.notify(
      'session is in progress, can not change provider.',
      'WarningMsg'
    )
    return
  end
  storage.sessions[session_id].model = model
  if session_id == require('chat.windows').current_session() then
    require('chat.windows').redraw_title()
  end
end

function M.getcwd(session_id)
  if storage.sessions[session_id] and not storage.sessions[session_id].cwd then
    storage.sessions[session_id].cwd = vim.fn.getcwd()
  end
  return storage.sessions[session_id].cwd
end

function M.change_cwd(session_id, cwd)
  local windows = require('chat.windows')
  storage.sessions[session_id].cwd = cwd
  if session_id == windows.current_session() then
    windows.redraw_title()
  end
end

function M.get_total_tokens(session_id)
  local session = storage.sessions[session_id]
  if not session then
    return 0, 0, 0
  end

  if not session.usage then
    local total = 0
    local prompt = 0
    local completion = 0
    for _, msg in ipairs(session.messages) do
      if msg.usage then
        total = total + (msg.usage.total_tokens or 0)
        prompt = prompt + (msg.usage.prompt_tokens or 0)
        completion = completion + (msg.usage.completion_tokens or 0)
      end
    end
    session.usage = {
      total_tokens = total,
      prompt_tokens = prompt,
      completion_tokens = completion,
    }
  end

  return session.usage.total_tokens,
    session.usage.prompt_tokens,
    session.usage.completion_tokens
end

return M

