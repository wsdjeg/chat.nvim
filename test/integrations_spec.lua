-- Coverage for telegram / wecom / dingtalk integrations (job-mock driven)
local lu = require('luaunit')
local job = require('job')
local config = require('chat.config')

local function fresh_mod(name, integrations_cfg, storage_dir)
  package.loaded['chat.integrations.' .. name] = nil
  config.setup({
    storage_dir = storage_dir,
    integrations = integrations_cfg,
  })
  return require('chat.integrations.' .. name)
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

--- Extract the JSON request body of a job: inline `-d <json>` arg first,
--- falling back to stdin (used with `stdin_body = true`).
local function request_body(j)
  for i, a in ipairs(j.cmd) do
    if a == '-d' and j.cmd[i + 1] and j.cmd[i + 1] ~= '@-' then
      return vim.json.decode(j.cmd[i + 1])
    end
  end
  if j.stdin[1] then
    return vim.json.decode(j.stdin[1])
  end
  return nil
end

-- ═════════════════════ Telegram ═════════════════════

TestTelegramIntegration = {}

local tg_storage

local function tg_config(extra)
  return vim.tbl_extend('force', {
    bot_token = 'tg-token-1',
    chat_id = 'tg-chat-1',
  }, extra or {})
end

local TG_INTEGRATION = {
  telegram = {
    bot_token = 'tg-token-1',
    chat_id = 'tg-chat-1',
  },
}

function TestTelegramIntegration:setUp()
  job.reset()
  job.intercept()
  tg_storage = vim.fn.tempname() .. '_tg/'
  vim.fn.mkdir(tg_storage, 'p')
  self.tg = fresh_mod('telegram', TG_INTEGRATION, tg_storage)
end

function TestTelegramIntegration:tearDown()
  job.intercept(false)
  self.tg.disconnect()
  wait(100)
  vim.fn.delete(tg_storage, 'rf')
end

local function tg_make_update(id, text, opts)
  opts = opts or {}
  local msg = {
    message_id = opts.message_id or id,
    from = {
      id = 100,
      first_name = 'Tester',
      username = 'tester',
      is_bot = opts.is_bot or false,
    },
    chat = {
      id = opts.chat_id or 555,
      type = opts.chat_type or 'group',
    },
    text = text,
  }
  if opts.reply_to_bot then
    msg.reply_to_message = {
      from = { username = 'chatnvim_bot' },
    }
  end
  return { update_id = id, message = msg }
end

function TestTelegramIntegration:test_get_me_on_connect()
  self.tg.connect(function() end)
  wait(200)
  local getme_id = find_job('getMe')
  lu.assertNotNil(getme_id, 'getMe request on connect')
  job.emit_stdout(getme_id, {
    vim.json.encode({ ok = true, result = { username = 'chatnvim_bot' } }),
  })
  wait(100)
  lu.assertEquals(self.tg.get_state().bot_username, 'chatnvim_bot')
end

function TestTelegramIntegration:test_connect_requires_token()
  config.config.integrations.telegram.bot_token = nil
  self.tg.connect(function() end)
  wait(100)
  lu.assertNil(find_job('getMe'))
  config.config.integrations.telegram.bot_token = 'tg-token-1'
end

function TestTelegramIntegration:test_updates_mention_delivered()
  local received = {}
  self.tg.connect(function(msg)
    received[#received + 1] = msg
  end)
  wait(200)
  local getme_id = find_job('getMe')
  job.emit_stdout(getme_id, {
    vim.json.encode({ ok = true, result = { username = 'chatnvim_bot' } }),
  })
  wait(200)

  local fetch_id = find_job('getUpdates')
  lu.assertNotNil(fetch_id, 'polling started')
  job.emit_stdout(fetch_id, {
    vim.json.encode({
      ok = true,
      result = {
        tg_make_update(10, '@chatnvim_bot what time is it'),
        tg_make_update(11, 'plain group message'),
        tg_make_update(12, 'reply to bot', { reply_to_bot = true }),
        tg_make_update(13, 'private message', { chat_type = 'private' }),
        tg_make_update(14, 'bot self', { is_bot = true, chat_type = 'private' }),
        tg_make_update(15, '@chatnvim_bot ', { chat_type = 'private' }),
      },
    }),
  })
  wait(300)
  local contents = {}
  for _, m in ipairs(received) do
    contents[#contents + 1] = m.content
  end
  lu.assertEquals(#received, 3, 'mention, reply, private delivered; empty/bot skipped')
  lu.assertTrue(vim.tbl_contains(contents, 'what time is it'), 'mention stripped')
  lu.assertTrue(vim.tbl_contains(contents, 'reply to bot'))
  lu.assertTrue(vim.tbl_contains(contents, 'private message'))
  -- author resolution
  lu.assertEquals(received[1].author, 'Tester')
  -- offset tracked
  lu.assertEquals(self.tg.get_state().last_update_id, 15)
end

function TestTelegramIntegration:test_updates_skips_processed_ids()
  local received = {}
  self.tg.connect(function(msg)
    received[#received + 1] = msg
  end)
  wait(200)
  local payload = vim.json.encode({
    ok = true,
    result = { tg_make_update(20, 'once', { chat_type = 'private' }) },
  })
  local fetch_id = find_job('getUpdates')
  job.emit_stdout(fetch_id, { payload })
  wait(200)
  lu.assertEquals(#received, 1)
  -- replay same update: skipped
  job.emit_stdout(fetch_id, { payload })
  wait(200)
  lu.assertEquals(#received, 1, 'duplicate update skipped')
end

function TestTelegramIntegration:test_updates_error_result()
  self.tg.connect(function() end)
  wait(200)
  local fetch_id = find_job('getUpdates')
  job.emit_stdout(fetch_id, { '{"ok":false,"result":[]}' })
  wait(100)
  lu.assertTrue(true, 'no crash')
end

function TestTelegramIntegration:test_updates_no_message_field()
  self.tg.connect(function() end)
  wait(200)
  local fetch_id = find_job('getUpdates')
  job.emit_stdout(fetch_id, { vim.json.encode({ ok = true, result = { { update_id = 30 } } }) })
  wait(100)
  lu.assertTrue(true)
end

function TestTelegramIntegration:test_send_message_webbody()
  self.tg.send_message('hello tg')
  local send_id, send_job = find_job('sendMessage')
  lu.assertNotNil(send_job)
  local body = request_body(send_job)
  lu.assertEquals(body.chat_id, 'tg-chat-1')
  lu.assertEquals(body.text, 'hello tg')
  lu.assertEquals(body.parse_mode, 'Markdown')
  job.emit_exit(send_id, 0)
end

function TestTelegramIntegration:test_send_message_chunks()
  self.tg.send_message(string.rep('x', 9000))
  local send_id = find_job('sendMessage')
  lu.assertNotNil(send_id)
  job.emit_exit(send_id, 0)
  wait(200)
  local send_id2, job2 = find_job('sendMessage')
  lu.assertNotNil(job2)
  local body = request_body(job2)
  lu.assertTrue(#body.text <= 4096)
  job.emit_exit(send_id2, 0)
end

function TestTelegramIntegration:test_reply()
  local id = self.tg.reply('tg-chat-1', 42, 'reply text')
  lu.assertTrue(id > 0)
  local _, j = find_job('sendMessage')
  -- reply uses inline body in the curl command
  local cmd = table.concat(j.cmd, ' ')
  lu.assertStrContains(cmd, 'reply_to_message_id')
  lu.assertStrContains(cmd, 'reply text')
  job.emit_exit(id, 0, 2)
end

function TestTelegramIntegration:test_state_and_session()
  self.tg.set_session('tg-session')
  lu.assertEquals(self.tg.current_session(), 'tg-session')
  local state_file = tg_storage .. 'integration/telegram.json'
  lu.assertTrue(vim.fn.filereadable(state_file) == 1)
  self.tg.clear_state()
  lu.assertNil(self.tg.get_state().bot_username)
  lu.assertEquals(vim.fn.filereadable(state_file), 0)
end

function TestTelegramIntegration:test_cleanup()
  self.tg.connect(function() end)
  wait(100)
  self.tg.cleanup()
  lu.assertFalse(self.tg.get_state().is_running)
end

-- ═════════════════════ WeCom ═════════════════════

TestWeComIntegration = {}

local wecom_storage

function TestWeComIntegration:setUp()
  job.reset()
  job.intercept()
  wecom_storage = vim.fn.tempname() .. '_wecom/'
  vim.fn.mkdir(wecom_storage, 'p')
end

function TestWeComIntegration:tearDown()
  job.intercept(false)
  vim.fn.delete(wecom_storage, 'rf')
end

function TestWeComIntegration:test_webhook_connect_and_send()
  local wecom = fresh_mod('wecom', {
    wecom = { webhook_key = 'wh-key-1' },
  }, wecom_storage)
  wecom.connect(function() end)
  wecom.send_message('hello wecom')
  local _, j = find_job('webhook/send')
  lu.assertNotNil(j, 'webhook send job')
  local body = vim.json.decode(j.stdin[1])
  lu.assertEquals(body.msgtype, 'text')
  lu.assertEquals(body.text.content, 'hello wecom')
  wecom.disconnect()
end

function TestWeComIntegration:test_api_send_with_token()
  local wecom = fresh_mod('wecom', {
    wecom = {
      corp_id = 'corp1',
      corp_secret = 'sec1',
      agent_id = 1001,
      user_id = 'u1',
    },
  }, wecom_storage)
  wecom.send_message('via api')
  local token_id = find_job('gettoken')
  lu.assertNotNil(token_id)
  job.emit_stdout(token_id, { vim.json.encode({ access_token = 'wc-token', expires_in = 7200 }) })
  wait(100)
  local _, j = find_job('message/send')
  lu.assertNotNil(j)
  lu.assertStrContains(table.concat(j.cmd, ' '), 'access_token=wc-token')
  local body = vim.json.decode(j.stdin[1])
  lu.assertEquals(body.touser, 'u1')
  lu.assertEquals(body.agentid, 1001)
  wecom.disconnect()
end

function TestWeComIntegration:test_connect_modes()
  -- webhook only: no timer polling
  local wecom = fresh_mod('wecom', {
    wecom = { webhook_key = 'wh' },
  }, wecom_storage)
  wecom.connect(function() end)
  wecom.disconnect()

  -- api mode: polling timer started (placeholder fetch)
  local wecom2 = fresh_mod('wecom', {
    wecom = { corp_id = 'c', corp_secret = 's' },
  }, wecom_storage)
  wecom2.connect(function() end)
  wait(200)
  wecom2.disconnect()
  lu.assertTrue(true)
end

function TestWeComIntegration:test_connect_missing_config()
  local wecom = fresh_mod('wecom', {
    wecom = {},
  }, wecom_storage)
  wecom.connect(function() end)
  lu.assertTrue(true)
end

function TestWeComIntegration:test_no_config_at_all()
  local wecom = fresh_mod('wecom', nil, wecom_storage)
  wecom.connect(function() end)
  lu.assertTrue(true)
end

function TestWeComIntegration:test_session_state()
  local wecom = fresh_mod('wecom', {
    wecom = { webhook_key = 'wh' },
  }, wecom_storage)
  wecom.set_session('wc-session')
  lu.assertEquals(wecom.current_session(), 'wc-session')
  wecom.cleanup()
end

-- ═════════════════════ DingTalk ═════════════════════

TestDingTalkIntegration = {}

local ding_storage

function TestDingTalkIntegration:setUp()
  job.reset()
  job.intercept()
  ding_storage = vim.fn.tempname() .. '_ding/'
  vim.fn.mkdir(ding_storage, 'p')
end

function TestDingTalkIntegration:tearDown()
  job.intercept(false)
  vim.fn.delete(ding_storage, 'rf')
end

function TestDingTalkIntegration:test_webhook_send()
  local ding = fresh_mod('dingtalk', {
    dingtalk = { webhook = 'https://oapi.dingtalk.com/robot/send?access_token=x' },
  }, ding_storage)
  ding.connect(function() end)
  ding.send_message('hello ding')
  local _, j = find_job('robot/send')
  lu.assertNotNil(j)
  local body = vim.json.decode(j.stdin[1])
  lu.assertEquals(body.text.content, 'hello ding')
  ding.disconnect()
end

function TestDingTalkIntegration:test_api_send_with_token()
  local ding = fresh_mod('dingtalk', {
    dingtalk = {
      app_key = 'dk1',
      app_secret = 'ds1',
      conversation_id = 'cid1',
      user_id = 'du1',
    },
  }, ding_storage)
  ding.send_message('api msg')
  local token_id = find_job('gettoken')
  lu.assertNotNil(token_id)
  job.emit_stdout(token_id, { vim.json.encode({ access_token = 'dd-token' }) })
  wait(100)
  local send_id, j = find_job('batchSend')
  lu.assertNotNil(j)
  lu.assertStrContains(table.concat(j.cmd, ' '), 'x-acs-dingtalk-access-token: dd-token')
  local body = vim.json.decode(j.stdin[1])
  lu.assertEquals(body.robotCode, 'dk1')
  lu.assertEquals(body.userIds, { 'du1' })
  lu.assertEquals(vim.json.decode(body.msgParam).content, 'api msg')
  job.emit_exit(send_id, 0)
  ding.disconnect()
end

function TestDingTalkIntegration:test_connect_missing_config()
  local ding = fresh_mod('dingtalk', { dingtalk = {} }, ding_storage)
  ding.connect(function() end)
  lu.assertTrue(true)
end

function TestDingTalkIntegration:test_session_state()
  local ding = fresh_mod('dingtalk', {
    dingtalk = { webhook = 'https://oapi.dingtalk.com/robot/send?access_token=y' },
  }, ding_storage)
  ding.set_session('dd-session')
  lu.assertEquals(ding.current_session(), 'dd-session')
  local state_file = ding_storage .. 'integration/dingtalk.json'
  lu.assertTrue(vim.fn.filereadable(state_file) == 1)
  ding.cleanup()
end

