local M = {}

local sessions = require('chat.sessions')

function M.request(opt)
  -- Fingerprint the request prefix before the provider builds the body.
  -- This is the single funnel every request passes through, so the cache
  -- probe sees all of them; a probe failure must never break the request.
  pcall(function()
    require('chat.sessions.cache_probe').begin_request(opt.session, opt.messages)
  end)

  local ok, provider = pcall(
    require,
    'chat.providers.' .. sessions.get_session_provider(opt.session)
  )
  if ok then
    local ok2, std =
      pcall(require, 'chat.protocol.' .. (provider.protocol or 'openai'))
    if ok2 then
      return provider.request({
        on_stdout = std.on_stdout,
        on_stderr = std.on_stderr,
        on_exit = std.on_exit,
        session = opt.session,
        messages = opt.messages,
      })
    end
  end
end

return M
