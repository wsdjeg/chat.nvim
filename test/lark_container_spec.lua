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
        -- p2p workspaces must never land in the repository root:
        -- `p2p_cwd_root()` falls back to `allowed_path` when unset, so point
        -- it at this spec's temp storage instead.
        p2p = { cwd_root = storage_dir },
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

function TestLarkContainer:test_startup_resets_cursor_to_now()
  -- The cached cursor says where the previous run stopped, not a queue to
  -- replay: an hours-old cursor makes the first tick fetch everything sent
  -- while the plugin was down and answer it in one burst. connect() therefore
  -- moves the cursor to "now" and writes it back before the first poll.
  write_state({
    last_message_id = 'om_old',
    last_message_time = '1700000005000',
    processed_ids = { om_old = true },
    containers = {
      oc_main = {
        chat_type = 'group',
        last_seen_time = '1700000005000',
      },
    },
  })

  local before = os.time()
  self.lark = fresh_lark()
  self.lark.connect(function() end)
  wait(200)
  feed_token_and_bot()

  -- Persisted right away, so a crash before the first tick keeps the reset.
  local state = read_state()
  lu.assertNotNil(state)
  local cursor = tonumber(state.containers.oc_main.last_seen_time)
  lu.assertTrue(cursor >= before * 1000, 'cursor moved forward to now')
  lu.assertTrue(cursor <= (os.time() + 1) * 1000, 'cursor is not in the future')
  -- The legacy mirror follows the main container.
  lu.assertEquals(
    state.containers.oc_main.last_seen_time,
    state.last_message_time
  )
  -- Leftover ids still guard the boundary with the previous session.
  lu.assertTrue(state.processed_ids.om_old)

  local _, fetch_job = find_job('container_id=oc_main')
  lu.assertNotNil(fetch_job)
  local start_time =
    tonumber(table.concat(fetch_job.cmd, ' '):match('start_time=(%d+)'))
  lu.assertTrue(start_time >= before, 'poll resumes from now, not from cache')

  -- Settle the request: an unanswered fetch leaves its 5s watchdog alive, and
  -- that timer would fire in a later spec and spawn a stray token job there.
  deliver('oc_main', {})
end

function TestLarkContainer:test_container_cursor_isolation()
  -- Cursors stay per container: a shared (global) one would let the active
  -- chat keep pushing the quiet chat's cursor forward past its messages.
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

  -- Both containers start at "now": the startup reset replaces the stale
  -- cursor and also seeds the container that had none, so neither can read
  -- the backlog.
  local _, main_job = find_job('container_id=oc_main')
  lu.assertNotNil(main_job)
  lu.assertStrContains(table.concat(main_job.cmd, ' '), 'start_time=')
  deliver('oc_main', {})

  local _, p2p_job = find_job('container_id=oc_p2p')
  lu.assertNotNil(p2p_job, 'p2p container polled after main')
  lu.assertStrContains(
    table.concat(p2p_job.cmd, ' '),
    'start_time=',
    'every container gets a startup cursor'
  )

  -- A message in p2p advances that cursor only.
  local new_ms = tostring((os.time() + 60) * 1000)
  deliver('oc_p2p', {
    make_msg('om_p2p', 'hi', {
      chat_id = 'oc_p2p',
      create_time = new_ms,
      sender_id = 'ou_peer',
    }),
  })

  local state = read_state()
  lu.assertNotNil(state)
  lu.assertEquals(new_ms, state.containers.oc_p2p.last_seen_time)
  lu.assertNotEquals(new_ms, state.containers.oc_main.last_seen_time)
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

-- ===========================================================================
-- Reply routing regression: a p2p message must never be answered in the group
-- ===========================================================================

function TestLarkContainer:test_p2p_container_owns_its_session()
  -- Regression: a p2p container without a session inherited the platform
  -- session through `current_session()`, so `on_response` matched the
  -- first branch, called `send_message(content)` without a session and the
  -- answer landed in the configured group instead of the private chat.
  --
  -- Deliberately polling-free: the bug lived in session resolution, so the
  -- assertion is on `get_binding()` (which the shared layer calls) rather
  -- than on a timed fetch.
  self.lark = fresh_lark()
  self.lark.add_container('oc_p2p', { chat_type = 'p2p', peer = 'ou_peer' })
  -- The platform session is what made the bug visible: it is the value an
  -- unbound container falls back to.
  self.lark.set_session('sess-main')

  -- The p2p chat owns a session of its own, derived from its chat id and
  -- therefore stable across restarts.
  lu.assertEquals('lark-oc_p2p', self.lark.get_binding('oc_p2p'))
  lu.assertNotEquals(
    'sess-main',
    self.lark.get_binding('oc_p2p'),
    'p2p must not borrow the group session'
  )
  -- The main container keeps the platform session.
  lu.assertEquals('sess-main', self.lark.get_binding('oc_main'))

  -- Reply for that session goes to the peer's open_id, never to oc_main.
  self.lark.send_message('I am just a plugin', 'lark-oc_p2p')
  wait(100)
  job.emit_stdout(find_job('tenant_access_token'), { TOKEN_JSON })
  wait(100)

  local send_id, send_job = find_job('receive_id_type=open_id')
  lu.assertNotNil(send_job, 'reply addressed to the p2p peer')
  lu.assertEquals('ou_peer', vim.json.decode(send_job.stdin[1]).receive_id)
  lu.assertNil(
    find_job('receive_id_type=chat_id'),
    'the group must not receive this reply'
  )
  job.emit_exit(send_id, 0)
end

function TestLarkContainer:test_container_session_is_stable_across_reload()
  -- The derived id is intentional: losing the state file must not create a
  -- fresh session and a fresh context for an existing conversation.
  self.lark.add_container('oc_p2p', { chat_type = 'p2p', peer = 'ou_peer' })
  lu.assertEquals('lark-oc_p2p', self.lark.get_binding('oc_p2p'))

  -- Reload with no state file at all: the same chat id must resolve to the
  -- very same session, so the conversation keeps its history.
  vim.fn.delete(storage_dir, 'rf')
  vim.fn.mkdir(storage_dir, 'p')
  self.lark = fresh_lark()
  self.lark.add_container('oc_p2p', { chat_type = 'p2p', peer = 'ou_peer' })

  lu.assertEquals('lark-oc_p2p', self.lark.get_binding('oc_p2p'))
end

function TestLarkContainer:test_get_binding_nil_chat_falls_back_to_platform_session()
  -- A message without a chat id (every integration other than lark) keeps
  -- resolving through the platform session.
  self.lark.set_session('sess-platform')
  lu.assertNil(self.lark.get_binding(nil))
  lu.assertEquals('sess-platform', self.lark.current_session())
end

-- ===========================================================================
-- Automatic p2p container provisioning
-- ===========================================================================

function TestLarkContainer:test_provision_list_prefers_p2p_allow()
  self.lark = fresh_lark({
    acl = { admins = { 'ou_admin' } },
    p2p = { allow = { 'ou_alice', 'ou_bob', 'ou_alice' } },
  })
  -- An explicit p2p.allow is the whole policy, admins included.
  lu.assertEquals({ 'ou_alice', 'ou_bob' }, self.lark.get_p2p_provision_list())
end

function TestLarkContainer:test_provision_list_falls_back_to_admins()
  -- No p2p.allow: admins are the only curated set. `acl.whitelist` is
  -- deliberately excluded, otherwise a long whitelist would be greeted on
  -- every connect.
  self.lark = fresh_lark({
    acl = { admins = { 'ou_admin' }, whitelist = { 'ou_member' } },
  })
  lu.assertEquals({ 'ou_admin' }, self.lark.get_p2p_provision_list())
end

function TestLarkContainer:test_provision_list_empty_config()
  self.lark = fresh_lark()
  lu.assertEquals({}, self.lark.get_p2p_provision_list())
end

function TestLarkContainer:test_connect_provisions_admin_p2p_chat()
  -- A polling bot can not learn a p2p chat id from an inbound message, so the
  -- admin's conversation has to be opened from this side on connect.
  self.lark = fresh_lark({ acl = { admins = { 'ou_admin' } } })
  self.lark.connect(function() end)
  wait(200)
  feed_token_and_bot()

  -- step 1: greeting goes to the admin's open_id
  local send_id, send_job = find_job('receive_id_type=open_id')
  lu.assertNotNil(send_job, 'greeting sent to the provisioned admin')
  lu.assertEquals(
    'ou_admin',
    vim.json.decode(send_job.stdin[1]).receive_id
  )

  -- step 2: the message detail reveals the chat id
  job.emit_stdout(send_id, {
    vim.json.encode({ code = 0, data = { message_id = 'om_prov' } }),
  })
  job.emit_exit(send_id, 0)
  wait(100)

  local detail_id = find_job('/im/v1/messages/om_prov')
  lu.assertNotNil(detail_id, 'message detail requested')
  job.emit_stdout(detail_id, {
    vim.json.encode({
      code = 0,
      data = { items = { { chat_id = 'oc_admin_p2p' } } },
    }),
  })
  job.emit_exit(detail_id, 0)
  wait(100)

  -- step 3: registered as a p2p container with its own session, so it is
  -- polled and replies are routed to the peer
  local found
  for _, ctr in ipairs(self.lark.get_containers()) do
    if ctr.chat_id == 'oc_admin_p2p' then
      found = ctr
    end
  end
  lu.assertNotNil(found, 'p2p container registered automatically')
  lu.assertEquals('p2p', found.chat_type)
  lu.assertEquals('ou_admin', found.peer)
  lu.assertEquals('lark-oc_admin_p2p', found.session)
end

function TestLarkContainer:test_connect_provisions_p2p_allow_entries()
  self.lark = fresh_lark({ p2p = { allow = { 'ou_alice' } } })
  self.lark.connect(function() end)
  wait(200)
  feed_token_and_bot()

  lu.assertNotNil(
    find_job('receive_id_type=open_id'),
    'p2p.allow is the provisioning list'
  )
end

function TestLarkContainer:test_connect_skips_known_p2p_container()
  self.lark = fresh_lark({ p2p = { allow = { 'ou_peer' } } })
  self.lark.add_container('oc_known', { chat_type = 'p2p', peer = 'ou_peer' })

  self.lark.connect(function() end)
  wait(200)
  feed_token_and_bot()

  lu.assertNil(
    find_job('receive_id_type=open_id'),
    'a known chat is reused, no greeting is re-sent'
  )
end

function TestLarkContainer:test_provisioning_can_be_disabled()
  self.lark = fresh_lark({
    acl = { admins = { 'ou_admin' } },
    p2p = { auto_create = false },
  })
  self.lark.connect(function() end)
  wait(200)
  feed_token_and_bot()

  lu.assertNil(
    find_job('receive_id_type=open_id'),
    'p2p.auto_create = false disables provisioning'
  )
end

function TestLarkContainer:test_provision_p2p_ignored_while_disconnected()
  -- connect() provisions on its own; a manual call while the poller is down
  -- must not fire requests.
  self.lark.provision_p2p({ 'ou_admin' })
  wait(50)
  lu.assertNil(find_job('receive_id_type=open_id'))
end

function TestLarkContainer:test_in_chat_allow_provisions_new_p2p_chat()
  -- `/allow @user` grants access; provisioning opens the DM right away so the
  -- user is polled before they type anything.
  --
  -- The admin's own container is registered up front, so connect-time
  -- provisioning has nothing to send and the greeting observed below can only
  -- come from the `/allow` command.
  self.lark = fresh_lark({
    acl = { mode = 'allow_all', admins = { 'ou_admin' } },
  })
  self.lark.add_container('oc_admin_p2p', {
    chat_type = 'p2p',
    peer = 'ou_admin',
  })
  self.lark.connect(function() end)
  wait(200)
  feed_token_and_bot()

  lu.assertNil(
    find_job('receive_id_type=open_id'),
    'no greeting for an already known admin'
  )

  -- Polling is sequential and `oc_admin_p2p` sorts before `oc_main`, so the
  -- main container is only fetched once the p2p request has settled.
  deliver('oc_admin_p2p', {})
  deliver('oc_main', {
    make_msg('om_allow_new', '@_user_1 /allow @_user_2', {
      sender_id = 'ou_admin',
      mentions = {
        { id = 'ou_bot_1', key = '@_user_1', name = 'chat.nvim' },
        { id = 'ou_target', key = '@_user_2', name = 'Zhang San' },
      },
    }),
  })
  wait(150)

  local _, send_job = find_job('receive_id_type=open_id')
  lu.assertNotNil(send_job, 'the newly allowed user gets a p2p chat')
  lu.assertEquals('ou_target', vim.json.decode(send_job.stdin[1]).receive_id)
end

-- ===========================================================================
-- Stale bindings: a binding must not outlive its session
-- ===========================================================================

function TestLarkContainer:test_stale_lark_binding_is_recreated()
  -- Deleting a session leaves the container pointing at an id that no longer
  -- exists. `chat_session()` used to return it verbatim, so the chat resolved
  -- to a dead session: replies were written and never delivered, and the
  -- conversation looked silently broken.
  self.lark.add_container('oc_p2p', { chat_type = 'p2p', peer = 'ou_peer' })
  self.lark.set_binding('oc_p2p', 'lark-oc_gone')

  -- Resolving the chat drops the dead binding and gives the conversation a
  -- working session again (the derived id is stable, so it is recreated).
  lu.assertEquals('lark-oc_p2p', self.lark.get_binding('oc_p2p'))
  lu.assertTrue(require('chat.sessions').exists('lark-oc_p2p'))

  -- The stale id is gone from the persisted state as well; the recreated
  -- binding carries the derived id.
  local state = read_state()
  lu.assertNotNil(state)
  lu.assertEquals('lark-oc_p2p', state.containers.oc_p2p.session)
end

function TestLarkContainer:test_hand_written_binding_is_not_dropped()
  -- A binding pointed at a session this module did not derive belongs to the
  -- user: dropping it would silently throw away their choice.
  self.lark.add_container('oc_p2p', { chat_type = 'p2p', peer = 'ou_peer' })
  self.lark.set_binding('oc_p2p', 'my-own-session')
  lu.assertEquals('my-own-session', self.lark.get_binding('oc_p2p'))
end

function TestLarkContainer:test_get_bound_sessions_skips_stale_bindings()
  self.lark.set_session('lark-main-gone')
  lu.assertEquals({}, self.lark.get_bound_sessions())
  lu.assertEquals({}, self.lark.get_chat_bindings('lark-main-gone'))
end

function TestLarkContainer:test_get_bound_sessions_keeps_live_bindings()
  self.lark.set_session('sess-live')
  lu.assertEquals({ 'sess-live' }, self.lark.get_bound_sessions())
end

return TestLarkContainer

