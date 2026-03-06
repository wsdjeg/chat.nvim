local M = {}

local discord = require('chat.integrations.discord')
local log = require('chat.log')

---@class ChatIntegrationMessage
---@field content string message content
---@field session string session ID

---@param callback fun(message:ChatIntegrationMessage)
function M.on_message(callback)
  discord.connect(function(message)
    log.debug(message.content)
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
end

---@param session string session ID
---@param content string message content
function M.on_response(session, content)
  -- Validate message content before sending
  if not content or type(content) ~= 'string' or content:match('^%s*$') then
    return
  end

  if session == discord.current_session() then
    discord.send_message(content)
  end
end

function M.set_session(bridge, session)
  if bridge == 'discord' then
    discord.set_session(session)
  end
end

return M
