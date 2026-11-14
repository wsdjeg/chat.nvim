-- Coverage for the parts of the Telegram integration that make it behave like
-- Lark: private chats (p2p), groups (mention required), per-chat containers and
-- sessions, and the in-chat ACL commands (/allow, /deny, /acl).
--
-- These were implemented but never verified, so every test here is about the
-- behaviour a user can actually observe: a DM is answered without an @mention,
-- a DM from a non-allowed peer is not, a group message is ignored unless the
-- bot is addressed, and a reply goes back to the chat the message came from
-- instead of the configured main chat.
local lu = require('luaunit')
local job = require('job')
local config = require('chat.config')
local sessions = require('chat.sessions')

local storage_dir

local function wait(ms)
  vim.wait(ms or 200, function()
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

--- Request body of an intercepted job: inline `-d <json>` or stdin.
local function request_body(j)
  if not j then
    return nil
  end
  for i, a in ipairs(j.cmd) do
    if a == '-d' and j.cmd[i + 1] and j.cmd[i + 1] ~= '@-' then
      return vim.json.decode(j.cmd[i + 1])
    end
  end
  if j.stdin and j.stdin[1] then
    return vim.json.decode(j.stdin[1])
  end
  return nil
end

--- Reload the integration with fresh state and the given telegram config.
---
--- `config.setup()` deep-merges, so lists left by a previous spec have to be
--- dropped explicitly (tbl_deep_extend ignores nil values).
local function fresh_telegram(telegram_extra)
  package.loaded['chat.integrations.telegram'] = nil
  if config.config.integrations and config.config.integrations.telegram then
    local tg = config.config.integrations.telegram
    tg.acl = nil
    tg.p2p = nil
  end
  config.setup({
    storage_dir = storage_dir,
    integrations = {
      telegram = vim.tbl_deep_extend('force', {
        bot_token = 'tg-token-1',
        chat_id = '555',
        -- p2p workspaces must never land in the repository root:
        -- p2p_cwd_root() falls back to allowed_path when unset.
        p2p = { cwd_root = storage_dir .. 'p2p' },
      }, telegram_extra or {}),
    },
  })
  sessions.set_cache_dir(storage_dir .. 'sessions/')
  return require('chat.integrations.telegram')
end

local function setUp_storage()
  job.reset()
  job.intercept()
  storage_dir = vim.fn.tempname() .. '_tg_chat/'
  vim.fn.mkdir(storage_dir, 'p')
end

local function tearDown_storage(tg)
  if tg then
    tg.disconnect()
  end
  wait(100)
  job.intercept(false)
  vim.fn.delete(storage_dir, 'rf')
end

--- One Telegram update carrying a text message.
local function make_update(id, text, opts)
  opts = opts or {}
  local msg = {
    message_id = opts.message_id or id,
    from = {
      id = opts.from_id or 1000,
      first_name = opts.first_name or 'Tester',
      username = opts.username or 'tester',
      is_bot = opts.is_bot or false,
    },
    chat = {
      id = opts.chat_id or (opts.chat_type == 'private' and (opts.from_id or 1000))
        or 555,
      type = opts.chat_type or 'group',
    },
    text = text,
  }
  if opts.reply_from_id then
    msg.reply_to_message = {
      from = { id = opts.reply_from_id, username = opts.reply_username },
    }
  end
  return { update_id = id, message = msg }
end

--- Connect, answer getMe with a known bot identity, return the poll jobid.
local function connect_with_bot(tg, received)
  tg.connect(function(msg)
    received[#received + 1] = msg
  end)
  wait(200)
  local getme_id = find_job('getMe')
  lu.assertNotNil(getme_id, 'getMe request on connect')
  job.emit_stdout(getme_id, {
    vim.json.encode({
      ok = true,
      result = { id = 999, username = 'chatnvim_bot' },
    }),
  })
  wait(200)
  local fetch_id = find_job('getUpdates')
  lu.assertNotNil(fetch_id, 'polling started')
  return fetch_id
end

local function deliver(fetch_id, updates)
  job.emit_stdout(fetch_id, {
    vim.json.encode({ ok = true, result = updates }),
  })
  wait(300)
end

-- ═════════════════════ ACL / p2p policy ═════════════════════

TestTelegramAcl = {}

function TestTelegramAcl:setUp()
  setUp_storage()
  self.tg = fresh_telegram()
end

function TestTelegramAcl:tearDown()
  tearDown_storage(self.tg)
end

function TestTelegramAcl:test_p2p_default_allowed()
  lu.assertTrue(self.tg.is_p2p_allowed({ id = '1000' }))
  lu.assertTrue(self.tg.is_p2p_allowed('1000'), 'bare id accepted')
end

function TestTelegramAcl:test_p2p_disabled()
  self.tg = fresh_telegram({ p2p = { enable = false } })
  lu.assertFalse(self.tg.is_p2p_allowed({ id = '1000' }))
end

function TestTelegramAcl:test_p2p_explicit_list_is_authoritative()
  self.tg = fresh_telegram({ p2p = { allow = { 1000 } } })
  lu.assertTrue(self.tg.is_p2p_allowed({ id = '1000' }))
  -- An explicit list is the whole policy: no fallback to allow_all.
  lu.assertFalse(self.tg.is_p2p_allowed({ id = '2000' }))
end

function TestTelegramAcl:test_p2p_username_entry_not_trusted()
  -- A username can be taken over, so it must not admit anybody.
  self.tg = fresh_telegram({ p2p = { allow = { '@tester' } } })
  lu.assertFalse(self.tg.is_p2p_allowed({ id = '1000', username = 'tester' }))
end

function TestTelegramAcl:test_p2p_follows_restrictive_acl_mode()
  self.tg = fresh_telegram({
    acl = { mode = 'whitelist', whitelist = { 1000 } },
  })
  lu.assertTrue(self.tg.is_p2p_allowed({ id = '1000' }))
  lu.assertFalse(
    self.tg.is_p2p_allowed({ id = '2000' }),
    'a whitelist governs DMs too'
  )
end

function TestTelegramAcl:test_p2p_nil_sender_denied()
  lu.assertFalse(self.tg.is_p2p_allowed(nil))
  lu.assertFalse(self.tg.is_p2p_allowed({}))
end

function TestTelegramAcl:test_admin_always_allowed()
  self.tg = fresh_telegram({
    acl = { mode = 'whitelist', admins = { 1000 }, whitelist = { 2000 } },
  })
  lu.assertTrue(self.tg.is_admin({ id = '1000' }))
  lu.assertTrue(
    self.tg.is_allowed({ id = '1000' }),
    'admins pass so they can recover a locked-out whitelist'
  )
  lu.assertFalse(self.tg.is_allowed({ id = '3000' }))
end

function TestTelegramAcl:test_runtime_deny_beats_allow_all()
  lu.assertTrue(self.tg.is_allowed({ id = '2000' }))
  lu.assertTrue(self.tg.acl_deny('2000'))
  lu.assertFalse(
    self.tg.is_allowed({ id = '2000' }),
    'a runtime /deny applies even in allow_all mode'
  )
  lu.assertFalse(self.tg.acl_deny('2000'), 'idempotent')
end

function TestTelegramAcl:test_runtime_allow_beats_whitelist()
  self.tg = fresh_telegram({ acl = { mode = 'whitelist', whitelist = { 1000 } } })
  lu.assertFalse(self.tg.is_allowed({ id = '2000' }))
  lu.assertTrue(self.tg.acl_allow(2000), 'numeric entry accepted')
  lu.assertTrue(self.tg.is_allowed({ id = '2000' }))
end

function TestTelegramAcl:test_blacklist_mode()
  self.tg = fresh_telegram({ acl = { mode = 'blacklist', blacklist = { 2000 } } })
  lu.assertFalse(self.tg.is_allowed({ id = '2000' }))
  lu.assertTrue(self.tg.is_allowed({ id = '3000' }))
end

function TestTelegramAcl:test_acl_grants_persist_to_state_file()
  self.tg.acl_deny('2000')
  local path = storage_dir .. 'integration/telegram.json'
  lu.assertEquals(vim.fn.filereadable(path), 1)
  local data = vim.json.decode(table.concat(vim.fn.readfile(path)))
  lu.assertEquals(data.acl.blacklist, { '2000' })
end

function TestTelegramAcl:test_parse_acl_command()
  lu.assertEquals(self.tg.parse_acl_command('/acl'), {
    command = 'acl',
    arg = '',
  })
  lu.assertEquals(self.tg.parse_acl_command('/allow 2000'), {
    command = 'allow',
    arg = '2000',
  })
  lu.assertEquals(self.tg.parse_acl_command('  /deny  '), {
    command = 'deny',
    arg = '',
  })
end

function TestTelegramAcl:test_parse_acl_command_prefix_guard()
  -- `/allowed` must not be read as `/allow`.
  lu.assertNil(self.tg.parse_acl_command('/allowed 2000'))
  lu.assertNil(self.tg.parse_acl_command('/denied 2000'))
  lu.assertNil(self.tg.parse_acl_command('hello /allow'))
  lu.assertNil(self.tg.parse_acl_command(''))
end

function TestTelegramAcl:test_resolve_target_prefers_reply()
  local id, err = self.tg.resolve_target('', { reply_to_message = { from = { id = 42 } } })
  lu.assertNil(err)
  lu.assertEquals(id, '42')
end

function TestTelegramAcl:test_resolve_target_numeric()
  local id = self.tg.resolve_target('777', {})
  lu.assertEquals(id, '777')
  lu.assertEquals(self.tg.resolve_target('-100123', {}), '-100123', 'group ids')
end

function TestTelegramAcl:test_resolve_target_rejects_username()
  local id, err = self.tg.resolve_target('@tester', {})
  lu.assertNil(id)
  lu.assertStrContains(err, 'Reply')
end

function TestTelegramAcl:test_resolve_target_requires_argument()
  local id, err = self.tg.resolve_target('', {})
  lu.assertNil(id)
  lu.assertStrContains(err, 'Usage')
end

function TestTelegramAcl:test_acl_status_lists_runtime_entries()
  self.tg.acl_allow('2000')
  local status = self.tg.acl_status()
  lu.assertStrContains(status, 'ACL mode: allow_all')
  lu.assertStrContains(status, '2000')
  lu.assertStrContains(status, '/allow')
end

-- ═════════════════════ Containers / sessions / bindings ═════════════════════

TestTelegramContainer = {}

function TestTelegramContainer:setUp()
  setUp_storage()
  self.tg = fresh_telegram()
end

function TestTelegramContainer:tearDown()
  tearDown_storage(self.tg)
end

function TestTelegramContainer:test_private_chat_gets_own_session_and_workspace()
  self.tg.add_container('777', { chat_type = 'private', peer = '777' })
  local id = self.tg.chat_session('777')
  lu.assertEquals(id, 'telegram-777')
  lu.assertTrue(sessions.exists(id))

  local dir = storage_dir .. 'p2p/telegram-777'
  lu.assertEquals(
    vim.fn.isdirectory(dir),
    1,
    'a private chat must never share the Neovim cwd with another user'
  )
end

function TestTelegramContainer:test_group_keeps_default_workspace()
  self.tg.add_container('555', { chat_type = 'group' })
  lu.assertNil(self.tg.chat_session('555'), 'main chat uses the platform session')
  lu.assertEquals(
    vim.fn.isdirectory(storage_dir .. 'p2p/telegram-555'),
    0,
    'groups intentionally keep the shared workspace'
  )
end

function TestTelegramContainer:test_two_private_chats_are_isolated()
  self.tg.add_container('777', { chat_type = 'private', peer = '777' })
  self.tg.add_container('888', { chat_type = 'private', peer = '888' })
  local a = self.tg.chat_session('777')
  local b = self.tg.chat_session('888')
  lu.assertEquals(a, 'telegram-777')
  lu.assertEquals(b, 'telegram-888')
  lu.assertNotEquals(a, b)
end

function TestTelegramContainer:test_same_chat_reuses_session()
  self.tg.add_container('777', { chat_type = 'private', peer = '777' })
  lu.assertEquals(self.tg.chat_session('777'), self.tg.chat_session('777'))
end

function TestTelegramContainer:test_set_session_binds_main_container()
  self.tg.set_session('tg-session')
  lu.assertEquals(self.tg.current_session(), 'tg-session')
  lu.assertEquals(self.tg.get_binding('555'), 'tg-session')
  lu.assertEquals(self.tg.get_chat_bindings('tg-session'), { '555' })
end

function TestTelegramContainer:test_set_binding_does_not_touch_platform_session()
  self.tg.set_session('tg-session')
  self.tg.add_container('777', { chat_type = 'private', peer = '777' })
  lu.assertTrue(self.tg.set_binding('777', 'other-session'))
  lu.assertEquals(
    self.tg.current_session(),
    'tg-session',
    'binding a personal chat must not steal the platform session'
  )
  lu.assertEquals(self.tg.get_chat_bindings('other-session'), { '777' })
end

function TestTelegramContainer:test_bound_sessions_lists_bindings()
  self.tg.set_session('tg-session')
  self.tg.add_container('777', { chat_type = 'private', peer = '777' })
  self.tg.chat_session('777')
  local bound = self.tg.get_bound_sessions()
  lu.assertTrue(vim.tbl_contains(bound, 'tg-session'))
  lu.assertTrue(vim.tbl_contains(bound, 'telegram-777'))
end

function TestTelegramContainer:test_get_binding_nil_chat()
  lu.assertNil(self.tg.get_binding(nil))
end

function TestTelegramContainer:test_stale_binding_is_dropped()
  -- A binding can outlive its session (e.g. rotation is missing). Answering
  -- into it would write a reply that is never delivered.
  self.tg.add_container('888', { chat_type = 'private', peer = '888' })
  self.tg.set_binding('888', 'telegram-rotated')
  lu.assertEquals(self.tg.get_chat_bindings('telegram-rotated'), {})
  lu.assertFalse(vim.tbl_contains(self.tg.get_bound_sessions(), 'telegram-rotated'))
end

function TestTelegramContainer:test_stale_binding_heals_on_read()
  self.tg.add_container('888', { chat_type = 'private', peer = '888' })
  self.tg.set_binding('888', 'telegram-rotated')
  local id = self.tg.chat_session('888')
  lu.assertEquals(id, 'telegram-888', 'a dead binding is replaced, not reused')
end

function TestTelegramContainer:test_containers_are_listed()
  self.tg.add_container('777', { chat_type = 'private', peer = '777', title = 'DM' })
  local list = self.tg.get_containers()
  lu.assertEquals(#list, 1)
  lu.assertEquals(list[1].chat_id, '777')
  lu.assertEquals(list[1].chat_type, 'private')
  lu.assertEquals(list[1].peer, '777')
  lu.assertEquals(list[1].title, 'DM')
end

function TestTelegramContainer:test_negative_group_id_is_normalized()
  self.tg.add_container(-1001234567890, { chat_type = 'group' })
  local list = self.tg.get_containers()
  lu.assertEquals(list[1].chat_id, '-1001234567890', 'no scientific notation')
end

-- ═════════════════════ Message routing ═════════════════════

TestTelegramRouting = {}

function TestTelegramRouting:setUp()
  setUp_storage()
  self.tg = fresh_telegram()
end

function TestTelegramRouting:tearDown()
  tearDown_storage(self.tg)
end

function TestTelegramRouting:test_private_message_needs_no_mention()
  local received = {}
  local fetch = connect_with_bot(self.tg, received)
  deliver(fetch, {
    make_update(1, 'hello bot', { chat_type = 'private', from_id = 1000 }),
  })
  lu.assertEquals(#received, 1)
  lu.assertEquals(received[1].content, 'hello bot')
  lu.assertEquals(received[1].chat_type, 'private')
  lu.assertEquals(received[1].chat_id, '1000')
end

function TestTelegramRouting:test_private_message_from_unlisted_peer_dropped()
  self.tg = fresh_telegram({ p2p = { allow = { 1000 } } })
  local received = {}
  local fetch = connect_with_bot(self.tg, received)
  deliver(fetch, {
    make_update(1, 'stranger', { chat_type = 'private', from_id = 2000 }),
  })
  lu.assertEquals(#received, 0)
end

function TestTelegramRouting:test_private_message_dropped_when_disabled()
  self.tg = fresh_telegram({ p2p = { enable = false } })
  local received = {}
  local fetch = connect_with_bot(self.tg, received)
  deliver(fetch, {
    make_update(1, 'hello', { chat_type = 'private', from_id = 1000 }),
  })
  lu.assertEquals(#received, 0)
end

function TestTelegramRouting:test_group_message_requires_mention()
  local received = {}
  local fetch = connect_with_bot(self.tg, received)
  deliver(fetch, {
    make_update(1, 'talking among ourselves', { chat_id = -100 }),
    make_update(2, '@chatnvim_bot what is up', { chat_id = -100 }),
  })
  lu.assertEquals(#received, 1)
  lu.assertEquals(received[1].content, 'what is up', 'mention stripped')
  lu.assertEquals(received[1].chat_id, '-100')
  lu.assertEquals(received[1].chat_type, 'group')
end

function TestTelegramRouting:test_group_reply_to_bot_counts()
  local received = {}
  local fetch = connect_with_bot(self.tg, received)
  deliver(fetch, {
    make_update(1, 'follow-up', { chat_id = -100, reply_from_id = 999 }),
  })
  lu.assertEquals(#received, 1)
end

function TestTelegramRouting:test_private_chat_creates_its_own_session()
  local received = {}
  local fetch = connect_with_bot(self.tg, received)
  deliver(fetch, {
    make_update(1, 'dm', { chat_type = 'private', from_id = 1000 }),
  })
  lu.assertEquals(self.tg.get_binding('1000'), 'telegram-1000')
end

function TestTelegramRouting:test_reply_goes_back_to_the_originating_chat()
  self.tg.set_session('tg-session')
  self.tg.add_container('777', { chat_type = 'private', peer = '777' })
  local session = self.tg.chat_session('777')

  self.tg.send_message('answer for the DM', session)
  local _, j = find_job('sendMessage')
  lu.assertNotNil(j, 'sendMessage started')
  local body = request_body(j)
  lu.assertEquals(
    body.chat_id,
    '777',
    'a DM reply must not land in the configured main chat'
  )
end

function TestTelegramRouting:test_reply_without_session_uses_main_chat()
  self.tg.send_message('hello')
  local _, j = find_job('sendMessage')
  lu.assertEquals(request_body(j).chat_id, '555')
end

function TestTelegramRouting:test_in_chat_allow_updates_acl_and_replies_in_place()
  self.tg = fresh_telegram({ acl = { admins = { 100 } } })
  self.tg.set_session('tg-session')
  local received = {}
  local fetch = connect_with_bot(self.tg, received)

  deliver(fetch, {
    make_update(1, '@chatnvim_bot /allow', {
      chat_id = -100,
      from_id = 100,
      reply_from_id = 2000,
    }),
  })

  lu.assertEquals(#received, 0, '/allow must never reach the LLM')
  lu.assertTrue(self.tg.is_allowed({ id = '2000' }), 'target whitelisted')

  local _, j = find_job('sendMessage')
  lu.assertNotNil(j, 'ACL reply sent')
  lu.assertEquals(request_body(j).chat_id, '-100', 'answered in the same chat')
end

function TestTelegramRouting:test_acl_command_from_non_admin_ignored()
  self.tg = fresh_telegram({ acl = { admins = { 100 } } })
  self.tg.set_session('tg-session')
  local received = {}
  local fetch = connect_with_bot(self.tg, received)

  deliver(fetch, {
    make_update(1, '@chatnvim_bot /allow', {
      chat_id = -100,
      from_id = 3000,
      reply_from_id = 2000,
    }),
  })

  lu.assertEquals(#received, 0, 'not forwarded to the LLM either')
  -- `is_allowed()` is true anyway under the default allow_all mode, so assert
  -- on the thing that actually matters: the runtime whitelist was not written.
  lu.assertEquals(
    #self.tg.get_acl().whitelist,
    0,
    'a non-admin must not be able to grant access'
  )
  lu.assertNil(find_job('sendMessage'), 'silently ignored, no spam reply')
end

function TestTelegramRouting:test_recent_senders_are_cached()
  local received = {}
  local fetch = connect_with_bot(self.tg, received)
  deliver(fetch, {
    make_update(1, 'hi', { chat_type = 'private', from_id = 1000, username = 'alice' }),
    make_update(2, 'hi', { chat_type = 'private', from_id = 2000, username = 'bob' }),
  })
  local ids = {}
  for _, sender in ipairs(self.tg.get_recent_senders()) do
    ids[sender.id] = sender.name
  end
  lu.assertEquals(ids['1000'], 'Tester')
  lu.assertEquals(ids['2000'], 'Tester')
end

function TestTelegramRouting:test_private_peer_mismatch_is_dropped()
  -- The stored peer is authoritative: if the container was registered for
  -- somebody else, a message from a different sender inside it is not
  -- trustworthy. The check must run BEFORE ensure_container(), which would
  -- otherwise overwrite the recorded peer with the current sender.
  self.tg = fresh_telegram()
  self.tg.add_container('1000', { chat_type = 'private', peer = '4242' })
  local received = {}
  local fetch = connect_with_bot(self.tg, received)
  deliver(fetch, {
    make_update(1, 'impostor', { chat_type = 'private', from_id = 1000 }),
  })
  lu.assertEquals(#received, 0, 'peer mismatch must not be answered')
end

return TestTelegramAcl

