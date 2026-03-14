local M = {}

local log = require('chat.log')
local tools = require('chat.tools')
local job = require('job')

---@class ChatMessage
---@field role string
---@field content string
---@field created integer

---@class ChatSession
---@field id string
---@field messages ChatMessage[]
---@field provider? string
---@field model? string
---@field cwd string session working directory

local cache_dir = vim.fn.stdpath('cache') .. '/chat.nvim/'
local progress_reasoning_contents = {} ---@type table<string, string>
local progress_finish_reasons = {} ---@type table<string, string>
local job_tool_calls = {} ---@type table<string, table>
local progress_usage = {} ---@type table<string, table>
--- @type table<string, ChatSession>
local sessions = {}
local jobid_session = {}
local progress_messages = {}

function M.write_cache(session)
  if not sessions[session] then
    log.error('session does not existed, skip writing cache.')
    return false
  end
  if vim.fn.isdirectory(cache_dir) == 0 then
    local ok, err = pcall(vim.fn.mkdir, cache_dir, 'p')
    if not ok then
      log.warn('failed to created cache directory, ' .. err)
      return
    end
  end
  local f_name = cache_dir .. session .. '.json'
  local file = io.open(f_name, 'w')
  if not file then
    log.error('Failed to open cache file: ' .. f_name)
    return false
  end
  local success, err = pcall(function()
    file:write(vim.json.encode(sessions[session]))
    io.close(file)
  end)
  if not success then
    log.error('Failed to write cache: ' .. err)
    return false
  end

  return true
end

function M.delete(session)
  local current_session = require('chat.windows').current_session()
  if not session then
    session = current_session
  end
  if not session then
    return
  end
  if M.is_in_progress(session) then
    M.cancel_progress(session)
  end
  local s = {}
  for id, _ in pairs(sessions) do
    table.insert(s, id)
  end
  table.sort(s)
  vim.fn.delete(cache_dir .. session .. '.json')
  sessions[session] = nil
  local memories = require('chat.memory').get_memories()

  for _, m in ipairs(memories) do
    if m.session == session then
      require('chat.memory').delete(m.id)
    end
  end

  require('chat.integrations').on_session_deleted(session)

  if current_session == session then
    for i = 1, #s do
      if s[i] == session then
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
  if not vim.tbl_isempty(sessions) then
    return sessions
  end
  local files = vim.fn.globpath(cache_dir, '*.json', false, true)
  for _, v in ipairs(files) do
    local file = io.open(v, 'r')
    if file then
      local context = file:read('*a')
      io.close(file)
      local ok, obj = pcall(vim.json.decode, context)
      if ok and obj ~= vim.NIL then
        -- 兼容老版本 session
        -- 如果没有 id key，说明是最老的版本直接是一组消息列表
        if not obj.id then
          obj.id = vim.fn.fnamemodify(v, ':t:r')
          obj = {
            id = obj.id,
            messages = obj,
            provider = require('chat.config').config.provider,
            model = require('chat.config').config.model,
            cwd = vim.fn.getcwd(),
          }
          sessions[obj.id] = obj
          M.write_cache(obj.id)
        end
        -- 检测完 id 后，如果有 id，但是 没有 cwd 选项
        -- 说明是 id 加上后到 cwd 加之前的版本。
        if not obj.cwd then
          obj.cwd = vim.fn.getcwd()
          sessions[obj.id] = obj
          M.write_cache(obj.id)
        end

        if not obj.prompt then
          obj.prompt = get_config_system_prompt()
          sessions[obj.id] = obj
          M.write_cache(obj.id)
        end

        sessions[obj.id] = obj
      end
    end
  end
  return sessions
end

---@param jobid integer
function M.on_progress_done(jobid)
  local session = M.get_progress_session(jobid)
  if progress_messages[session] then
    local reasoning_content
    if progress_reasoning_contents[session] then
      reasoning_content = progress_reasoning_contents[session]
      progress_reasoning_contents[session] = nil
    end
    M.append_message(session, {
      role = 'assistant',
      reasoning_content = reasoning_content,
      content = progress_messages[session],
      created = os.time(),
    })
    progress_messages[session] = nil
  else
    progress_reasoning_contents[session] = nil
    progress_messages[session] = nil
  end
  M.write_cache(session)
end

---@param id integer
---@param code integer
---@param signal integer
function M.on_progress_exit(id, code, signal)
  local session = M.get_progress_session(id)
  progress_reasoning_contents[session] = nil
  progress_messages[session] = nil
  jobid_session[id] = nil
end

---@return boolean
function M.is_in_progress(session)
  -- Check if there's an active job for this session
  for _, v in pairs(jobid_session) do
    if v == session then
      return true
    end
  end
  
  -- Also check if there are pending async tools
  if M.has_pending_async_tools(session) then
    return true
  end
  
  return false
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
    local windows = require('chat.windows')

    if session == windows.current_session() then
      if
        not progress_messages[session]
        and not progress_reasoning_contents[session]
      then
        windows.push_text({
          is_start = true,
          content = text,
        })
      else
        if not progress_messages[session] then
          windows.push_text({
            content = '\n\n' .. text,
          })
        else
          windows.push_text({
            content = text,
          })
        end
      end
    end

    progress_messages[session] = (progress_messages[session] or '') .. text
  end
end

function M.on_progress_reasoning_content(id, text)
  local session = jobid_session[id]
  if session then
    local windows = require('chat.windows')

    if session == windows.current_session() then
      if
        not progress_messages[session]
        and not progress_reasoning_contents[session]
      then
        windows.push_text({
          is_start = true,
          reasoning_content = text,
        })
      else
        windows.push_text({
          reasoning_content = text,
        })
      end
    end

    progress_reasoning_contents[session] = (
      progress_reasoning_contents[session] or ''
    ) .. text
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

function M.set_progress_usage(id, usage)
  progress_usage[id] = usage
end

function M.set_progress_finish_reason(id, reason)
  progress_finish_reasons[id] = reason
end

function M.get_progress_finish_reason(id)
  return progress_finish_reasons[id]
end

function M.get_progress_usage(id)
  return progress_usage[id]
end

function M.set_session_jobid(session, jobid)
  if jobid > 0 then
    jobid_session[jobid] = session
  end
end

function M.set_session_prompt(session, prompt)
  if type(prompt) ~= 'string' then
    return false
  end
  if not session then
    return false
  end

  if not sessions[session] then
    return false
  end

  sessions[session].prompt = prompt

  return true
end

function M.get_messages(session)
  local message = {}
  for _, m in ipairs(sessions[session].messages) do
    table.insert(message, {
      role = m.role,
      content = m.content,
      reasoning_content = m.reasoning_content,
      tool_calls = m.tool_calls,
      tool_call_id = m.tool_call_id,
      created = m.created,
      on_complete = m.on_complete,
      usage = m.usage,
      error = m.error,
      tool_call_state = m.tool_call_state,
    })
  end
  return message
end

function M.get_request_messages(session)
  local message = {}
  if sessions[session].prompt and #sessions[session].prompt > 0 then
    table.insert(message, {
      role = 'system',
      content = sessions[session].prompt,
    })
  end
  for _, m in ipairs(sessions[session].messages) do
    if vim.tbl_contains({ 'user', 'assistant', 'tool' }, m.role) then
      table.insert(message, {
        role = m.role,
        content = m.content,
        reasoning_content = m.reasoning_content,
        tool_calls = m.tool_calls,
        tool_call_id = m.tool_call_id,
      })
    end
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
    prompt = get_config_system_prompt(),
    cwd = vim.fs.normalize(vim.fn.getcwd()),
  }
  return id
end

function M.on_progress_tool_call(id, tool_call)
  job_tool_calls[id] = job_tool_calls[id] or {}

  -- Some streaming implementations may emit early deltas without index
  if tool_call.index == nil then
    return
  end

  local idx = tool_call.index + 1

  if not job_tool_calls[id][idx] then
    job_tool_calls[id][idx] = {
      id = tool_call.id,
      index = tool_call.index,
      type = tool_call.type,
      ['function'] = {
        name = nil,
        arguments = '',
      },
    }
  end

  local state = job_tool_calls[id][idx]

  -- function.name is not a delta, just overwrite when it appears
  if
    tool_call['function']
    and tool_call['function'].name ~= nil
    and tool_call['function'].name ~= vim.NIL
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

function M.on_progress_tool_call_done(id)
  local session = M.get_progress_session(id)
  local windows = require('chat.windows')
  local reasoning_content = progress_reasoning_contents[session]
  local content = progress_messages[session]
  local message = {
    role = 'assistant',
    reasoning_content = reasoning_content,
    content = content,
    tool_calls = job_tool_calls[id],
    created = os.time(),
    session = session,
  }

  progress_messages[session] = nil
  progress_reasoning_contents[session] = nil
  M.append_message(session, message)
  windows.on_tool_call_start(session, {
    role = message.role,
    tool_calls = message.tool_calls,
    created = message.created,
    session = session,
  })

  for _, tool_call in ipairs(job_tool_calls[id]) do
    local ok, arguments =
      pcall(vim.json.decode, tool_call['function'].arguments)
    if ok then
      local result = tools.call(tool_call['function'].name, arguments, {
        cwd = sessions[session].cwd,
        session = session,
        callback = function(result)
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
          M.append_message(session, tool_done_message)
          windows.on_tool_call_done(session, { tool_done_message })
          M.finish_async_tool(session, result.jobid)
        end,
      })
      if result.jobid then
        M.start_async_tool(session, result.jobid)
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
        M.append_message(session, tool_done_message)
        windows.on_tool_call_done(session, { tool_done_message })
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
      M.append_message(session, tool_done_message)
      log.info('failed to decode arguments, error is:' .. arguments)
      log.info('arguments is:' .. tool_call['function'].arguments)
      windows.on_tool_call_done(session, { tool_done_message })
    end
  end

  -- clear job_tool_calls by id
  job_tool_calls[id] = nil
end

function M.append_message(session, message)
  if
    message.role == 'assistant'
    and message.content
    and message.content ~= ''
  then
    require('chat.integrations').on_response(session, message.content)
  end
  table.insert(sessions[session].messages, message)
end

function M.exists(session)
  return sessions[session] ~= nil
end

function M.get_session_provider(session)
  return sessions[session].provider
end

function M.set_session_provider(session, provider)
  if M.is_in_progress(session) then
    require('chat.log').notify(
      'session is in progress, can not change provider.',
      'WarningMsg'
    )
    return
  end
  sessions[session].provider = provider
  -- when set provider, set_session_model function will be called too
  -- so, only need to update window title in model function
  return true
end

function M.get_session_model(session)
  return sessions[session].model
end

function M.set_session_model(session, model)
  if M.is_in_progress(session) then
    require('chat.log').notify(
      'session is in progress, can not change provider.',
      'WarningMsg'
    )
    return
  end
  sessions[session].model = model
  if session == require('chat.windows').current_session() then
    require('chat.windows').redraw_title()
  end
end

function M.getcwd(session)
  if sessions[session] and not sessions[session].cwd then
    sessions[session].cwd = vim.fn.getcwd()
  end
  return sessions[session].cwd
end

function M.change_cwd(session, cwd)
  local windows = require('chat.windows')
  sessions[session].cwd = cwd
  if session == windows.current_session() then
    windows.redraw_title()
  end
end

function M.clear(session)
  local windows = require('chat.windows')
  session = session or windows.current_session()

  if session and sessions[session] then
    if M.is_in_progress(session) then
      require('chat.log').notify({

        'session is in progress',
        'Press Ctrl-C to cancel before clear session',
      }, 'WarningMsg')

      return false
    else
      sessions[session].messages = {}
      M.write_cache(session)
      if session == windows.current_session() then
        windows.render_result_buf()
      end
      return true
    end
  end
end

--- Save current session to a specified file path
---@param session string session id
---@param filepath string target file path
---@return boolean success
function M.save_to_file(session, filepath)
  if not sessions[session] then
    log.error('Session does not exist: ' .. session)
    return false
  end

  filepath = vim.fs.normalize(vim.fn.fnamemodify(filepath, ':p'))

  -- Ensure parent directory exists
  local dir = vim.fn.fnamemodify(filepath, ':h')
  if vim.fn.isdirectory(dir) == 0 then
    local ok, err = pcall(vim.fn.mkdir, dir, 'p')
    if not ok then
      log.error('Failed to create directory: ' .. err)
      return false
    end
  end

  local file = io.open(filepath, 'w')
  if not file then
    log.error('Failed to open file: ' .. filepath)
    return false
  end

  local success, err = pcall(function()
    file:write(vim.json.encode(sessions[session]))
    io.close(file)
  end)

  if not success then
    log.error('Failed to write session: ' .. err)
    return false
  end

  log.notify('Session saved to:\n' .. filepath)
  return true
end

--- Load session from a specified file path
---@param filepath string source file path
---@return string|nil session_id
function M.load_from_file(filepath)
  filepath = vim.fs.normalize(vim.fn.fnamemodify(filepath, ':p'))

  if vim.fn.filereadable(filepath) == 0 then
    log.error('File not found: ' .. filepath)
    return nil
  end

  local file = io.open(filepath, 'r')
  if not file then
    log.error('Failed to open file: ' .. filepath)
    return nil
  end

  local content = file:read('*a')
  io.close(file)

  local ok, obj = pcall(vim.json.decode, content)
  if not ok or obj == vim.NIL then
    log.error('Invalid session file format: ' .. filepath)
    return nil
  end

  if not obj.messages or type(obj.messages) ~= 'table' then
    log.error('Invalid session: missing messages')
    return nil
  end

  -- Generate new session ID if already exists
  local session_id = obj.id
  if not session_id or sessions[session_id] then
    session_id = os.date('%Y-%m-%d-%H-%M-%S', os.time())
    obj.id = session_id
  end

  local config = require('chat.config')
  obj.provider = obj.provider or config.config.provider
  obj.model = obj.model or config.config.model
  obj.cwd = obj.cwd or vim.fs.normalize(vim.fn.getcwd())
  obj.prompt = obj.prompt or get_config_system_prompt()

  sessions[session_id] = obj
  M.write_cache(session_id)

  log.notify('Session loaded: ' .. session_id)
  return session_id
end

--- Share session to pastebin and return URL
---@param session string session id
function M.share(session)
  if not sessions[session] then
    log.error('Session does not exist: ' .. session)
    return nil
  end

  local content = vim.json.encode(sessions[session])

  -- Use paste.rs service (no API key required)
  local url = 'https://paste.rs'

  local stdout = {}
  local stderr = {}

  local jobid = job.start({
    'curl',
    '-s',
    '-w',
    '\n%{http_code}',
    '--data-binary',
    '@-',
    url,
  }, {
    on_stdout = function(id, data)
      for _, v in ipairs(data) do
        table.insert(stdout, v)
      end
    end,
    on_stderr = function(id, data)
      for _, v in ipairs(data) do
        table.insert(stderr, v)
      end
    end,
    on_exit = function(id, code, single)
      if code == 0 and single == 0 then
        local output = table.concat(stdout, '\n')
        -- Split response body and status code
        local result, http_code = output:match('^(.-)\n(%d+)$')

        if
          http_code
          and tonumber(http_code) >= 200
          and tonumber(http_code) < 300
        then
          result = vim.trim(result)
          vim.fn.setreg('+', result)
          log.notify(
            '✓ Session shared!\nURL: '
              .. result
              .. '\n(Copied to clipboard)'
          )
        else
          -- Log detailed error to runtime log, show simple message to user
          log.error(
            'Failed to share session (HTTP '
              .. (http_code or 'unknown')
              .. '): '
              .. (result or output)
          )
          log.notify(
            '✗ Failed to share session\nCheck chat.nvim runtime log',
            'ErrorMsg'
          )
        end
      else
        log.error(
          'Failed to share session: '
            .. (table.concat(stderr, '\n') or 'unknown error')
        )
        log.notify(
          '✗ Failed to share session\nCheck chat.nvim runtime log',
          'ErrorMsg'
        )
      end
    end,
  })
  job.send(jobid, content)
  job.send(jobid, nil)
end

--- Load session from URL
---@param url string URL to load from
---@return string|nil url
function M.load_from_url(url)
  -- Validate URL (must start with http:// or https://)
  if not url:match('^https?://') then
    log.error('Invalid URL, must start with http:// or https://')
    return
  end

  local result
  local ok, err

  if vim.fn.has('nvim-0.10') == 1 then
    local obj = vim
      .system({
        'curl',
        '-s',
        '-L', -- Follow redirects
        url,
      }, { text = true })
      :wait()

    ok = obj.code == 0
    if ok then
      result = obj.stdout
    else
      err = obj.stderr
    end
  else
    local cmd = string.format('curl -s -L %s', vim.fn.shellescape(url))
    result = vim.fn.system(cmd)
    ok = vim.v.shell_error == 0
    err = result
  end

  if not ok or not result or result == '' then
    log.error('Failed to load from URL: ' .. (err or 'unknown error'))
    return
  end

  -- Parse JSON
  local obj
  ok, err = pcall(vim.json.decode, result)
  if not ok or err == vim.NIL then
    log.error('Invalid session data from URL')
    return
  end
  obj = err -- The decoded object

  if not obj.messages or type(obj.messages) ~= 'table' then
    log.error('Invalid session: missing messages')
    return
  end

  local session_id = obj.id
  if not session_id or sessions[session_id] then
    session_id = os.date('%Y-%m-%d-%H-%M-%S', os.time())
    obj.id = session_id
  end

  local config = require('chat.config')
  obj.provider = obj.provider or config.config.provider
  obj.model = obj.model or config.config.model
  obj.cwd = obj.cwd or vim.fs.normalize(vim.fn.getcwd())
  obj.prompt = obj.prompt or get_config_system_prompt()

  sessions[session_id] = obj
  M.write_cache(session_id)

  log.notify('Session loaded from URL: ' .. session_id)
  return session_id
end

function M.on_complete(session, id)
  local usage = M.get_progress_usage(id)
  local message = {
    on_complete = true,
    usage = usage,
    created = os.time(),
  }
  M.append_message(session, message)
  M.write_cache(session)
  require('chat.windows').on_message(session, message)
end
function M.send_tool_results(session)
  local messages = M.get_request_messages(session)
  if messages[#messages].role == 'tool' then
    local protocol = require('chat.protocol')
    log.info('send tool_call results to server.')
    local jobid = protocol.request({
      session = session,
      messages = M.get_request_messages(session),
    })
    log.info('curl request jobid is ' .. jobid)
    if session == require('chat.windows').current_session() then
      require('chat.spinners').start()
    end
  end
end

local pending_async_tools = {}

function M.start_async_tool(session, jobid)
  pending_async_tools[session] = pending_async_tools[session] or {}
  table.insert(pending_async_tools[session], jobid)
end

function M.finish_async_tool(session, jobid)
  local pending = pending_async_tools[session]
  if pending then
    for i, id in ipairs(pending) do
      if id == jobid then
        table.remove(pending, i)
        break
      end
    end
    if #pending == 0 then
      pending_async_tools[session] = nil
      M.write_cache(session)
      M.send_tool_results(session)
    end
  end
end

function M.has_pending_async_tools(session)
  local pending = pending_async_tools[session]
  return pending and #pending > 0
end

M.get()

return M
