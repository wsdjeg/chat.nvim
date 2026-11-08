-- Coverage for the container abstraction + p2p support in
-- lua/chat/integrations/lark.lua (ideas/lark-acl-bindings.md Phase 2).
--
-- A group and a p2p conversation are both "containers" to the Lark messages
-- endpoint. What differs is which cursor is used (each container has its own),
-- whether an @mention is required (p2p: no) and where a reply goes (p2p: the
-- peer's open_id).
local lu = require('luaunit')
local job = require('job')
local config = require('chat.config')

local storage_dir

--- Reload the integration with fresh state, pointing STATE_FILE at temp storage.
local function fresh_lark(lark_extra)
  package.loaded['chat.integrations.lark'] = nil
  -- The tenant token cache is shared and survives reloads.
  require('chat.integrations.lark.auth').reset()
  -- config.setup() deep-merges: drop lists from previous specs explicitly
  -- (tbl_deep_extend ignores nil values, direct assignment drops the key).
  if config.config.integrations and config.config.integrations.lark then
    local lark = config.config.integrations.lark
    lark.acl = nil
    lark.p2p = nil
    lark.chat_id = nil
  end
  config.setup({
    storage_dir = storage_dir,
    integrations = {
      lark = vim.tbl_deep_extend('force', {
        app_id = 'cli_test_app',
        app_secret = 'secret_test',
        chat_id = 'oc_main',
      }, lark_extra or {}),
    },
  })
  return require('chat.integrations.lark')
end

TestLarkContainer = {}

local function wait(ms)
  vim.wait(ms or 300, function()
    return false
  end, 20)
end

--- Find a started job whose command contains the given fragment.
local function find_job(fragment)
  for id, j in pairs(job.jobs) do
    if table.concat(j.cmd, ' '):find(fragment, 1, true) then
      return id, j
    end
  end
end

local TOKEN_JSON = vim.json.encode({
  tenant_access_token = 't-abc123',
  expire = 7200,
})

local BOT_JSON = vim.json.encode({ bot = { open_id = 'ou_bot_1' } })

local function feed_token_and_bot()
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

--- Write a state file before connect() so load_state() is exercised.
local function write_state(data)
  local dir = storage_dir .. 'integration'
  vim.fn.mkdir(dir, 'p')
  vim.fn.writefile({ vim.json.encode(data) }, dir .. '/lark.json')
end

local function read_state()
  local path = storage_dir .. 'integration/lark.json'
  if vim.fn.filereadable(path) ~= 1 then
    return nil
  end
  local ok, data = pcall(vim.json.decode, table.concat(vim.fn.readfile(path)))
  return ok and data or nil
end

local function make_msg(id, text, opts)
  opts = opts or {}
  return {
    message_id = id,
    chat_id = opts.chat_id or 'oc_main',
    create_time = opts.create_time or '1700000000000',
    msg_type = 'text',
    body = { content = vim.json.encode({ text = text }) },
    mentions = opts.mentions or {},
    sender = {
      id = opts.sender_id or 'ou_user_9',
      sender_type = opts.sender_type or 'user',
    },
  }
end

--- Deliver one fetch response for a specific container.
local function deliver(container_id, items)
  local fetch_id = find_job('container_id=' .. container_id)
  lu.assertNotNil(fetch_id, 'fetch job started for ' .. container_id)
  job.emit_stdout(fetch_id, {
    vim.json.encode({ data = { items = items } }),
  })
  job.emit_exit(fetch_id, 0)
  wait(200)
end

function TestLarkContainer:setUp()
  job.reset()
  job.intercept()
  storage_dir = vim.fn.tempname() .. '_lark_container_test/'
  vim.fn.mkdir(storage_dir, 'p')
  self.lark = fresh_lark()
end

function TestLarkContainer:tearDown()
  job.intercept(false)
  self.lark.disconnect()
  wait(100)
  vim.fn.delete(storage_dir, 'rf')
end

-- ===========================================================================
-- Containers and cursors
-- ===========================================================================

function TestLarkContainer:test_legacy_state_seeds_main_container()
  -- A state file written before the container abstraction has no
  -- `containers` key: the main container is derived from `chat_id` and the
  -- legacy cursor is used, so behaviour is identical to the old version.
  local future_ms = tostring((os.time() + 3600) * 1000)
  write_state({
    last_message_id = 'om_prev',
    last_message_time = future_ms,
    processed_ids = {},
    session = 'sess-legacy',
  })

  self.lark = fresh_lark()
  self.lark.connect(function() end)
  wait(200)
  feed_token_and_bot()

  local _, fetch_job = find_job('container_id=oc_main')
  lu.assertNotNil(fetch_job, 'main container polled')
  local url = table.concat(fetch_job.cmd, ' ')
  lu.assertStrContains(url, 'start_time=')
  -- future timestamps are clamped to "now", same guard as before
  local start_time = tonumber(url:match('start_time=(%d+)'))
  lu.assertTrue(start_time <= os.time() + 1)
  lu.assertEquals('sess-legacy', self.lark.current_session())
end

function TestLarkContainer:test_container_cursor_isolation()
  -- Two containers with different cursors. A shared (global) cursor would
  -- make the quiet one unfetchable: the active chat would keep pushing it
  -- forward past the quiet chat's messages.
  write_state({
    session = nil,
    containers = {
      oc_main = {
        chat_type = 'group',
        last_seen_time = '1700000005000',
      },
      oc_p2p = {
        chat_type = 'p2p',
        peer = 'ou_peer',
      },
    },
  })

  self.lark = fresh_lark()
  self.lark.connect(function() end)
  wait(200)
  feed_token_and_bot()

  -- oc_main is fetched first (ids are sorted): it has a cursor
  local _, main_job = find_job('container_id=oc_main')
  lu.assertNotNil(main_job)
  lu.assertStrContains(table.concat(main_job.cmd, ' '), 'start_time=')
  job.emit_stdout(find_job('container_id=oc_main'), {
    vim.json.encode({ data = { items = {} } }),
  })
  job.emit_exit(find_job('container_id=oc_main'), 0)
  wait(200)

  -- oc_p2p has no cursor of its own: it must NOT inherit oc_main's cursor
  local _, p2p_job = find_job('container_id=oc_p2p')
  lu.assertNotNil(p2p_job, 'p2p container polled after main')
  local url = table.concat(p2p_job.cmd, ' ')
  lu.assertNotStrContains(url, 'start_time=', 'cursor is per container')

  -- Advancing the p2p cursor leaves the main cursor untouched
  job.emit_stdout(find_job('container_id=oc_p2p'), {
    vim.json.encode({
      data = { items = { make_msg('om_p2p', 'hi', {
        chat_id = 'oc_p2p',
        create_time = '1700000009000',
        sender_id = 'ou_peer',
      }) } },
    }),
  })
  job.emit_exit(find_job('container_id=oc_p2p'), 0)
  wait(200)

  local state = read_state()
  lu.assertNotNil(state)
  lu.assertEquals('1700000009000', state.containers.oc_p2p.last_seen_time)
  lu.assertEquals('1700000005000', state.containers.oc_main.last_seen_time)
end

function TestLarkContainer:test_containers_survive_reload()
  self.lark.add_container('oc_p2p', { chat_type = 'p2p', peer = 'ou_peer' })
  self.lark.set_binding('oc_p2p', 'sess-p2p')

  self.lark = fresh_lark()
  self.lark.connect(function() end)
  wait(200)

  lu.assertEquals('sess-p2p', self.lark.get_binding('oc_p2p'))
  local list = self.lark.get_containers()
  local found
  for _, ctr in ipairs(list) do
    if ctr.chat_id == 'oc_p2p' then
      found = ctr
    end
  end
  lu.assertNotNil(found)
  lu.assertEquals('p2p', found.chat_type)
  lu.assertEquals('ou_peer', found.peer)
end

function TestLarkContainer:test_add_container_rejects_nil()
  lu.assertFalse(self.lark.add_container(nil))
  lu.assertEquals(0, #self.lark.get_containers())
end

-- ===========================================================================
-- p2p: no mention required, deny by default
-- ===========================================================================

function TestLarkContainer:test_p2p_message_delivered_without_mention()
  write_state({
    containers = {
      oc_main = { chat_type = 'group' },
      oc_p2p = { chat_type = 'p2p', peer = 'ou_peer' },
    },
  })

  local received = {}
  self.lark = fresh_lark({ p2p = { allow = { 'ou_peer' } } })
  self.lark.connect(function(msg)
    received[#received + 1] = msg
  end)
  wait(200)
  feed_token_and_bot()

  -- drain the main container first so the p2p fetch starts
  deliver('oc_main', {})
  deliver('oc_p2p', {
    make_msg('om_dm', 'hello bot', {
      chat_id = 'oc_p2p',
      sender_id = 'ou_peer',
      mentions = {},
    }),
  })

  lu.assertEquals(1, #received, 'p2p message needs no @mention')
  lu.assertEquals('hello bot', received[1].content)
  lu.assertEquals('oc_p2p', received[1].chat_id)
  lu.assertEquals('p2p', received[1].chat_type)
end

function TestLarkContainer:test_p2p_peer_not_in_allow_list_is_ignored()
  write_state({
    containers = {
      oc_main = { chat_type = 'group' },
      oc_p2p = { chat_type = 'p2p', peer = 'ou_peer' },
    },
  })

  local received = {}
  self.lark = fresh_lark({ p2p = { allow = { 'ou_someone_else' } } })
  self.lark.connect(function(msg)
    received[#received + 1] = msg
  end)
  wait(200)
  feed_token_and_bot()

  deliver('oc_main', {})
  deliver('oc_p2p', {
    make_msg('om_dm', 'hello bot', {
      chat_id = 'oc_p2p',
      sender_id = 'ou_peer',
    }),
  })

  lu.assertEquals(0, #received, 'unlisted peer is refused')
end

function TestLarkContainer:test_p2p_sender_mismatch_is_ignored()
  -- Only the registered peer is trusted inside a p2p container.
  write_state({
    containers = {
      oc_main = { chat_type = 'group' },
      oc_p2p = { chat_type = 'p2p', peer = 'ou_peer' },
    },
  })

  local received = {}
  self.lark = fresh_lark({ p2p = { allow = { 'ou_peer' } } })
  self.lark.connect(function(msg)
    received[#received + 1] = msg
  end)
  wait(200)
  feed_token_and_bot()

  deliver('oc_main', {})
  deliver('oc_p2p', {
    make_msg('om_dm', 'hello bot', {
      chat_id = 'oc_p2p',
      sender_id = 'ou_evil',
    }),
  })

  lu.assertEquals(0, #received, 'sender mismatch is dropped')
end

function TestLarkContainer:test_group_still_requires_mention()
  local received = {}
  self.lark.connect(function(msg)
    received[#received + 1] = msg
  end)
  wait(200)
  feed_token_and_bot()

  deliver('oc_main', { make_msg('om_plain', 'no mention here') })

  lu.assertEquals(0, #received, 'groups keep the @mention requirement')
end

function TestLarkContainer:test_is_p2p_allowed_defaults_to_deny()
  self.lark = fresh_lark({ acl = { mode = 'allow_all' } })
  -- allow_all is a statement about the bound group, not about DMs
  lu.assertFalse(self.lark.is_p2p_allowed('ou_anyone'))
  lu.assertFalse(self.lark.is_p2p_allowed(nil))
end

function TestLarkContainer:test_is_p2p_allowed_falls_back_to_acl_lists()
  self.lark = fresh_lark({
    acl = { admins = { 'ou_admin' }, whitelist = { 'ou_alice' } },
  })
  lu.assertTrue(self.lark.is_p2p_allowed('ou_admin'))
  lu.assertTrue(self.lark.is_p2p_allowed('ou_alice'))
  lu.assertFalse(self.lark.is_p2p_allowed('ou_bob'))
end

function TestLarkContainer:test_is_p2p_allowed_explicit_list_is_authoritative()
  -- An explicit `p2p.allow` is the whole policy: it does not silently widen
  -- back to admins, otherwise one typo would quietly let every admin in.
  self.lark = fresh_lark({
    acl = { admins = { 'ou_admin' } },
    p2p = { allow = { 'ou_alice' } },
  })
  lu.assertTrue(self.lark.is_p2p_allowed('ou_alice'))
  lu.assertFalse(self.lark.is_p2p_allowed('ou_admin'))
end

-- ===========================================================================
-- Bindings and reply routing
-- ===========================================================================

function TestLarkContainer:test_bindings_are_per_chat()
  self.lark.set_binding('oc_a', 'sess-a')
  lu.assertEquals('sess-a', self.lark.get_binding('oc_a'))
  lu.assertNil(self.lark.current_session(), 'set_binding touches one chat only')

  self.lark.set_session('sess-main')
  lu.assertEquals('sess-main', self.lark.current_session())
  -- the platform session is mirrored onto the main container
  lu.assertEquals('sess-main', self.lark.get_binding('oc_main'))
  lu.assertEquals({ 'sess-a', 'sess-main' }, self.lark.get_bound_sessions())
end

function TestLarkContainer:test_send_message_defaults_to_main_container()
  self.lark.send_message('hello')
  wait(100)
  local token_id = find_job('tenant_access_token')
  lu.assertNotNil(token_id)
  job.emit_stdout(token_id, { TOKEN_JSON })
  wait(100)

  local _, send_job = find_job('receive_id_type=chat_id')
  lu.assertNotNil(send_job, 'single-arg send targets the configured chat')
  local body = vim.json.decode(send_job.stdin[1])
  lu.assertEquals('oc_main', body.receive_id)
  job.emit_exit(find_job('receive_id_type=chat_id'), 0)
end

function TestLarkContainer:test_send_message_routes_p2p_to_peer_open_id()
  self.lark.add_container('oc_p2p', { chat_type = 'p2p', peer = 'ou_peer' })
  self.lark.set_binding('oc_p2p', 'sess-p2p')

  self.lark.send_message('hi there', 'sess-p2p')
  wait(100)
  local token_id = find_job('tenant_access_token')
  job.emit_stdout(token_id, { TOKEN_JSON })
  wait(100)

  local send_id, send_job = find_job('receive_id_type=open_id')
  lu.assertNotNil(send_job, 'p2p replies address the peer open_id')
  local body = vim.json.decode(send_job.stdin[1])
  lu.assertEquals('ou_peer', body.receive_id)
  job.emit_exit(send_id, 0)
end

function TestLarkContainer:test_send_message_unknown_session_falls_back_to_main()
  self.lark.send_message('hello', 'sess-unknown')
  wait(100)
  job.emit_stdout(find_job('tenant_access_token'), { TOKEN_JSON })
  wait(100)

  local _, send_job = find_job('receive_id_type=chat_id')
  lu.assertNotNil(send_job)
  lu.assertEquals('oc_main', vim.json.decode(send_job.stdin[1]).receive_id)
end

-- ===========================================================================
-- p2p discovery (create_p2p)
-- ===========================================================================

function TestLarkContainer:test_create_p2p_refuses_unlisted_open_id()
  self.lark = fresh_lark({ p2p = { allow = { 'ou_alice' } } })
  local result
  self.lark.create_p2p('ou_bob', function(ok, msg)
    result = { ok = ok, msg = msg }
  end)
  wait(50)
  lu.assertNotNil(result)
  lu.assertFalse(result.ok)
  lu.assertStrContains(result.msg, 'not allowed')
end

function TestLarkContainer:test_create_p2p_rejects_empty_open_id()
  local result
  self.lark.create_p2p('', function(ok, msg)
    result = { ok = ok, msg = msg }
  end)
  wait(50)
  lu.assertFalse(result.ok)
end

function TestLarkContainer:test_create_p2p_discovers_chat_id()
  self.lark = fresh_lark({ p2p = { allow = { 'ou_peer' }, greeting = 'hello!' } })
  local result
  self.lark.create_p2p('ou_peer', function(ok, msg)
    result = { ok = ok, msg = msg }
  end)
  wait(100)

  -- create_p2p resolves the tenant token first (cold cache here), so the
  -- greeting request only starts once the token job answers.
  local token_id = find_job('tenant_access_token')
  lu.assertNotNil(token_id, 'token requested before the greeting')
  job.emit_stdout(token_id, { TOKEN_JSON })
  wait(100)

  -- step 1: greeting is sent to the open_id
  local send_id, send_job = find_job('receive_id_type=open_id')
  lu.assertNotNil(send_job)
  local body = vim.json.decode(send_job.stdin[1])
  lu.assertEquals('ou_peer', body.receive_id)
  lu.assertEquals('hello!', vim.json.decode(body.content).text)

  -- step 2: the message detail carries the p2p chat_id
  job.emit_stdout(send_id, {
    vim.json.encode({ code = 0, data = { message_id = 'om_greet' } }),
  })
  job.emit_exit(send_id, 0)
  wait(100)

  local _, detail_job = find_job('/im/v1/messages/om_greet')
  lu.assertNotNil(detail_job, 'message detail requested')
  job.emit_stdout(find_job('/im/v1/messages/om_greet'), {
    vim.json.encode({ code = 0, data = { items = { { chat_id = 'oc_new_p2p' } } } }),
  })
  job.emit_exit(find_job('/im/v1/messages/om_greet'), 0)
  wait(100)

  lu.assertTrue(result.ok)
  lu.assertEquals('oc_new_p2p', result.msg)

  -- step 3: the container is registered so the poller starts reading it
  local found
  for _, ctr in ipairs(self.lark.get_containers()) do
    if ctr.chat_id == 'oc_new_p2p' then
      found = ctr
    end
  end
  lu.assertNotNil(found)
  lu.assertEquals('p2p', found.chat_type)
  lu.assertEquals('ou_peer', found.peer)
end

function TestLarkContainer:test_create_p2p_reuses_known_container()
  self.lark = fresh_lark({ p2p = { allow = { 'ou_peer' } } })
  self.lark.add_container('oc_existing', {
    chat_type = 'p2p',
    peer = 'ou_peer',
  })

  local result
  self.lark.create_p2p('ou_peer', function(ok, msg)
    result = { ok = ok, msg = msg }
  end)
  wait(50)

  lu.assertTrue(result.ok)
  lu.assertEquals('oc_existing', result.msg)
  lu.assertNil(find_job('receive_id_type=open_id'), 'no greeting for a known chat')
end

return TestLarkContainer

