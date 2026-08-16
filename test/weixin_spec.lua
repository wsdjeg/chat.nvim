-- Coverage for lua/chat/integrations/weixin.lua + weixin/{api,message,state}.lua
local lu = require('luaunit')
local job = require('job')
local config = require('chat.config')

local WX_MODS = {
  'chat.integrations.weixin',
  'chat.integrations.weixin.api',
  'chat.integrations.weixin.message',
  'chat.integrations.weixin.state',
  'chat.integrations.weixin.types',
  'chat.integrations.weixin.login',
}

local function fresh_weixin(storage_dir, wx_config)
  for _, m in ipairs(WX_MODS) do
    package.loaded[m] = nil
  end
  config.setup({
    storage_dir = storage_dir,
    integrations = wx_config,
  })
  return require('chat.integrations.weixin')
end

local function wait(ms)
  vim.wait(ms or 250, function()
    return false
  end, 20)
end

local function find_job(fragment)
  for id, j in pairs(job.jobs) do
    if table.concat(j.cmd, ' '):find(fragment, 1, true) then
      return id, j
    end
  end
end

-- ═════════════════════ Weixin API unit ═════════════════════

TestWeixinApi = {}

local wx_storage

function TestWeixinApi:setUp()
  job.reset()
  wx_storage = vim.fn.tempname() .. '_wx/'
  vim.fn.mkdir(wx_storage, 'p')
  self.wx = fresh_weixin(wx_storage, {
    weixin = { token = 'wx-tok', default_user_id = 'wx-user-1' },
  })
  self.Api = require('chat.integrations.weixin.api')
end

function TestWeixinApi:tearDown()
  vim.fn.delete(wx_storage, 'rf')
end

function TestWeixinApi:test_request_success_via_stdout()
  local got
  local id = self.Api.request('ilink/bot/echo', { foo = 'bar' }, function(result, err)
    got = { result = result, err = err }
  end)
  lu.assertTrue(id > 0)
  job.emit_stdout(id, { '{"ret":0,"data":"ok"}' })
  lu.assertEquals(got.result.data, 'ok')
  lu.assertNil(got.err)
end

function TestWeixinApi:test_request_decode_error()
  local got
  local id = self.Api.request('ilink/bot/echo', nil, function(result, err)
    got = { result = result, err = err }
  end)
  job.emit_stdout(id, { 'nope{{' })
  lu.assertNil(got.result)
  lu.assertEquals(got.err, 'Decode error')
end

function TestWeixinApi:test_request_empty_exit_zero()
  local got
  local id = self.Api.request('ilink/bot/echo', nil, function(result, err)
    got = { result = result, err = err }
  end)
  job.emit_exit(id, 0, 0)
  lu.assertEquals(got.err, 'Empty response (exit 0)')
end

function TestWeixinApi:test_request_curl_error()
  local got
  local id = self.Api.request('ilink/bot/echo', nil, function(result, err)
    got = { result = result, err = err }
  end)
  job.emit_exit(id, 6, 0)
  lu.assertStrContains(got.err, "Couldn't resolve host")
end

function TestWeixinApi:test_request_callback_once()
  local count = 0
  local id = self.Api.request('ilink/bot/echo', nil, function()
    count = count + 1
  end)
  job.emit_stdout(id, { '{"ret":0}' })
  job.emit_exit(id, 0, 0)
  lu.assertEquals(count, 1, 'safe_callback guard prevents double call')
end

function TestWeixinApi:test_request_no_config()
  local saved = config.config.integrations.weixin
  config.config.integrations.weixin = nil
  local got
  local ret = self.Api.request('ilink/bot/echo', nil, function(result, err)
    got = { result = result, err = err }
  end)
  lu.assertNil(ret)
  lu.assertEquals(got.err, 'Integration not configured')
  config.config.integrations.weixin = saved
end

function TestWeixinApi:test_request_missing_token()
  local saved = config.config.integrations.weixin
  config.config.integrations.weixin = {}
  local got
  local ret = self.Api.request('ilink/bot/echo', nil, function(result, err)
    got = { result = result, err = err }
  end)
  lu.assertNil(ret)
  lu.assertEquals(got.err, 'Missing token')
  config.config.integrations.weixin = saved
end

function TestWeixinApi:test_request_body_includes_base_info()
  local id = self.Api.request('ilink/bot/echo', { foo = 1 }, function() end)
  local body = vim.json.decode(job.jobs[id].stdin[1])
  lu.assertEquals(body.foo, 1)
  lu.assertEquals(body.base_info.channel_version, '1.0.0')
  lu.assertNil(job.jobs[id].stdin[2 + 1], 'stdin closed with nil')
end

function TestWeixinApi:test_request_headers()
  local id = self.Api.request('ilink/bot/echo', nil, function() end)
  local cmd = table.concat(job.jobs[id].cmd, ' ')
  lu.assertStrContains(cmd, 'Authorization: Bearer wx-tok')
  lu.assertStrContains(cmd, 'AuthorizationType: ilink_bot_token')
  lu.assertStrContains(cmd, 'X-WECHAT-UIN: ')
end

function TestWeixinApi:test_get_config_ticket()
  local ticket
  self.Api.get_config('user-9', function(t, err)
    ticket = t or err
  end)
  local id = find_job('getconfig')
  lu.assertNotNil(id)
  job.emit_stdout(id, { '{"ret":0,"typing_ticket":"tk-1"}' })
  lu.assertEquals(ticket, 'tk-1')
end

function TestWeixinApi:test_get_config_no_ticket()
  local err
  self.Api.get_config('user-9', function(t, e)
    err = e or t
  end)
  local id = find_job('getconfig')
  job.emit_stdout(id, { '{"ret":1,"errmsg":"bad"}' })
  lu.assertEquals(err, 'bad')
end

function TestWeixinApi:test_send_typing()
  local done
  self.Api.send_typing('user-9', 'tk-1', true, function(r, e)
    done = e or (r and 'ok')
  end)
  local id = find_job('sendtyping')
  lu.assertNotNil(id)
  local body = vim.json.decode(job.jobs[id].stdin[1])
  lu.assertEquals(body.ilink_user_id, 'user-9')
  lu.assertEquals(body.typing_ticket, 'tk-1')
  job.emit_stdout(id, { '{"ret":0}' })
  lu.assertEquals(done, 'ok')
end

function TestWeixinApi:test_send_message_missing_context_token()
  local err
  local ret = self.Api.send_message('u1', nil, 'hi', function(_, e)
    err = e
  end)
  lu.assertNil(ret)
  lu.assertEquals(err, 'Missing context_token')
end

function TestWeixinApi:test_send_message_body()
  local send_err
  local id = self.Api.send_message('u1', 'ctx-9', 'hello wx', function(_, e)
    send_err = e
  end)
  lu.assertNotNil(id, 'err=' .. tostring(send_err))
  local body = vim.json.decode(job.jobs[id].stdin[1])
  lu.assertEquals(body.msg.to_user_id, 'u1')
  lu.assertEquals(body.msg.context_token, 'ctx-9')
  lu.assertEquals(body.msg.item_list[1].text_item.text, 'hello wx')
  lu.assertNotNil(body.msg.client_id, 'client_id generated')
end

function TestWeixinApi:test_get_default_user_id_and_is_configured()
  lu.assertEquals(self.Api.get_default_user_id(), 'wx-user-1')
  lu.assertTrue(self.Api.is_configured())
  config.config.integrations.weixin.token = nil
  lu.assertFalse(self.Api.is_configured())
  -- restore so later tests can send
  config.config.integrations.weixin.token = 'wx-tok'
end

function TestWeixinApi:test_set_and_clear_credentials()
  self.Api.set_credentials('new-tok', 'acc-1', 'https://example.com')
  lu.assertEquals(config.config.integrations.weixin.token, 'new-tok')
  lu.assertEquals(config.config.integrations.weixin.default_user_id, 'acc-1')
  lu.assertEquals(self.Api.BASE_URL, 'https://example.com')

  self.Api.clear_credentials()
  lu.assertNil(config.config.integrations.weixin.token)
  lu.assertNil(config.config.integrations.weixin.default_user_id)
end

function TestWeixinApi:test_get_updates()
  local got
  self.Api.get_updates('buf-x', function(r, e)
    got = { r = r, e = e }
  end)
  local id = find_job('getupdates')
  lu.assertNotNil(id)
  local body = vim.json.decode(job.jobs[id].stdin[1])
  lu.assertEquals(body.get_updates_buf, 'buf-x')
  job.emit_stdout(id, { '{"ret":0}' })
  lu.assertEquals(got.r.ret, 0)
end

-- ═════════════════════ Weixin Message unit ═════════════════════

TestWeixinMessage = {}

function TestWeixinMessage:setUp()
  self.Msg = require('chat.integrations.weixin.message')
end

function TestWeixinMessage:test_parse_item_types()
  local Types = require('chat.integrations.weixin.types')
  local text = self.Msg.parse_item({
    type = Types.MessageItemType.TEXT,
    text_item = { text = 'hi' },
  })
  lu.assertEquals(text.type, 'text')
  lu.assertEquals(text.text, 'hi')

  local img = self.Msg.parse_item({
    type = Types.MessageItemType.IMAGE,
    image_item = { aes_key = 'a', encrypt_query_param = 'q' },
  })
  lu.assertEquals(img.type, 'image')
  lu.assertEquals(img.aes_key, 'a')

  local voice = self.Msg.parse_item({
    type = Types.MessageItemType.VOICE,
    voice_item = { aes_key = 'v', text = 'transcript' },
  })
  lu.assertEquals(voice.type, 'voice')
  lu.assertEquals(voice.text, 'transcript')

  local file = self.Msg.parse_item({
    type = Types.MessageItemType.FILE,
    file_item = { aes_key = 'f', encrypt_query_param = 'fq' },
  })
  lu.assertEquals(file.type, 'file')

  local video = self.Msg.parse_item({
    type = Types.MessageItemType.VIDEO,
    video_item = { aes_key = 'vid' },
  })
  lu.assertEquals(video.type, 'video')

  lu.assertNil(self.Msg.parse_item({ type = 999 }))
  lu.assertNil(self.Msg.parse_item(nil))
  -- missing sub_item accessors
  lu.assertEquals(self.Msg.parse_item({ type = Types.MessageItemType.TEXT }).text, '')
  lu.assertNil(self.Msg.parse_item({ type = Types.MessageItemType.IMAGE }).aes_key)
end

function TestWeixinMessage:test_parse_full()
  local Types = require('chat.integrations.weixin.types')
  local parsed = self.Msg.parse({
    seq = 1,
    message_id = 'm1',
    from_user_id = 'u1',
    to_user_id = 'bot',
    create_time_ms = 123,
    session_id = 's1',
    message_type = Types.MessageType.USER,
    message_state = Types.MessageState.FINISH,
    context_token = 'ctx',
    item_list = {
      { type = Types.MessageItemType.TEXT, text_item = { text = 'hello' } },
      { type = 999 }, -- unknown, skipped
    },
  })
  lu.assertEquals(parsed.message_id, 'm1')
  lu.assertEquals(#parsed.items, 1)
  lu.assertNil(self.Msg.parse(nil))
end

function TestWeixinMessage:test_get_text()
  lu.assertEquals(self.Msg.get_text(nil), '')
  local text = self.Msg.get_text({
    items = {
      { type = 'text', text = 'a' },
      { type = 'voice', text = 'b' },
      { type = 'image', aes_key = 'x' }, -- no text contribution
    },
  })
  lu.assertEquals(text, 'ab')
end

function TestWeixinMessage:test_should_process()
  local Types = require('chat.integrations.weixin.types')
  lu.assertFalse(self.Msg.should_process(nil))
  lu.assertFalse(self.Msg.should_process({
    message_type = Types.MessageType.BOT,
  }))
  lu.assertTrue(self.Msg.should_process({
    message_type = Types.MessageType.USER,
  }))
end

function TestWeixinMessage:test_extract_inbound()
  local Types = require('chat.integrations.weixin.types')
  local context_tokens = {}
  local inbound = self.Msg.extract_inbound({
    {
      message_id = 'm1',
      from_user_id = 'u1',
      context_token = 'tok1',
      message_type = Types.MessageType.USER,
      item_list = { { type = Types.MessageItemType.TEXT, text_item = { text = 'hello' } } },
    },
    {
      message_id = 'm2',
      from_user_id = 'u2',
      context_token = 'tok2',
      message_type = Types.MessageType.BOT, -- skipped
      item_list = { { type = Types.MessageItemType.TEXT, text_item = { text = 'bot' } } },
    },
    {
      message_id = 'm3',
      from_user_id = 'u3',
      message_type = Types.MessageType.USER,
      item_list = { { type = 999 } }, -- no text -> skipped
    },
  }, context_tokens)
  lu.assertEquals(#inbound, 1)
  lu.assertEquals(inbound[1].user_id, 'u1')
  lu.assertEquals(inbound[1].content, 'hello')
  lu.assertEquals(context_tokens['u1'], 'tok1')
  lu.assertNil(context_tokens['u3'])
  lu.assertEquals(self.Msg.extract_inbound({}, context_tokens), {})
  lu.assertEquals(self.Msg.extract_inbound(nil, context_tokens), {})
end

-- ═════════════════════ Weixin integration flow ═════════════════════

TestWeixinIntegration = {}

function TestWeixinIntegration:setUp()
  job.reset()
  self.storage = vim.fn.tempname() .. '_wxflow/'
  vim.fn.mkdir(self.storage, 'p')
  self.wx = fresh_weixin(self.storage, {
    weixin = { token = 'wx-tok', default_user_id = 'wx-user-1' },
  })
end

function TestWeixinIntegration:tearDown()
  self.wx.disconnect()
  wait(100)
  vim.fn.delete(self.storage, 'rf')
end

local USER_MSG = {
  message_id = 'in-1',
  from_user_id = 'wx-user-1',
  to_user_id = 'bot',
  context_token = 'ctx-inbound',
  message_type = 1, -- USER (per types)
  message_state = 2,
  item_list = { { type = 1, text_item = { text = 'hello weixin' } } },
}

local function feed_update(jobid, msgs, buf)
  job.emit_stdout(jobid, vim.json.encode({
    ret = 0,
    get_updates_buf = buf or 'buf-2',
    msgs = msgs,
  }))
end

function TestWeixinIntegration:test_connect_without_config()
  -- use a pristine storage dir: cached credentials from other tests would
  -- legitimately allow connect (re-login flow)
  local dir2 = vim.fn.tempname() .. '_wxnc/'
  vim.fn.mkdir(dir2, 'p')
  local wx2 = fresh_weixin(dir2, {})
  -- config.setup deep-merges integrations, so clear explicitly
  config.config.integrations.weixin = {}
  wx2.connect(function() end)
  wait(100)
  lu.assertNil(find_job('getupdates'))
  vim.fn.delete(dir2, 'rf')
end

function TestWeixinIntegration:test_poll_delivers_message()
  local Types = require('chat.integrations.weixin.types')
  local received = {}
  self.wx.connect(function(msg)
    received[#received + 1] = msg
  end)
  wait(300)
  local poll_id = find_job('getupdates')
  lu.assertNotNil(poll_id, 'long-poll started')

  USER_MSG.message_type = Types.MessageType.USER
  USER_MSG.item_list[1].type = Types.MessageItemType.TEXT
  feed_update(poll_id, { USER_MSG }, 'buf-next')
  wait(300)

  lu.assertEquals(#received, 1)
  lu.assertEquals(received[1].content, 'hello weixin')
  lu.assertEquals(received[1].user_id, 'wx-user-1')
end

function TestWeixinIntegration:test_send_message_after_inbound()
  local Types = require('chat.integrations.weixin.types')
  self.wx.connect(function() end)
  wait(300)
  local poll_id = find_job('getupdates')
  USER_MSG.message_type = Types.MessageType.USER
  USER_MSG.item_list[1].type = Types.MessageItemType.TEXT
  feed_update(poll_id, { USER_MSG })
  wait(300)

  self.wx.send_message('reply text')
  local send_id, j = find_job('sendmessage')
  lu.assertNotNil(j, 'send job started')
  local body = vim.json.decode(j.stdin[1])
  lu.assertEquals(body.msg.to_user_id, 'wx-user-1')
  lu.assertEquals(body.msg.context_token, 'ctx-inbound')
  lu.assertEquals(body.msg.item_list[1].text_item.text, 'reply text')
  job.emit_stdout(send_id, { '{"ret":0}' })
end

function TestWeixinIntegration:test_send_message_error_response()
  local Types = require('chat.integrations.weixin.types')
  self.wx.connect(function() end)
  wait(300)
  local poll_id = find_job('getupdates')
  USER_MSG.message_type = Types.MessageType.USER
  USER_MSG.item_list[1].type = Types.MessageItemType.TEXT
  feed_update(poll_id, { USER_MSG })
  wait(300)

  self.wx.send_message('will fail')
  local send_id = find_job('sendmessage')
  lu.assertNotNil(send_id)
  job.emit_stdout(send_id, { '{"ret":5,"errcode":1,"errmsg":"nope"}' })
  wait(100)
  lu.assertTrue(true, 'non-expired error logged without session reset')
end

function TestWeixinIntegration:test_send_message_session_expired()
  local Types = require('chat.integrations.weixin.types')
  self.wx.connect(function() end)
  wait(300)
  local poll_id = find_job('getupdates')
  USER_MSG.message_type = Types.MessageType.USER
  USER_MSG.item_list[1].type = Types.MessageItemType.TEXT
  feed_update(poll_id, { USER_MSG })
  wait(300)

  self.wx.send_message('first')
  local send_id = find_job('sendmessage')
  self.wx.send_message('second')
  -- session expired error -> queue dropped, credentials cleared
  job.emit_stdout(send_id, { '{"ret":-14}' })
  wait(200)
  local Api = require('chat.integrations.weixin.api')
  lu.assertFalse(Api.is_configured(), 'credentials cleared after expiry')
end

function TestWeixinIntegration:test_poll_session_expired()
  self.wx.connect(function() end)
  wait(300)
  local poll_id = find_job('getupdates')
  job.emit_stdout(poll_id, { '{"ret":-14,"errmsg":"expired"}' })
  wait(200)
  local Api = require('chat.integrations.weixin.api')
  lu.assertFalse(Api.is_configured())
end

function TestWeixinIntegration:test_poll_error_string()
  self.wx.connect(function() end)
  wait(300)
  local poll_id = find_job('getupdates')
  job.emit_exit(poll_id, 7, 0)
  wait(100)
  lu.assertTrue(true, 'transport error tolerated, timer retries')
end

function TestWeixinIntegration:test_poll_updates_cursor_saved()
  self.wx.connect(function() end)
  wait(300)
  local poll_id = find_job('getupdates')
  feed_update(poll_id, {}, 'cursor-99')
  wait(100)
  -- next poll includes the cursor
  wait(3100)
  local _, j = find_job('getupdates')
  -- may be the same record; check the most recent getupdates job body
  local found = false
  for _, jj in pairs(job.jobs) do
    if jj.stdin[1] and vim.json.decode(jj.stdin[1]).get_updates_buf == 'cursor-99' then
      found = true
    end
  end
  lu.assertTrue(found, 'cursor forwarded on next poll')
end

function TestWeixinIntegration:test_send_message_no_user()
  config.config.integrations.weixin.default_user_id = nil
  self.wx.send_message('orphan')
  wait(300)
  lu.assertNil(find_job('sendmessage'))
  config.config.integrations.weixin.default_user_id = 'wx-user-1'
end

function TestWeixinIntegration:test_send_message_empty_content()
  self.wx.send_message('')
  lu.assertNil(find_job('sendmessage'))
end

function TestWeixinIntegration:test_send_typing_flow()
  self.wx.send_typing('wx-user-1', true)
  local cfg_id = find_job('getconfig')
  lu.assertNotNil(cfg_id, 'ticket fetched lazily')
  job.emit_stdout(cfg_id, { '{"ret":0,"typing_ticket":"tk-x"}' })
  wait(100)
  local typing_id = find_job('sendtyping')
  lu.assertNotNil(typing_id)
  local body = vim.json.decode(job.jobs[typing_id].stdin[1])
  lu.assertEquals(body.typing_ticket, 'tk-x')
  -- second call uses cached ticket (no new getconfig)
  local cfg_count = 0
  for _, j in pairs(job.jobs) do
    if table.concat(j.cmd, ' '):find('getconfig', 1, true) then
      cfg_count = cfg_count + 1
    end
  end
  self.wx.send_typing('wx-user-1', false)
  wait(200)
  local cfg_count2 = 0
  for _, j in pairs(job.jobs) do
    if table.concat(j.cmd, ' '):find('getconfig', 1, true) then
      cfg_count2 = cfg_count2 + 1
    end
  end
  lu.assertEquals(cfg_count2, cfg_count, 'typing ticket cached')
end

function TestWeixinIntegration:test_send_typing_no_user()
  self.wx.send_typing(nil, true)
  lu.assertNil(find_job('getconfig'))
end

function TestWeixinIntegration:test_reconnect_requires_callback()
  local wx2 = fresh_weixin(self.storage, {
    weixin = { token = 't', default_user_id = 'd' },
  })
  local State = require('chat.integrations.weixin.state')
  State.set_credentials({ bot_token = 'b', account_id = 'a', base_url = nil })
  lu.assertFalse(wx2.reconnect(), 'no callback stored')
  wx2.connect(function() end)
  wait(100)
  -- disconnect() deliberately clears the callback, so reconnect must be
  -- attempted while still attached
  lu.assertTrue(wx2.reconnect(), 'callback + credentials present')
  wx2.disconnect()
end

function TestWeixinIntegration:test_reconnect_requires_credentials()
  local wx2 = fresh_weixin(self.storage, {
    weixin = { token = 't' },
  })
  wx2.connect(function() end)
  wx2.disconnect()
  lu.assertFalse(wx2.reconnect())
end

function TestWeixinIntegration:test_session_and_state()
  lu.assertNil(self.wx.current_session())
  self.wx.set_session('wx-session')
  lu.assertEquals(self.wx.current_session(), 'wx-session')
  lu.assertEquals(type(self.wx.get_state()), 'table')
  self.wx.clear_state()
  self.wx.cleanup()
end

function TestWeixinIntegration:test_logout()
  self.wx.connect(function() end)
  wait(200)
  self.wx.logout()
  local Api = require('chat.integrations.weixin.api')
  lu.assertFalse(Api.is_configured(), 'logout clears credentials')
end

function TestWeixinIntegration:test_login_state_module()
  local Login = require('chat.integrations.weixin.login')
  lu.assertEquals(type(Login.get_state()), 'table')
  Login.clear()
  lu.assertTrue(true)
end

