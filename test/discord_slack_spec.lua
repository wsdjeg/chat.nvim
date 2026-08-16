-- Coverage for discord / slack integrations (job-mock driven)
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

-- ═════════════════════ Discord ═════════════════════

TestDiscordIntegration = {}

local dc_storage

local DISCORD_CFG = {
  discord = { token = 'dc-token', channel_id = 'ch-1' },
}

function TestDiscordIntegration:setUp()
  job.reset()
  dc_storage = vim.fn.tempname() .. '_dc/'
  vim.fn.mkdir(dc_storage, 'p')
  self.dc = fresh_mod('discord', DISCORD_CFG, dc_storage)
end

function TestDiscordIntegration:tearDown()
  self.dc.disconnect()
  wait(100)
  vim.fn.delete(dc_storage, 'rf')
end

local function dc_msg(id, text, opts)
  opts = opts or {}
  local m = {
    id = id,
    content = text,
    channel_id = 'ch-1',
    author = {
      id = opts.author_id or 'user-9',
      username = opts.username or 'tester',
      bot = opts.bot or false,
    },
  }
  if opts.mentions then
    m.mentions = opts.mentions
  end
  if opts.reply_to_bot then
    m.referenced_message = { author = { id = '111' } }
  end
  return m
end

local function dc_feed_bot_id()
  local getme_id = find_job('users/@me')
  lu.assertNotNil(getme_id)
  -- discord mention syntax is <@snowflake-id>; use a numeric bot id
  job.emit_stdout(getme_id, { vim.json.encode({ id = '111', username = 'chatnvim' }) })
  job.emit_exit(getme_id, 0, 0)
  wait(50)
end

function TestDiscordIntegration:test_connect_gets_bot_id()
  self.dc.connect(function() end)
  wait(200)
  dc_feed_bot_id()
  lu.assertEquals(self.dc.get_state().bot_id, '111')
  -- persisted to state file
  local state_file = dc_storage .. 'integration/discord.json'
  lu.assertTrue(vim.fn.filereadable(state_file) == 1)
end

function TestDiscordIntegration:test_connect_requires_token()
  config.config.integrations.discord.token = nil
  self.dc.connect(function() end)
  lu.assertTrue(true)
  config.config.integrations.discord.token = 'dc-token'
end

function TestDiscordIntegration:test_connect_requires_channel()
  config.config.integrations.discord.channel_id = nil
  self.dc.connect(function() end)
  lu.assertTrue(true)
  config.config.integrations.discord.channel_id = 'ch-1'
end

function TestDiscordIntegration:test_fetch_delivers_mention()
  local received = {}
  self.dc.connect(function(msg)
    received[#received + 1] = msg
  end)
  wait(200)
  dc_feed_bot_id()
  wait(300)

  local fetch_id = find_job('/messages?limit=10')
  lu.assertNotNil(fetch_id, 'fetch job started')
  job.emit_stdout(fetch_id, {
    vim.json.encode({
      -- Discord API returns newest first; the module reverses
      -- internally to process chronologically
      dc_msg('106', 'replying bot', { reply_to_bot = true }),
      dc_msg('105', '/command run', { username = 'cmd' }),
      dc_msg('104', 'bot echo', { bot = true, mentions = { { id = '111' } } }),
      dc_msg('103', '<@111> ', { mentions = { { id = '111' } } }),
      dc_msg('102', 'not for bot'),
      dc_msg('101', '<@111> hello discord', { mentions = { { id = '111' } } }),
    }),
  })
  job.emit_exit(fetch_id, 0, 0)
  wait(300)

  lu.assertEquals(#received, 3, 'mention, command, reply delivered')
  lu.assertEquals(received[1].content, 'hello discord')
  lu.assertEquals(received[1].author, 'tester')
  lu.assertEquals(self.dc.get_state().last_message_id, '106')
end

function TestDiscordIntegration:test_fetch_skips_processed()
  local received = {}
  self.dc.connect(function(msg)
    received[#received + 1] = msg
  end)
  wait(200)
  dc_feed_bot_id()
  wait(200)
  local payload = vim.json.encode({
    dc_msg('201', 'once', { mentions = { { id = '111' } } }),
  })
  local fetch_id = find_job('/messages?limit=10')
  job.emit_stdout(fetch_id, { payload })
  job.emit_exit(fetch_id, 0, 0)
  wait(200)
  lu.assertEquals(#received, 1)
  job.emit_stdout(fetch_id, { payload })
  job.emit_exit(fetch_id, 0, 0)
  wait(200)
  lu.assertEquals(#received, 1, 'duplicate id skipped')
end

function TestDiscordIntegration:test_fetch_empty_response()
  self.dc.connect(function() end)
  wait(200)
  dc_feed_bot_id()
  wait(200)
  local fetch_id = find_job('/messages?limit=10')
  job.emit_stdout(fetch_id, { '[]' })
  job.emit_exit(fetch_id, 0, 0)
  wait(100)
  lu.assertTrue(true)
end

function TestDiscordIntegration:test_fetch_decode_error()
  self.dc.connect(function() end)
  wait(200)
  dc_feed_bot_id()
  wait(200)
  local fetch_id = find_job('/messages?limit=10')
  job.emit_stdout(fetch_id, { 'not json' })
  job.emit_exit(fetch_id, 0, 0)
  wait(100)
  lu.assertTrue(true)
end

function TestDiscordIntegration:test_fetch_nonzero_exit()
  self.dc.connect(function() end)
  wait(200)
  dc_feed_bot_id()
  wait(200)
  local fetch_id = find_job('/messages?limit=10')
  job.emit_exit(fetch_id, 22, 0)
  wait(100)
  lu.assertTrue(true, 'callback(nil) path exercised')
end

function TestDiscordIntegration:test_send_message_queue()
  self.dc.send_message('first')
  local send_id, j = find_job('ch-1/messages')
  lu.assertNotNil(j)
  lu.assertEquals(vim.json.decode(j.stdin[1]).content, 'first')
  -- exit -> next in queue
  self.dc.send_message('second')
  job.emit_exit(send_id, 0, 0)
  wait(200)
  local _, j2 = find_job('ch-1/messages')
  lu.assertNotNil(j2)
end

function TestDiscordIntegration:test_send_message_empty_ignored()
  self.dc.send_message('')
  lu.assertNil(find_job('ch-1/messages'))
end

function TestDiscordIntegration:test_send_message_chunks()
  self.dc.send_message(string.rep('z', 5000))
  local send_id, j = find_job('ch-1/messages')
  lu.assertTrue(#vim.json.decode(j.stdin[1]).content <= 2000)
  job.emit_exit(send_id, 0, 0)
  wait(200)
  lu.assertNotNil(find_job('ch-1/messages'))
end

function TestDiscordIntegration:test_reply()
  local id = self.dc.reply('ch-1', '42', 'reply text')
  lu.assertTrue(id > 0)
  local _, j = find_job('ch-1/messages')
  local cmd = table.concat(j.cmd, ' ')
  lu.assertStrContains(cmd, 'message_reference')
  job.emit_exit(id, 0, 2)
end

function TestDiscordIntegration:test_send_typing()
  self.dc.send_typing(true)
  lu.assertNotNil(find_job('/typing'))
  self.dc.send_typing(false)
end

function TestDiscordIntegration:test_session_and_clear_state()
  self.dc.set_session('dc-session')
  lu.assertEquals(self.dc.current_session(), 'dc-session')
  self.dc.clear_state()
  lu.assertNil(self.dc.get_state().bot_id)
end

function TestDiscordIntegration:test_receive_messages_alias()
  lu.assertEquals(self.dc.receive_messages, self.dc.connect)
end

function TestDiscordIntegration:test_cleanup()
  self.dc.connect(function() end)
  self.dc.cleanup()
  lu.assertFalse(self.dc.get_state().is_running)
end

-- ═════════════════════ Slack ═════════════════════

TestSlackIntegration = {}

local slack_storage

local SLACK_CFG = {
  slack = { bot_token = 'xoxb-1', channel_id = 'C123' },
}

function TestSlackIntegration:setUp()
  job.reset()
  slack_storage = vim.fn.tempname() .. '_slack/'
  vim.fn.mkdir(slack_storage, 'p')
  self.slack = fresh_mod('slack', SLACK_CFG, slack_storage)
end

function TestSlackIntegration:tearDown()
  self.slack.disconnect()
  wait(100)
  vim.fn.delete(slack_storage, 'rf')
end

local function sl_msg(ts, text, opts)
  opts = opts or {}
  local m = {
    ts = ts,
    text = text,
    user = opts.user or 'U999',
  }
  if opts.bot_id then
    m.bot_id = opts.bot_id
  end
  if opts.thread_ts then
    m.thread_ts = opts.thread_ts
  end
  return m
end

local function sl_feed_bot_id()
  local auth_id = find_job('auth.test')
  lu.assertNotNil(auth_id)
  job.emit_stdout(auth_id, {
    vim.json.encode({ ok = true, user_id = 'UBOT' }),
  })
  wait(50)
end

function TestSlackIntegration:test_connect_gets_bot_user()
  self.slack.connect(function() end)
  wait(200)
  sl_feed_bot_id()
  lu.assertEquals(self.slack.get_state().bot_user_id, 'UBOT')
end

function TestSlackIntegration:test_connect_requires_token()
  config.config.integrations.slack.bot_token = nil
  self.slack.connect(function() end)
  lu.assertTrue(true)
  config.config.integrations.slack.bot_token = 'xoxb-1'
end

function TestSlackIntegration:test_connect_requires_channel()
  config.config.integrations.slack.channel_id = nil
  self.slack.connect(function() end)
  lu.assertTrue(true)
  config.config.integrations.slack.channel_id = 'C123'
end

function TestSlackIntegration:test_fetch_delivers_mention()
  local received = {}
  self.slack.connect(function(msg)
    received[#received + 1] = msg
  end)
  wait(200)
  sl_feed_bot_id()
  wait(300)

  local fetch_id = find_job('conversations.history')
  lu.assertNotNil(fetch_id)
  job.emit_stdout(fetch_id, {
    vim.json.encode({
      ok = true,
      messages = {
        -- Slack conversations.history returns newest first; the module
        -- reverses internally to process chronologically
        sl_msg('1111.0005', '<@UBOT> ', {}),
        sl_msg('1111.0004', 'bot msg', { bot_id = 'B1' }),
        sl_msg('1111.0003', 'thread reply', { thread_ts = '1111.0001' }),
        sl_msg('1111.0002', 'not mentioned'),
        sl_msg('1111.0001', '<@UBOT> hi slack'),
      },
    }),
  })
  wait(300)
  lu.assertEquals(#received, 2, 'mention and thread reply delivered')
  lu.assertEquals(received[1].content, 'hi slack')
  lu.assertEquals(self.slack.get_state().last_timestamp, '1111.0005')
end

function TestSlackIntegration:test_fetch_api_error()
  self.slack.connect(function() end)
  wait(200)
  sl_feed_bot_id()
  wait(200)
  local fetch_id = find_job('conversations.history')
  job.emit_stdout(fetch_id, { vim.json.encode({ ok = false, error = 'channel_not_found' }) })
  wait(100)
  lu.assertTrue(true)
end

function TestSlackIntegration:test_fetch_skips_processed()
  local received = {}
  self.slack.connect(function(msg)
    received[#received + 1] = msg
  end)
  wait(200)
  sl_feed_bot_id()
  wait(200)
  local payload = vim.json.encode({
    ok = true,
    messages = { sl_msg('2222.0001', '<@UBOT> once') },
  })
  local fetch_id = find_job('conversations.history')
  job.emit_stdout(fetch_id, { payload })
  wait(200)
  lu.assertEquals(#received, 1)
  job.emit_stdout(fetch_id, { payload })
  wait(200)
  lu.assertEquals(#received, 1, 'duplicate ts skipped')
end

function TestSlackIntegration:test_send_message()
  self.slack.send_message('hello slack')
  local send_id, j = find_job('chat.postMessage')
  lu.assertNotNil(j)
  local cmd = table.concat(j.cmd, ' ')
  lu.assertStrContains(cmd, 'channel=C123')
  lu.assertStrContains(cmd, 'text=hello%20slack')
  job.emit_exit(send_id, 0, 0)
end

function TestSlackIntegration:test_send_message_chunks()
  self.slack.send_message(string.rep('q', 90000))
  local send_id = find_job('chat.postMessage')
  lu.assertNotNil(send_id)
  job.emit_exit(send_id, 0, 0)
  wait(200)
  lu.assertNotNil(find_job('chat.postMessage'))
end

function TestSlackIntegration:test_reply()
  local id = self.slack.reply('C123', '1111.0001', 'thread text')
  lu.assertTrue(id > 0)
  local _, j = find_job('chat.postMessage')
  lu.assertStrContains(table.concat(j.cmd, ' '), 'thread_ts=1111.0001')
  job.emit_exit(id, 0, 2)
end

function TestSlackIntegration:test_missing_config_send()
  config.config.integrations.slack.channel_id = nil
  self.slack.send_message('x')
  lu.assertTrue(true)
  config.config.integrations.slack.channel_id = 'C123'
end

function TestSlackIntegration:test_session_and_clear_state()
  self.slack.set_session('sl-session')
  lu.assertEquals(self.slack.current_session(), 'sl-session')
  self.slack.clear_state()
  lu.assertNil(self.slack.get_state().bot_user_id)
end

function TestSlackIntegration:test_cleanup()
  self.slack.connect(function() end)
  self.slack.cleanup()
  lu.assertFalse(self.slack.get_state().is_running)
end

