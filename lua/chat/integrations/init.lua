local M = {}

local log = require('chat.log')

-- 集成模块表
local integrations = {
  discord = require('chat.integrations.discord'),
  lark = require('chat.integrations.lark'),
  dingtalk = require('chat.integrations.dingtalk'),
  wecom = require('chat.integrations.wecom'),
  telegram = require('chat.integrations.telegram'),
  weixin = require('chat.integrations.weixin'),
  slack = require('chat.integrations.slack'),
}

---@class ChatIntegrationMessage
---@field content string message content
---@field session string session ID

-- Helper: parse and execute /session command
local function handle_session_command(integration, message)
  local arg = message.content:match('^/session%s+(.+)$')
  
  if not arg then
    -- /session without args: bind to current window session
    integration.set_session(require('chat.windows').current_session())
    return
  end
  
  -- Try to parse as number
  local num = tonumber(arg)
  if num then
    -- Bind by index
    local session_list = integration._session_list
    if session_list and session_list[num] then
      local session_id = session_list[num]
      integration.set_session(session_id)
      integration.send_message(string.format('Session bound: %d) %s', num, session_id))
    else
      integration.send_message('Invalid session number. Use /list to see available sessions.')
    end
  else
    -- Bind by session_id
    local sessions = require('chat.sessions')
    if sessions.exists(arg) then
      integration.set_session(arg)
      integration.send_message('Session bound: ' .. arg)
    else
      integration.send_message('Session not found: ' .. arg)
    end
  end
end

-- Helper: list sessions with optional filter
local function handle_list_command(integration, message)
  log.info('[Integration] handle_list_command called')
  local pattern = message.content:match('^/list%s+(.+)$')
  local sessions = require('chat.sessions')
  local all_sessions = sessions.get()
  local current = integration.current_session()
  
  log.debug(string.format('[Integration] pattern: %s, current: %s, sessions count: %d',
    pattern or 'nil', current or 'nil', vim.tbl_count(all_sessions)))
  
  -- Sort sessions by id (newest first)
  local sorted = {}
  for id, session in pairs(all_sessions) do
    table.insert(sorted, { id = id, session = session })
  end
  table.sort(sorted, function(a, b) return a.id > b.id end)
  -- Filter by pattern if provided
  local filtered = {}
  for _, item in ipairs(sorted) do
    if not pattern then
      table.insert(filtered, item)
    else
      -- Get first message content for search
      local first_msg = ''
      if item.session.messages and #item.session.messages > 0 then
        first_msg = item.session.messages[1].content or ''
      end
      
      -- Match against id, provider, model, and first message
      local search_str = string.format('%s %s %s %s', 
        item.id, 
        item.session.provider or '', 
        item.session.model or '',
        first_msg)
      if search_str:lower():match(pattern:lower()) then
        table.insert(filtered, item)
      end
    end
  end
  
  -- Store session list for /session <number>
  integration._session_list = {}
  for _, item in ipairs(filtered) do
    table.insert(integration._session_list, item.id)
  end
  
  -- Build output
  local lines = pattern 
    and { string.format('Sessions matching "%s":', pattern) }
    or { 'Available sessions:' }
  
  if #filtered == 0 then
    table.insert(lines, pattern and '  No matches found' or '  No sessions available')
  else
    -- Limit display to 10 sessions
    local display_count = math.min(#filtered, 10)
    for i = 1, display_count do
      local item = filtered[i]
      local marker = (item.id == current) and ' ✓' or ''
      local provider = item.session.provider or 'default'
      local model = item.session.model or 'default'
      
      -- Get first line of first message
      local title = ''
      if item.session.messages and #item.session.messages > 0 then
        local first_msg = item.session.messages[1].content or ''
        title = vim.split(first_msg, '\n')[1]
        -- Truncate if too long
        if #title > 50 then
          title = vim.fn.strcharpart(title, 0, 47) .. '...'
        end
      end
      
      table.insert(
        lines,
        string.format('  %d) %s (%s/%s)%s', i, item.id, provider, model, marker)
      )
      if title ~= '' then
        table.insert(lines, string.format('     %s', title))
      end
    end
    
    -- Show total count and hidden count
    table.insert(lines, string.format('Total: %d session(s)', #filtered))
    if #filtered > 10 then
      table.insert(lines, string.format('  (showing first 10, %d hidden)', #filtered - 10))
    end
    table.insert(lines, '')
  end
  
  local message_content = table.concat(lines, '\n')
  log.info(string.format('[Integration] Sending list message (%d bytes)', #message_content))
  integration.send_message(message_content)
end

-- 通用的消息处理函数
local function handle_message(integration, name, callback)
  return function(message)
    log.debug(string.format('[%s] %s', name, message.content))

    -- Discord 特殊处理：发送 typing 指示器
    if name == 'discord' then
      integration.send_typing(true)
    end

    -- 处理命令
    if message.content:match('^/session%s*') then
      handle_session_command(integration, message)
      return
    elseif message.content:match('^/list%s*') or message.content == '/list' then
      handle_list_command(integration, message)
      return
    elseif message.content == '/clear' then
      local sessions = require('chat.sessions')
      local session = integration.current_session()
      if session and not sessions.is_in_progress(session) then
        sessions.clear(session)
        integration.send_message('Session messages cleared!')
      end
      return
    elseif message.content == '/status' then
      local sessions = require('chat.sessions')
      local session = integration.current_session()
      if session then
        local provider = sessions.get_session_provider(session) or 'default'
        local model = sessions.get_session_model(session) or 'default'
        local cwd = sessions.getcwd(session) or vim.fn.getcwd()
        local in_progress = sessions.is_in_progress(session)
        local status = string.format(
          'Session: %s\nProvider: %s\nModel: %s\nCWD: %s\nStatus: %s',
          session,
          provider,
          model,
          cwd,
          in_progress and 'Processing' or 'Idle'
        )
        integration.send_message(status)
      else
        integration.send_message('No active session. Use /session to bind a session.')
      end
      return
    end

    -- 正常消息
    local session = integration.current_session()
    if session then
      callback({
        session = session,
        content = message.content,
      })
    end
  end
end

---@param callback fun(message:ChatIntegrationMessage)
function M.on_message(callback)
  for name, integration in pairs(integrations) do
    integration.connect(handle_message(integration, name, callback))
  end
end

---@param session string session ID
---@param content string message content
function M.on_response(session, content)
  if not content or type(content) ~= 'string' or content:match('^%s*$') then
    return
  end

  for _, integration in pairs(integrations) do
    if session == integration.current_session() then
      integration.send_message(content)
    end
  end
end

function M.set_session(bridge, session)
  local integration = integrations[bridge]
  if integration then
    integration.set_session(session)
  end
end

function M.on_session_deleted(session)
  for _, integration in pairs(integrations) do
    if session == integration.current_session() then
      integration.disconnect()
      integration.set_session(nil)
    end
  end
end

function M.get_integrations(session)
  local ins = {}
  for name, integration in pairs(integrations) do
    if session == integration.current_session() then
      table.insert(ins, name)
    end
  end
  return ins
end

return M

