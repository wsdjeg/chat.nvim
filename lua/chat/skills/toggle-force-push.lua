-- lua/chat/skills/toggle-force-push.lua
-- /toggle-force-push - Toggle force push protection for current session
--
-- When enabled, git_push with force=true will be rejected.
-- This is a session-level toggle, persisted with the session.
--
-- Usage:
--   /toggle-force-push   # Toggle on/off
--
-- State-type skill: notify the receipt, return nil. Returning the string
-- would append it to the session as an assistant message, duplicating the
-- same text in the result window.

local log = require('chat.log')

return {
  name = 'toggle-force-push',
  description = 'Toggle force push protection for current session',
  handler = function(_, ctx)
    local sessions = require('chat.sessions')
    local current = sessions.get_session_disable_force_push(ctx.session)
    sessions.set_session_disable_force_push(ctx.session, not current)
    log.notify(
      (not current) and 'Force push disabled for this session'
        or 'Force push enabled for this session'
    )
  end,
}

