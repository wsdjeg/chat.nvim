-- lua/chat/skills/disable-force-push.lua
-- /disable-force-push - Toggle force push protection for current session
--
-- When enabled, git_push with force=true will be rejected.
-- This is a session-level toggle, persisted with the session.
--
-- Usage:
--   /disable-force-push   # Toggle on/off

local log = require('chat.log')

return {
  name = 'disable-force-push',
  description = 'Toggle force push protection for current session',
  handler = function(_, ctx)
    local sessions = require('chat.sessions')
    local current = sessions.get_session_disable_force_push(ctx.session)
    sessions.set_session_disable_force_push(ctx.session, not current)
    local msg = (not current) and 'Force push disabled for this session'
      or 'Force push enabled for this session'
    log.notify(msg)
    return msg
  end,
}

