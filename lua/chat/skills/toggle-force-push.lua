-- lua/chat/skills/toggle-force-push.lua
-- /toggle-force-push - Toggle force push protection for current session
--
-- When enabled, git_push with force=true will be rejected.
-- This is a session-level toggle, persisted with the session.
--
-- Usage:
--   /toggle-force-push   # Toggle on/off
--
-- State-type skill: the receipt goes through skills.notify(ctx, ...), which
-- shows a transient popup for a local invocation of the session on screen and
-- stays silent for remote callers. notify() always returns nil, so nothing is
-- ever appended to the message list.

local skills = require('chat.skills')

return {
  name = 'toggle-force-push',
  description = 'Toggle force push protection for current session',
  handler = function(_, ctx)
    local sessions = require('chat.sessions')
    local current = sessions.get_session_disable_force_push(ctx.session)
    sessions.set_session_disable_force_push(ctx.session, not current)
    return skills.notify(
      ctx,
      (not current) and 'Force push disabled for this session'
        or 'Force push enabled for this session'
    )
  end,
}

