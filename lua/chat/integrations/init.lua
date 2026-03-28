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
}

---@class ChatIntegrationMessage
---@field content string message content
---@field session string session ID

-- 通用的消息处理函数
local function handle_message(integration, name, callback)
  return function(message)
    log.debug(string.format('[%s] %s', name, message.content))
    
    -- Discord 特殊处理：发送 typing 指示器
    if name == 'discord' then
      integration.send_typing(true)
    end
    
    -- 处理命令
    if message.content == '/session' then
      integration.set_session(require('chat.windows').current_session())
      return
    elseif message.content == '/clear' then
      local sessions = require('chat.sessions')
      local session = integration.current_session()
      if session and not sessions.is_in_progress(session) then
        sessions.clear(session)
        integration.send_message('session messages cleared!')
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
