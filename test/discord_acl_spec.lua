-- Coverage for the Discord access control layer (discord/acl.lua).
--
-- No real Discord API is involved: `job.intercept()` captures every curl job
-- and the spec drives each callback, exactly like discord_slack_spec does for
-- the polling flow.
local lu = require('luaunit')
local job = require('job')
local config = require('chat.config')

--- Fresh instance with its own temp storage.
---
--- `config.setup()` deep-merges, so the previous spec's `acl` / `p2p` tables
--- have to be dropped explicitly: otherwise a whitelist from one test would
--- leak into the next one and every "default" assertion would be wrong.
local function fresh_discord(storage_dir, cfg)
  package.loaded['chat.integrations.discord'] = nil
  local d = config.config.integrations and config.config.integrations.discord
  if d then
    d.acl = nil
    d.p2p = nil
  end
  config.setup({
    storage_dir = storage_dir,
    integrations = {
      discord = vim.tbl_deep_extend('force', {
        token = 'dc-token',
        channel_id = 'ch-1',
        -- DM workspaces must never land in the repository root:
        -- `p2p_cwd_root()` falls back to `allowed_path` when unset, so point
        -- it at this spec's temp storage instead.
        p2p = { cwd_root = storage_dir },
      }, cfg or {}),
    },
  })
  return require('chat.integrations.discord')
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

--- Newest job that actually carried a request body.
---
--- `channels/<id>/messages` matches both the polling GET (no stdin at all)
--- and the send POST (body on stdin), so a plain substring search returns the
--- fetch job half the time. Only a job with `stdin[1]` is a send.
local function find_send_job(fragment)
  local best_id, best
  for id, j in pairs(job.jobs) do
    local cmd = table.concat(j.cmd, ' ')
    if
      type(j.stdin) == 'table'
      and j.stdin[1] ~= nil
      and cmd:find(fragment, 1, true)
    then
      if not best_id or id > best_id then
        best_id, best = id, j
      end
    end
  end
  return best_id, best
end

local function dc_msg(id, text, opts)
  opts = opts or {}
  local m = {
    id = id,
    content = text,
    channel_id = opts.channel_id or 'ch-1',
    author = {
      id = opts.author_id or 'user-9',
      username = opts.username or 'tester',
      bot = opts.bot or false,
    },
  }
  if opts.mentions then
    m.mentions = opts.mentions
  end
  return m
end

--- Answer the pending /users/@me job so mentions become detectable.
local function feed_bot_id(bot_id)
  local id = find_job('users/@me')
  lu.assertNotNil(id, 'users/@me job started')
  job.emit_stdout(id, {
    vim.json.encode({ id = bot_id or '111', username = 'chatnvim' }),
  })
  job.emit_exit(id, 0, 0)
  wait(80)
end

--- Deliver one fetch response for a container and release the chain.
local function feed_fetch(fragment, messages)
  local id = find_job(fragment)
  lu.assertNotNil(id, 'fetch job started: ' .. fragment)
  job.emit_stdout(id, { vim.json.encode(messages) })
  job.emit_exit(id, 0, 0)
  wait(300)
end

TestDiscordAcl = {}

local storage_dir

function TestDiscordAcl:setUp()
  job.reset()
  job.intercept()
  storage_dir = vim.fn.tempname() .. '_dcacl/'
  vim.fn.mkdir(storage_dir, 'p')
  self.dc = fresh_discord(storage_dir)
end

function TestDiscordAcl:tearDown()
  job.intercept(false)
  self.dc.disconnect()
  wait(100)
  vim.fn.delete(storage_dir, 'rf')
end

-- ═════════════════════ modes and effective ACL ═════════════════════

function TestDiscordAcl:test_mode_defaults_to_allow_all()
  lu.assertEquals('allow_all', self.dc.acl_mode())
  -- no config: everybody passes, i.e. old behaviour is preserved
  lu.assertTrue(self.dc.is_allowed('user-any'))
  lu.assertFalse(self.dc.is_allowed(nil))
end

function TestDiscordAcl:test_whitelist_mode()
  self.dc = fresh_discord(storage_dir, {
    acl = { mode = 'whitelist', whitelist = { 'user-alice' } },
  })
  lu.assertEquals('whitelist', self.dc.acl_mode())
  lu.assertTrue(self.dc.is_allowed('user-alice'))
  lu.assertFalse(self.dc.is_allowed('user-bob'))
end

function TestDiscordAcl:test_blacklist_mode()
  self.dc = fresh_discord(storage_dir, {
    acl = { mode = 'blacklist', blacklist = { 'user-bob' } },
  })
  lu.assertEquals('blacklist', self.dc.acl_mode())
  lu.assertFalse(self.dc.is_allowed('user-bob'))
  lu.assertTrue(self.dc.is_allowed('user-alice'))
end

function TestDiscordAcl:test_runtime_entries_override_mode()
  self.dc = fresh_discord(storage_dir, { acl = { mode = 'allow_all' } })
  -- A runtime deny has to bite even in allow_all: that is what keeps /deny
  -- useful without editing the config first.
  lu.assertTrue(self.dc.acl_deny('user-bob'))
  lu.assertFalse(self.dc.is_allowed('user-bob'))

  lu.assertTrue(self.dc.acl_allow('user-carol'))
  lu.assertTrue(self.dc.is_allowed('user-carol'))

  -- Same state again: no change, and no state write
  lu.assertFalse(self.dc.acl_allow('user-carol'))
end

function TestDiscordAcl:test_allow_moves_id_out_of_deny_list()
  lu.assertTrue(self.dc.acl_deny('user-dave'))
  lu.assertFalse(self.dc.is_allowed('user-dave'))
  lu.assertTrue(self.dc.acl_allow('user-dave'))
  lu.assertTrue(self.dc.is_allowed('user-dave'))
  -- the deny entry is gone, so the merged list reports it only in whitelist
  local acl = self.dc.get_acl()
  lu.assertTrue(vim.tbl_contains(acl.whitelist, 'user-dave'))
  lu.assertFalse(vim.tbl_contains(acl.blacklist, 'user-dave'))
end

function TestDiscordAcl:test_allow_and_deny_reject_nil()
  lu.assertFalse(self.dc.acl_allow(nil))
  lu.assertFalse(self.dc.acl_deny(nil))
  lu.assertFalse(self.dc.acl_allow(''))
  lu.assertFalse(self.dc.acl_deny(''))
end

function TestDiscordAcl:test_get_acl_merges_config_and_runtime()
  self.dc = fresh_discord(storage_dir, {
    acl = {
      mode = 'whitelist',
      admins = { 'user-admin' },
      whitelist = { 'user-alice' },
    },
  })
  self.dc.acl_allow('user-carol')

  local acl = self.dc.get_acl()
  lu.assertEquals('whitelist', acl.mode)
  lu.assertEquals({ 'user-admin' }, acl.admins)
  lu.assertEquals({ 'user-alice', 'user-carol' }, acl.whitelist)
  lu.assertEquals({}, acl.blacklist)
end

function TestDiscordAcl:test_admin_always_passes()
  self.dc = fresh_discord(storage_dir, {
    acl = { mode = 'whitelist', admins = { 'user-admin' }, whitelist = {} },
  })
  lu.assertTrue(self.dc.is_admin('user-admin'))
  lu.assertFalse(self.dc.is_admin('user-alice'))
  lu.assertFalse(self.dc.is_admin(nil))
  -- admins bypass the ACL so a locked-out whitelist stays repairable
  lu.assertTrue(self.dc.is_allowed('user-admin'))
end

function TestDiscordAcl:test_acl_status_report()
  self.dc = fresh_discord(storage_dir, {
    acl = {
      mode = 'whitelist',
      admins = { 'user-admin' },
      whitelist = { 'user-alice' },
    },
  })
  self.dc.acl_allow('user-carol')

  local report = self.dc.acl_status()
  lu.assertStrContains(report, 'ACL mode: whitelist')
  lu.assertStrContains(report, 'user-admin')
  lu.assertStrContains(report, 'Whitelist (2)')
  lu.assertStrContains(report, '/allow')
end

-- ═════════════════════ persistence ═════════════════════

function TestDiscordAcl:test_runtime_entries_persist_to_state()
  self.dc.acl_allow('user-alice')
  self.dc.acl_deny('user-bob')

  local state_file = storage_dir .. 'integration/discord.json'
  lu.assertTrue(vim.fn.filereadable(state_file) == 1, 'state file written')
  local data = vim.json.decode(table.concat(vim.fn.readfile(state_file), ''))
  lu.assertNotNil(data.acl)
  lu.assertEquals({ 'user-alice' }, data.acl.whitelist)
  lu.assertEquals({ 'user-bob' }, data.acl.blacklist)
end

function TestDiscordAcl:test_runtime_entries_survive_reload()
  self.dc.acl_allow('user-alice')

  self.dc = fresh_discord(storage_dir, { acl = { mode = 'whitelist' } })
  self.dc.connect(function() end)
  wait(200)

  lu.assertTrue(self.dc.is_allowed('user-alice'), 'runtime allow reloaded')
end

-- ═════════════════════ recent senders ═════════════════════

function TestDiscordAcl:test_recent_senders_cache()
  local received = {}
  self.dc.connect(function(msg)
    received[#received + 1] = msg
  end)
  wait(200)
  feed_bot_id()
  wait(200)

  feed_fetch('channels/ch-1', {
    dc_msg('301', '<@111> hi', {
      mentions = { { id = '111' } },
      author_id = 'user-9',
      username = 'tester',
    }),
    dc_msg('302', 'bot echo', { bot = true, author_id = '999' }),
  })

  lu.assertEquals(1, #received, 'one human message delivered')
  local recent = self.dc.get_recent_senders()
  lu.assertEquals(1, #recent, 'bots are not cached as speakers')
  lu.assertEquals('user-9', recent[1].id)
  lu.assertEquals('tester', recent[1].name)
end

-- ═════════════════════ message text helpers ═════════════════════

-- The parse helpers are internal to `discord/acl.lua` (the module only hands
-- them out through `new(ctx)`), so they are covered through their observable
-- effect instead of called directly.

function TestDiscordAcl:test_parse_acl_command_requires_a_space()
  self.dc = fresh_discord(storage_dir)
  -- The module under test is already loaded through the facade; parse helpers
  -- are internal, so drive the observable path instead: a `/allowed` message
  -- must reach the model, not be treated as a command.
  local received = {}
  self.dc.connect(function(msg)
    received[#received + 1] = msg
  end)
  wait(200)
  feed_bot_id()
  wait(200)

  feed_fetch('channels/ch-1', {
    dc_msg('311', '<@111> /allowed', { mentions = { { id = '111' } } }),
  })
  lu.assertEquals(1, #received, '/allowed is not a command')
  lu.assertEquals('/allowed', received[1].content)
end

-- ═════════════════════ in-chat commands ═════════════════════

--- Helper: connect, feed the bot id, and deliver one guild message.
function TestDiscordAcl:deliver_group(text, opts)
  opts = opts or {}
  local received = {}
  self.dc.connect(function(msg)
    received[#received + 1] = msg
  end)
  wait(200)
  feed_bot_id()
  wait(200)

  local mentions = opts.mentions or { { id = '111' } }
  feed_fetch('channels/ch-1', {
    dc_msg(opts.id or '401', text, {
      mentions = mentions,
      author_id = opts.author_id or 'user-admin',
      username = opts.username or 'admin',
    }),
  })
  return received
end

function TestDiscordAcl:test_in_chat_allow_by_admin()
  self.dc = fresh_discord(storage_dir, {
    acl = { mode = 'whitelist', admins = { 'user-admin' } },
  })
  local received = self:deliver_group('<@111> /allow <@777>', {
    mentions = { { id = '111' }, { id = '777' } },
  })

  lu.assertEquals(0, #received, 'command never reaches the model')
  lu.assertTrue(self.dc.is_allowed('777'), 'target was allowed')

  -- the reply went out as a message job
  local _, send_job = find_send_job('channels/ch-1/messages')
  lu.assertNotNil(send_job, 'reply sent')
  local body = vim.json.decode(send_job.stdin[1])
  lu.assertStrContains(body.content, 'Allowed:')
  lu.assertStrContains(body.content, '777')
end

function TestDiscordAcl:test_in_chat_allow_ignored_for_non_admin()
  self.dc = fresh_discord(storage_dir, {
    acl = { mode = 'whitelist', admins = { 'user-admin' } },
  })
  local received = self:deliver_group('<@111> /allow <@777>', {
    author_id = 'user-bob',
    mentions = { { id = '111' }, { id = '777' } },
  })

  lu.assertEquals(0, #received, 'non-admin message dropped or skipped')
  lu.assertFalse(self.dc.is_allowed('777'), 'ACL untouched')
  -- silent: no reply job at all
  lu.assertNil(find_send_job('channels/ch-1/messages'), 'no reply to non-admin')
end

function TestDiscordAcl:test_in_chat_deny_by_admin()
  self.dc = fresh_discord(storage_dir, {
    acl = { mode = 'allow_all', admins = { 'user-admin' } },
  })
  self.dc.acl_allow('user-777')

  local received = self:deliver_group('<@111> /deny <@777>', {
    mentions = { { id = '111' }, { id = '777' } },
  })

  lu.assertEquals(0, #received, 'command never reaches the model')
  lu.assertFalse(self.dc.is_allowed('777'), 'target was denied')
end

function TestDiscordAcl:test_in_chat_acl_status_command()
  self.dc = fresh_discord(storage_dir, {
    acl = { mode = 'whitelist', admins = { 'user-admin' }, whitelist = { 'user-alice' } },
  })
  local received = self:deliver_group('<@111> /acl')

  lu.assertEquals(0, #received)
  local _, send_job = find_send_job('channels/ch-1/messages')
  lu.assertNotNil(send_job)
  local body = vim.json.decode(send_job.stdin[1])
  lu.assertStrContains(body.content, 'ACL mode: whitelist')
  lu.assertStrContains(body.content, 'user-alice')
end

function TestDiscordAcl:test_in_chat_allow_without_target_shows_usage()
  self.dc = fresh_discord(storage_dir, {
    acl = { mode = 'whitelist', admins = { 'user-admin' } },
  })
  self:deliver_group('<@111> /allow')

  local _, send_job = find_send_job('channels/ch-1/messages')
  lu.assertNotNil(send_job)
  local body = vim.json.decode(send_job.stdin[1])
  lu.assertStrContains(body.content, 'Usage:')
end

function TestDiscordAcl:test_non_admin_sender_is_filtered_by_acl()
  self.dc = fresh_discord(storage_dir, {
    acl = { mode = 'whitelist', admins = { 'user-admin' } },
  })
  local received = self:deliver_group('<@111> hello', { author_id = 'user-bob' })
  lu.assertEquals(0, #received, 'whitelist keeps strangers out')
end

-- ═════════════════════ DM admission ═════════════════════

function TestDiscordAcl:test_p2p_defaults_to_allow()
  -- Historical Discord behaviour: a DM channel only exists after the peer
  -- opened the conversation, so with nothing configured the peer is served.
  lu.assertTrue(self.dc.is_p2p_allowed('user-any'))
end

function TestDiscordAcl:test_p2p_disabled_blocks_everyone()
  self.dc = fresh_discord(storage_dir, { p2p = { enable = false } })
  lu.assertFalse(self.dc.is_p2p_allowed('user-any'))
end

function TestDiscordAcl:test_p2p_allow_list_is_authoritative()
  self.dc = fresh_discord(storage_dir, {
    p2p = { allow = { 'user-alice' } },
    acl = { admins = { 'user-admin' } },
  })
  lu.assertTrue(self.dc.is_p2p_allowed('user-alice'))
  -- an explicit list is the whole policy: no admin fallback, otherwise one
  -- typo would quietly widen access to every admin
  lu.assertFalse(self.dc.is_p2p_allowed('user-admin'))
  lu.assertFalse(self.dc.is_p2p_allowed('user-bob'))
end

function TestDiscordAcl:test_p2p_respects_whitelist_mode()
  self.dc = fresh_discord(storage_dir, {
    acl = { mode = 'whitelist', whitelist = { 'user-alice' } },
  })
  lu.assertTrue(self.dc.is_p2p_allowed('user-alice'))
  lu.assertFalse(self.dc.is_p2p_allowed('user-bob'))
end

function TestDiscordAcl:test_p2p_sender_mismatch_is_ignored()
  self.dc = fresh_discord(storage_dir, { p2p = { allow = { 'user-9' } } })
  self.dc.add_container('dm-1', { chat_type = 'p2p', peer = 'user-9' })

  local received = {}
  self.dc.connect(function(msg)
    received[#received + 1] = msg
  end)
  wait(200)
  feed_bot_id()
  wait(200)

  -- drain the main channel first (the chain is strictly sequential)
  feed_fetch('channels/ch-1', {})

  -- the registered peer is the only trustworthy identity in that container
  feed_fetch('channels/dm-1', {
    dc_msg('501', 'hello from a stranger', {
      channel_id = 'dm-1',
      author_id = 'user-other',
    }),
  })
  lu.assertEquals(0, #received, 'sender mismatch ignored')
end

function TestDiscordAcl:test_p2p_message_delivered_without_mention()
  self.dc = fresh_discord(storage_dir, { p2p = { allow = { 'user-9' } } })
  self.dc.add_container('dm-1', { chat_type = 'p2p', peer = 'user-9' })

  local received = {}
  self.dc.connect(function(msg)
    received[#received + 1] = msg
  end)
  wait(200)
  feed_bot_id()
  wait(200)

  feed_fetch('channels/ch-1', {})
  feed_fetch('channels/dm-1', {
    dc_msg('511', 'hello bot', { channel_id = 'dm-1', author_id = 'user-9' }),
  })

  lu.assertEquals(1, #received, 'DM needs no mention')
  lu.assertEquals('hello bot', received[1].content)
  lu.assertEquals('p2p', received[1].chat_type)
end

