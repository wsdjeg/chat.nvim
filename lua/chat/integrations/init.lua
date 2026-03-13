local M = {}

local discord = require('chat.integrations.discord')
local lark = require('chat.integrations.lark')
local dingtalk = require('chat.integrations.dingtalk')
local wecom = require('chat.integrations.wecom')
local telegram = require('chat.integrations.telegram')
local log = require('chat.log')

---@class ChatIntegrationMessage
---@field content string message content
---@field session string session ID

---@param callback fun(message:ChatIntegrationMessage)
function M.on_message(callback)
  -- Discord
  discord.connect(function(message)
    log.debug('[Discord] ' .. message.content)
    if message.content == '/session' then
      discord.set_session(require('chat.windows').current_session())
      return
    elseif message.content == '/clear' then
      local sessions = require('chat.sessions')
      local session = discord.current_session()
      if session and not sessions.is_in_progress(session) then
        require('chat.sessions').clear(discord.current_session())
        discord.send_message('session messages cleared!')
      end
      return
    end
    if discord.current_session() then
      callback({
        session = discord.current_session(),
        content = message.content,
      })
    end
  end)

  -- Lark (Feishu)
  lark.connect(function(message)
    log.debug('[Lark] ' .. message.content)
    if message.content == '/session' then
      lark.set_session(require('chat.windows').current_session())
      return
    elseif message.content == '/clear' then
      local sessions = require('chat.sessions')
      local session = lark.current_session()
      if session and not sessions.is_in_progress(session) then
        require('chat.sessions').clear(lark.current_session())
        lark.send_message('session messages cleared!')
      end
      return
    end
    local session = lark.current_session()
    if session then
      callback({
        session = session,
        content = message.content,
      })
    end
  end)

  -- DingTalk
  dingtalk.connect(function(message)
    log.debug('[DingTalk] ' .. message.content)
    if message.content == '/session' then
      dingtalk.set_session(require('chat.windows').current_session())
      return
    elseif message.content == '/clear' then
      local sessions = require('chat.sessions')
      local session = dingtalk.current_session()
      if session and not sessions.is_in_progress(session) then
        require('chat.sessions').clear(dingtalk.current_session())
        dingtalk.send_message('session messages cleared!')
      end
      return
    end
    local session = dingtalk.current_session()
    if session then
      callback({
        session = session,
        content = message.content,
      })
    end
  end)

  -- WeCom (Enterprise WeChat)
  wecom.connect(function(message)
    log.debug('[WeCom] ' .. message.content)
    if message.content == '/session' then
      wecom.set_session(require('chat.windows').current_session())
      return
    elseif message.content == '/clear' then
      local sessions = require('chat.sessions')
      local session = wecom.current_session()
      if session and not sessions.is_in_progress(session) then
        require('chat.sessions').clear(wecom.current_session())
        wecom.send_message('session messages cleared!')
      end
      return
    end
    local session = wecom.current_session()
    if session then
      callback({
        session = session,
        content = message.content,
      })
    end
  end)

  -- Telegram
  telegram.connect(function(message)
    log.debug('[Telegram] ' .. message.content)
    if message.content == '/session' then
      telegram.set_session(require('chat.windows').current_session())
      return
    elseif message.content == '/clear' then
      local sessions = require('chat.sessions')
      local session = telegram.current_session()
      if session and not sessions.is_in_progress(session) then
        require('chat.sessions').clear(telegram.current_session())
        telegram.send_message('session messages cleared!')
      end
      return
    end
    local session = telegram.current_session()
    if session then
      callback({
        session = session,
        content = message.content,
      })
    end
  end)
end

---@param session string session ID
---@param content string message content
function M.on_response(session, content)
  if not content or type(content) ~= 'string' or content:match('^%s*$') then
    return
  end

  -- Check each IM independently, not with elseif
  if session == discord.current_session() then
    discord.send_message(content)
  end

  if session == lark.current_session() then
    lark.send_message(content)
  end

  if session == dingtalk.current_session() then
    dingtalk.send_message(content)
  end

  if session == wecom.current_session() then
    wecom.send_message(content)
  end

  if session == telegram.current_session() then
    telegram.send_message(content)
  end
end

function M.set_session(bridge, session)
  if bridge == 'discord' then
    discord.set_session(session)
  elseif bridge == 'lark' then
    lark.set_session(session)
  elseif bridge == 'dingtalk' then
    dingtalk.set_session(session)
  elseif bridge == 'wecom' then
    wecom.set_session(session)
  elseif bridge == 'telegram' then
    telegram.set_session(session)
  end
end

function M.on_session_deleted(session)
  if session == discord.current_session() then
    discord.disconnect()
  end

  if session == lark.current_session() then
    lark.disconnect()
  end

  if session == dingtalk.current_session() then
    dingtalk.disconnect()
  end

  if session == wecom.current_session() then
    wecom.disconnect()
  end

  if session == telegram.current_session() then
    telegram.disconnect()
  end
end

function M.get_integrations(session)
  local ins = {}

  -- Check each IM independently, not with elseif
  if session == discord.current_session() then
    table.insert(ins, 'discord')
  end

  if session == lark.current_session() then
    table.insert(ins, 'lark')
  end

  if session == dingtalk.current_session() then
    table.insert(ins, 'dingtalk')
  end

  if session == wecom.current_session() then
    table.insert(ins, 'wecom')
  end

  if session == telegram.current_session() then
    table.insert(ins, 'telegram')
  end
  return ins
end

return M
