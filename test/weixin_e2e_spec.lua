-- End-to-end coverage for the WeChat (weixin) integration.
--
-- The chain under test is the one that broke in production ("AI replies no
-- longer reach WeChat, but inbound messages still arrive"):
--
--   long-poll getupdates
--     -> weixin poll callback
--       -> integrations.handle_message (session dispatch)
--         -> session.message callback
--           ... the AI turn runs ...
--             -> sessions.messages.append_message(assistant)
--               -> integrations.on_response(session, content)
--                 -> weixin.send_message(content)
--                   -> sendmessage job (chunked)
--
-- Every hop had a unit test already, but nothing verified them wired
-- together. No real WeChat login is involved: `job.intercept()` captures all
-- curl jobs so the spec drives every callback, and the credentials live in
-- the test config.

local lu = require('luaunit')
local job = require('job')
local config = require('chat.config')

-- chat.integrations caches the integration modules at require time, so it
-- must be reloaded together with them; otherwise on_response/on_message would
-- keep pointing at a stale weixin instance.
local RELOAD_MODS = {
  'chat.integrations',
  'chat.integrations.weixin',
  'chat.integrations.weixin.api',
  'chat.integrations.weixin.message',
  'chat.integrations.weixin.state',
  'chat.integrations.weixin.types',
  'chat.integrations.weixin.login',
}

local SID = 'wx-e2e-session'
local USER_ID = 'wx-user-1'
local CONTEXT_TOKEN = 'ctx-e2e'
local WECHAT_LIMIT = 2048

local function wait(ms)
  vim.wait(ms or 250, function()
    return false
  end, 20)
end

--- Job ids whose command line contains `fragment`, oldest first.
local function job_ids(fragment)
  local ids = {}
  for id, j in pairs(job.jobs) do
    if table.concat(j.cmd, ' '):find(fragment, 1, true) then
      ids[#ids + 1] = id
    end
  end
  table.sort(ids)
  return ids
end

local function find_job(fragment)
  return job_ids(fragment)[1]
end

--- Text carried by a sendmessage job.
local function sent_text(jobid)
  local body = vim.json.decode(job.jobs[jobid].stdin[1])
  return body.msg.item_list[1].text_item.text
end

--- One inbound user message as returned by the getupdates endpoint.
local function inbound(text)
  local Types = require('chat.integrations.weixin.types')
  return {
    message_id = 'in-' .. text:gsub('%s+', '-'),
    from_user_id = USER_ID,
    to_user_id = 'wx-bot',
    context_token = CONTEXT_TOKEN,
    message_type = Types.MessageType.USER,
    message_state = Types.MessageState.FINISH,
    item_list = {
      {
        type = Types.MessageItemType.TEXT,
        text_item = { text = text },
      },
    },
  }
end

--- Deliver a getupdates response to the pending long-poll job.
local function feed_update(jobid, msgs, buf)
  job.emit_stdout(jobid, vim.json.encode({
    ret = 0,
    get_updates_buf = buf or 'buf-next',
    msgs = msgs,
  }))
end

-- ═════════════════════ Weixin end-to-end ═════════════════════

TestWeixinE2E = {}

function TestWeixinE2E:setUp()
  job.reset()
  job.intercept()

  self.storage = vim.fn.tempname() .. '_wxe2e/'
  vim.fn.mkdir(self.storage, 'p')

  -- Other spec files capture these module tables at load time (e.g.
  -- windows_extra_spec stubs chat.integrations.on_message on the table it
  -- required). Reloading them here would leave package.loaded pointing at a
  -- fresh table, so the original references must be restored in tearDown.
  self.saved_loaded = {}
  for _, m in ipairs(RELOAD_MODS) do
    self.saved_loaded[m] = package.loaded[m]
    package.loaded[m] = nil
  end

  config.setup({
    storage_dir = self.storage,
    allowed_path = vim.fn.getcwd(),
    memory = { enable = false },
    integrations = {
      weixin = { token = 'wx-e2e-token', default_user_id = 'wx-bot' },
    },
  })

  -- Isolate session storage: the cache dir is derived from storage_dir once,
  -- at module load, so point it at the temp dir and start from an empty table.
  local storage = require('chat.sessions.storage')
  storage.set_cache_dir(self.storage .. 'sessions/')
  storage.sessions[SID] = {
    id = SID,
    messages = {},
    cwd = vim.fn.getcwd(),
    provider = 'test-provider',
    model = 'test-model',
  }

  self.ims = require('chat.integrations')
  self.wx = require('chat.integrations.weixin')
  self.messages = require('chat.sessions.messages')
  self.log = require('chat.log')
  self.orig_warn = self.log.warn

  self.wx.set_session(SID)

  -- Mirror the real startup path: on_message installs the shared
  -- handle_message wrapper (session lookup, /commands, typing timer) in front
  -- of each integration's callback.
  self.received = {}
  self.ims.on_message(function(msg)
    table.insert(self.received, msg)
  end)
  wait(300) -- let the long-poll job start
end

function TestWeixinE2E:tearDown()
  self.log.warn = self.orig_warn
  self.ims.unbridge_session(SID)
  self.wx.disconnect()
  wait(100)
  job.intercept(false)
  require('chat.sessions.storage').sessions[SID] = nil
  vim.fn.delete(self.storage, 'rf')

  -- Hand the pre-test module tables back: other spec files stubbed methods on
  -- those exact tables, and windows.lua re-requires chat.integrations.
  for _, m in ipairs(RELOAD_MODS) do
    package.loaded[m] = self.saved_loaded[m]
  end
end

--- Deliver one inbound message so the integration learns the reply routing:
--- context_token and last_from_user_id both come from the inbound payload.
--- Sending before that is a genuine error path, covered separately below.
function TestWeixinE2E:seed_context()
  local poll_id = find_job('getupdates')
  lu.assertNotNil(poll_id, 'long-poll job started')
  feed_update(poll_id, { inbound('seed') })
  wait(300)
  self.received = {}
end

--- Inbound poll -> session callback -> AI reply -> sendmessage job.
function TestWeixinE2E:test_inbound_then_ai_reply_reaches_wechat()
  local poll_id = find_job('getupdates')
  lu.assertNotNil(poll_id, 'long-poll job started')

  feed_update(poll_id, { inbound('hello weixin') }, 'buf-1')
  wait(300)

  lu.assertEquals(1, #self.received, 'inbound delivered exactly once')
  lu.assertEquals(SID, self.received[1].session, 'bound session dispatched')
  lu.assertEquals('hello weixin', self.received[1].content)

  -- The AI turn completes. append_message is the only place assistant text is
  -- announced to integrations, which is exactly what regressed before.
  self.messages.append_message(SID, {
    role = 'assistant',
    content = 'reply from AI',
    created = os.time(),
  })
  wait(200)

  local ids = job_ids('sendmessage')
  lu.assertEquals(1, #ids, 'one sendmessage job for the reply')

  local body = vim.json.decode(job.jobs[ids[1]].stdin[1])
  lu.assertEquals(USER_ID, body.msg.to_user_id, 'replies to the sender')
  lu.assertEquals(
    CONTEXT_TOKEN,
    body.msg.context_token,
    'reuses the inbound context token'
  )
  lu.assertEquals('reply from AI', sent_text(ids[1]))

  job.emit_stdout(ids[1], { '{"ret":0}' })
  wait(150)
  lu.assertEquals(1, #job_ids('sendmessage'), 'success is not retried')
end

--- Sending before any inbound message has no context_token: the API rejects
--- the attempt synchronously and no HTTP job is created. This is the guard
--- that keeps a half-configured integration from spraying curl jobs.
function TestWeixinE2E:test_reply_without_context_token_sends_nothing()
  lu.assertNil(
    require('chat.integrations.weixin.state').get_context_token(USER_ID),
    'no context token before an inbound message'
  )

  self.wx.send_message('no token yet')
  wait(200)

  lu.assertEquals(0, #job_ids('sendmessage'), 'no job without context_token')
end

--- A reply longer than the WeChat limit is chunked into sequential sends.
function TestWeixinE2E:test_long_reply_is_chunked_into_sequential_sends()
  self:seed_context()

  -- No whitespace, so the chunker hard-splits at the limit: the pieces
  -- reassemble byte-for-byte into the original reply.
  local long = string.rep('x', WECHAT_LIMIT * 2 + 904)

  self.messages.append_message(SID, {
    role = 'assistant',
    content = long,
    created = os.time(),
  })
  wait(200)

  lu.assertEquals(1, #job_ids('sendmessage'), 'only one chunk in flight')

  -- Each successful send dequeues the next chunk (queued via vim.schedule).
  for i = 1, 2 do
    local ids = job_ids('sendmessage')
    lu.assertEquals(i, #ids, 'chunk ' .. i .. ' is the one in flight')
    job.emit_stdout(ids[#ids], { '{"ret":0}' })
    wait(200)
  end

  local ids = job_ids('sendmessage')
  lu.assertEquals(3, #ids, 'all three chunks sent')

  local texts = {}
  for _, id in ipairs(ids) do
    texts[#texts + 1] = sent_text(id)
  end
  lu.assertEquals(WECHAT_LIMIT, #texts[1])
  lu.assertEquals(WECHAT_LIMIT, #texts[2])
  lu.assertEquals(904, #texts[3])
  lu.assertEquals(long, table.concat(texts), 'chunks reassemble the reply')

  -- One more completion must not spawn a fourth job.
  job.emit_stdout(ids[#ids], { '{"ret":0}' })
  wait(150)
  lu.assertEquals(3, #job_ids('sendmessage'), 'queue is drained')
end

--- Replies are only pushed for the session bound to the integration.
function TestWeixinE2E:test_reply_for_unbound_session_is_not_sent()
  self:seed_context()
  self.wx.set_session(nil)

  self.messages.append_message(SID, {
    role = 'assistant',
    content = 'should stay local',
    created = os.time(),
  })
  wait(200)

  lu.assertEquals(0, #job_ids('sendmessage'), 'unbound session sends nothing')
end

--- The outbound queue is capped; overflow is dropped with a warning.
function TestWeixinE2E:test_queue_overflow_is_dropped()
  self:seed_context()

  local warnings = {}
  self.log.warn = function(msg)
    warnings[#warnings + 1] = tostring(msg)
  end

  -- One message goes straight into the in-flight job; MAX_QUEUE_SIZE more
  -- fill the queue; the rest overflow.
  for _ = 1, 102 do
    self.wx.send_message('a')
  end

  local dropped = false
  for _, w in ipairs(warnings) do
    if w:find('Message queue full', 1, true) then
      dropped = true
    end
  end
  lu.assertTrue(dropped, 'overflow dropped with a warning')
  lu.assertEquals(1, #job_ids('sendmessage'), 'sends stay sequential')
end

return TestWeixinE2E

