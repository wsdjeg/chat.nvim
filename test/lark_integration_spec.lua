-- Coverage for lua/chat/integrations/lark.lua
-- Drives the Lark polling flow with the test/job.lua mock.
local lu = require('luaunit')
local job = require('job')
local config = require('chat.config')

local function fresh_lark(storage_dir)
  package.loaded['chat.integrations.lark'] = nil
  -- configure before loading so STATE_FILE points at temp storage
  config.setup({
    storage_dir = storage_dir,
    integrations = {
      lark = {
        app_id = 'cli_test_app',
        app_secret = 'secret_test',
        chat_id = 'oc_test_chat',
      },
    },
  })
  return require('chat.integrations.lark')
end

TestLarkIntegration = {}

local storage_dir

function TestLarkIntegration:setUp()
  job.reset()
  job.intercept()
  storage_dir = vim.fn.tempname() .. '_lark_test/'
  vim.fn.mkdir(storage_dir, 'p')
  self.lark = fresh_lark(storage_dir)
end

function TestLarkIntegration:tearDown()
  job.intercept(false)
  self.lark.disconnect()
  vim.wait(100, function()
    return false
  end, 20)
  vim.fn.delete(storage_dir, 'rf')
end

local function wait(ms)
  vim.wait(ms or 300, function()
    return false
  end, 20)
end

--- Find a started job whose URL contains the given fragment
local function find_job(url_fragment)
  for id, j in pairs(job.jobs) do
    if table.concat(j.cmd, ' '):find(url_fragment, 1, true) then
      return id, j
    end
  end
end

local TOKEN_JSON = vim.json.encode({
  tenant_access_token = 't-abc123',
  expire = 7200,
})

local BOT_JSON = vim.json.encode({
  bot = { open_id = 'ou_bot_1' },
})

function TestLarkIntegration:test_session_management()
  lu.assertNil(self.lark.current_session())
  self.lark.set_session('sess-lark')
  lu.assertEquals(self.lark.current_session(), 'sess-lark')
  -- state file persisted
  local state_file = storage_dir .. 'integration/lark.json'
  lu.assertTrue(vim.fn.filereadable(state_file) == 1, 'state file written')
  local content = table.concat(vim.fn.readfile(state_file), '')
  lu.assertStrContains(content, 'sess-lark')
end

function TestLarkIntegration:test_state_roundtrip_on_connect()
  self.lark.set_session('sess-roundtrip')
  -- reload module fresh; connect() should load state from disk
  self.lark = fresh_lark(storage_dir)
  self.lark.connect(function() end)
  wait(100)
  lu.assertEquals(self.lark.current_session(), 'sess-roundtrip')
end

function TestLarkIntegration:test_connect_starts_token_and_bot_fetch()
  self.lark.connect(function() end)
  wait(200)
  local token_id = find_job('tenant_access_token')
  lu.assertNotNil(token_id, 'token job started')
  -- no bot info until token arrives
  lu.assertNil(find_job('/bot/v3/info'))

  job.emit_stdout(token_id, { TOKEN_JSON })
  wait(100)
  local bot_id = find_job('/bot/v3/info')
  lu.assertNotNil(bot_id, 'bot info job started after token')
  local cmd = table.concat(job.jobs[bot_id].cmd, ' ')
  lu.assertStrContains(cmd, 'Bearer t-abc123')
  job.emit_stdout(bot_id, { BOT_JSON })
  wait(50)
end

function TestLarkIntegration:test_connect_requires_config()
  config.config.integrations.lark.app_secret = nil
  self.lark.connect(function() end)
  wait(100)
  lu.assertNil(find_job('tenant_access_token'))
  config.config.integrations.lark.app_secret = 'secret_test'
end

function TestLarkIntegration:test_connect_requires_chat_id()
  config.config.integrations.lark.chat_id = nil
  self.lark.connect(function() end)
  wait(100)
  lu.assertNil(find_job('tenant_access_token'))
  config.config.integrations.lark.chat_id = 'oc_test_chat'
end

local function feed_token_and_bot()
  -- connect() spawns one token job for bot info AND (via the poll timer)
  -- another for the first fetch; feed every pending token job so both
  -- callbacks run regardless of job iteration order
  for id, j in pairs(job.jobs) do
    if table.concat(j.cmd, ' '):find('tenant_access_token', 1, true) then
      job.emit_stdout(id, { TOKEN_JSON })
    end
  end
  wait(100)
  local bot_id = find_job('/bot/v3/info')
  if bot_id then
    job.emit_stdout(bot_id, { BOT_JSON })
    wait(50)
  end
end

local function make_msg(id, text, opts)
  opts = opts or {}
  return {
    message_id = id,
    chat_id = 'oc_test_chat',
    create_time = opts.create_time or '1700000000000',
    msg_type = 'text',
    body = { content = vim.json.encode({ text = text }) },
    mentions = opts.mentions or {
      { id = 'ou_bot_1', key = '@_user_1', name = 'chat.nvim' },
    },
    sender = {
      id = opts.sender_id or 'ou_user_9',
      sender_type = opts.sender_type or 'user',
    },
  }
end

function TestLarkIntegration:test_fetch_delivers_mention_message()
  local received = {}
  self.lark.connect(function(msg)
    received[#received + 1] = msg
  end)
  wait(200)
  feed_token_and_bot()

  local fetch_id = find_job('container_id_type=chat')
  lu.assertNotNil(fetch_id, 'fetch job started')
  local items = vim.json.encode({
    data = {
      items = {
        make_msg('om_1', '@_user_1 hello lark'),
        make_msg('om_2', '@_user_1 second', { create_time = '1700000001000' }),
      },
    },
  })
  job.emit_stdout(fetch_id, { items:sub(1, 20) })
  job.emit_stdout(fetch_id, { items:sub(21) })
  job.emit_exit(fetch_id, 0)
  wait(200)
  lu.assertEquals(#received, 2, 'both mention messages delivered')
  local ids = { received[1].message_id, received[2].message_id }
  lu.assertTrue(vim.tbl_contains(ids, 'om_1') and vim.tbl_contains(ids, 'om_2'))
  lu.assertEquals(received[1].author, 'ou_user_9')
end

function TestLarkIntegration:test_fetch_skips_processed_ids()
  local received = {}
  self.lark.connect(function(msg)
    received[#received + 1] = msg
  end)
  wait(200)
  feed_token_and_bot()

  local items = vim.json.encode({
    data = { items = { make_msg('om_dup', '@_user_1 again') } },
  })
  local fetch_id = find_job('container_id_type=chat')
  job.emit_stdout(fetch_id, { items })
  job.emit_exit(fetch_id, 0)
  wait(200)
  lu.assertEquals(#received, 1)

  -- second fetch with same message id: skipped
  local fetch_id2 = find_job('container_id_type=chat')
  -- fetch id may be the same job id (job mock keeps records); trigger new poll
  job.emit_stdout(fetch_id2 or fetch_id, { items })
  job.emit_exit(fetch_id2 or fetch_id, 0)
  wait(200)
  lu.assertEquals(#received, 1, 'duplicate message id skipped')
end

function TestLarkIntegration:test_fetch_skips_app_sender_and_unmentioned()
  local received = {}
  self.lark.connect(function(msg)
    received[#received + 1] = msg
  end)
  wait(200)
  feed_token_and_bot()

  local items = vim.json.encode({
    data = {
      items = {
        make_msg('om_app', '@_user_1 from app', { sender_type = 'app' }),
        make_msg('om_nomention', 'plain text', { mentions = {} }),
        make_msg('om_other_mention', 'hi @other', {
          mentions = { { id = 'ou_other', key = '@_user_2' } },
        }),
      },
    },
  })
  local fetch_id = find_job('container_id_type=chat')
  job.emit_stdout(fetch_id, { items })
  job.emit_exit(fetch_id, 0)
  wait(200)
  lu.assertEquals(#received, 0, 'app/unmentioned messages skipped')
end

function TestLarkIntegration:test_fetch_api_error_no_crash()
  self.lark.connect(function() end)
  wait(200)
  feed_token_and_bot()
  local fetch_id = find_job('container_id_type=chat')
  job.emit_stdout(fetch_id, { '{"code":999003,"msg":"no permission"}' })
  job.emit_exit(fetch_id, 0)
  wait(100)
  lu.assertTrue(true, 'no crash on API error')
end

function TestLarkIntegration:test_fetch_invalid_json_no_crash()
  self.lark.connect(function() end)
  wait(200)
  feed_token_and_bot()
  local fetch_id = find_job('container_id_type=chat')
  job.emit_stdout(fetch_id, { 'garbage{{{' })
  job.emit_exit(fetch_id, 0)
  wait(100)
  lu.assertTrue(true)
end

function TestLarkIntegration:test_fetch_empty_items()
  self.lark.connect(function() end)
  wait(200)
  feed_token_and_bot()
  local fetch_id = find_job('container_id_type=chat')
  job.emit_stdout(fetch_id, { '{"data":{"items":[]}}' })
  job.emit_exit(fetch_id, 0)
  wait(100)
  lu.assertTrue(true)
end

function TestLarkIntegration:test_fetch_uses_start_time_from_state()
  -- Pre-write state with a last_message_time in the future
  local state_dir = storage_dir .. 'integration'
  vim.fn.mkdir(state_dir, 'p')
  local future_ms = tostring((os.time() + 3600) * 1000)
  vim.fn.writefile({
    vim.json.encode({
      last_message_id = 'om_prev',
      last_message_time = future_ms,
      processed_ids = {},
      session = 'sess-time',
    }),
  }, state_dir .. '/lark.json')

  self.lark = fresh_lark(storage_dir)
  self.lark.connect(function() end)
  wait(200)
  feed_token_and_bot()
  local _, fetch_job = find_job('container_id_type=chat')
  lu.assertNotNil(fetch_job)
  local url = table.concat(fetch_job.cmd, ' ')
  lu.assertStrContains(url, 'start_time=')
  -- future timestamp clamped to now: start_time < os.time()
  local start_time = tonumber(url:match('start_time=(%d+)'))
  lu.assertTrue(start_time <= os.time() + 1, 'future start_time clamped')
end

function TestLarkIntegration:test_send_message_flows_through_token()
  self.lark.send_message('hello world')
  wait(100)
  local token_id = find_job('tenant_access_token')
  lu.assertNotNil(token_id, 'token fetched before send')
  job.emit_stdout(token_id, { TOKEN_JSON })
  wait(100)
  local _, send_job = find_job('receive_id_type=chat_id')
  lu.assertNotNil(send_job, 'send job started')
  lu.assertNotNil(send_job.stdin[1])
  local body = vim.json.decode(send_job.stdin[1])
  lu.assertEquals(body.receive_id, 'oc_test_chat')
  lu.assertEquals(body.msg_type, 'text')
  lu.assertEquals(vim.json.decode(body.content).text, 'hello world')
  lu.assertStrContains(table.concat(send_job.cmd, ' '), 'Bearer t-abc123')
  job.emit_exit(1, 0)
end

function TestLarkIntegration:test_send_message_chunks_long_content()
  local long = string.rep('a', 40000)
  self.lark.send_message(long)
  wait(100)
  local token_id = find_job('tenant_access_token')
  job.emit_stdout(token_id, { TOKEN_JSON })
  wait(100)
  local send_id, send_job = find_job('receive_id_type=chat_id')
  lu.assertNotNil(send_job)
  local body = vim.json.decode(send_job.stdin[1])
  lu.assertTrue(#vim.json.decode(body.content).text <= 30720, 'first chunk within limit')
  -- second chunk queued until first job exits
  job.emit_exit(send_id, 0)
  wait(200)
  local _, send_job2 = find_job('receive_id_type=chat_id')
  lu.assertNotNil(send_job2, 'second chunk sent after first completes')
end

function TestLarkIntegration:test_cleanup_disconnects()
  self.lark.connect(function() end)
  wait(100)
  self.lark.cleanup()
  wait(50)
  lu.assertTrue(true, 'cleanup without error')
end

function TestLarkIntegration:test_disconnect_idempotent()
  self.lark.disconnect()
  self.lark.disconnect()
  lu.assertTrue(true)
end

