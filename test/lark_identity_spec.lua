-- test/lark_identity_spec.lua
-- Covers lua/chat/integrations/lark/identity.lua (email / mobile -> open_id resolution) and
-- the email-configured ACL path in lua/chat/integrations/lark.lua.
--
-- See ideas/lark-acl-bindings.md 3.2: entries are resolved once at connect
-- time, and every comparison happens in open_id space afterwards.
local lu = require('luaunit')
local job = require('job')
local config = require('chat.config')
local curl = require('chat.curl')
local auth = require('chat.integrations.lark.auth')

local identity = require('chat.integrations.lark.identity')

local BATCH_FRAGMENT = 'batch_get_id'
local TOKEN_FRAGMENT = 'tenant_access_token'

--- Jobs whose command line contains `fragment`, in id order.
local function jobs_matching(fragment)
  local found = {}
  for id, j in pairs(job.jobs) do
    if table.concat(j.cmd, ' '):find(fragment, 1, true) then
      table.insert(found, { id = id, job = j })
    end
  end
  table.sort(found, function(a, b)
    return a.id < b.id
  end)
  return found
end

local function wait(ms)
  vim.wait(ms or 150, function()
    return false
  end, 20)
end

--- Drop recorded jobs so a later phase counts only its own requests.
--- `job.reset()` also leaves interception mode, so re-enable it.
local function reset_jobs()
  job.reset()
  job.intercept()
end

TestLarkIdentity = {}

function TestLarkIdentity:setUp()
  job.reset()
  job.intercept()
  auth.reset()
  -- Seeded so identity.resolve never has to fetch a token: these specs are
  -- about lookup behaviour, not token plumbing.
  auth._set_token('t-cached')

  self.storage_dir = vim.fn.tempname() .. '_lark_identity_test/'
  vim.fn.mkdir(self.storage_dir, 'p')
  config.setup({
    storage_dir = self.storage_dir,
    integrations = {
      lark = { app_id = 'cli_test_app', app_secret = 'secret_test' },
    },
  })

  self._orig_available = curl.is_available
  curl.is_available = function()
    return true
  end
end

function TestLarkIdentity:tearDown()
  curl.is_available = self._orig_available
  job.reset()
  auth.reset()
  vim.fn.delete(self.storage_dir, 'rf')
end

-- ─── classify ─────────────────────────────────────────────

function TestLarkIdentity:test_classify_open_id()
  lu.assertEquals(identity.classify('ou_abc123'), 'open_id')
end

function TestLarkIdentity:test_classify_email()
  lu.assertEquals(identity.classify('nova@example.com'), 'email')
end

function TestLarkIdentity:test_classify_phone()
  lu.assertEquals(identity.classify('+8613800138000'), 'phone')
  lu.assertEquals(identity.classify('13800138000'), 'phone')
end

function TestLarkIdentity:test_classify_unsupported_ids()
  -- user_id / union_id live in other id spaces and are rejected on purpose
  lu.assertEquals(identity.classify('us_abc123'), 'user_id')
  lu.assertEquals(identity.classify('on_abc123'), 'union_id')
end

function TestLarkIdentity:test_classify_junk()
  lu.assertEquals(identity.classify(''), 'empty')
  lu.assertEquals(identity.classify('nova'), 'unknown')
  lu.assertEquals(identity.classify(nil), 'unknown')
  lu.assertEquals(identity.classify(42), 'unknown')
end

-- ─── resolve: open_id only ───────────────────────────────

function TestLarkIdentity:test_open_id_entries_need_no_request()
  local result
  identity.resolve({ 'ou_a', 'ou_b' }, function(r)
    result = r
  end)

  lu.assertEquals(result['ou_a'], 'ou_a')
  lu.assertEquals(result['ou_b'], 'ou_b')
  lu.assertEquals(#result.failed, 0)
  lu.assertEquals(#jobs_matching(BATCH_FRAGMENT), 0, 'zero requests')
end

function TestLarkIdentity:test_unsupported_entries_are_reported()
  local result
  identity.resolve({ 'ou_a', 'us_bad', 'on_bad' }, function(r)
    result = r
  end)

  lu.assertEquals(result['ou_a'], 'ou_a')
  lu.assertNil(result['us_bad'])
  lu.assertEquals(#result.failed, 2)
  lu.assertStrContains(table.concat(result.failed, ','), 'us_bad')
  lu.assertStrContains(table.concat(result.failed, ','), 'on_bad')
end

function TestLarkIdentity:test_empty_entries_are_skipped_silently()
  local result
  identity.resolve({ '', 'ou_a' }, function(r)
    result = r
  end)

  lu.assertEquals(#result.failed, 0, 'config noise is not a failure')
  lu.assertEquals(result['ou_a'], 'ou_a')
end

-- ─── resolve: email / mobile ─────────────────────────────

function TestLarkIdentity:test_request_uses_open_id_type_and_stdin()
  identity.resolve({ 'nova@example.com' }, function() end)

  local found = jobs_matching(BATCH_FRAGMENT)
  lu.assertEquals(#found, 1, 'one lookup per batch')

  local cmd = table.concat(found[1].job.cmd, ' ')
  -- user_id_type=open_id is mandatory: without it the response carries
  -- user_id-space values that never match a sender id.
  lu.assertStrContains(cmd, 'user_id_type=open_id')
  lu.assertStrContains(cmd, 'POST')
  lu.assertStrContains(cmd, 'Bearer t-cached')
  -- Body over stdin: addresses must not end up in argv.
  lu.assertNotNil(cmd:find('-d @-', 1, true), 'body travels over stdin')
  lu.assertEquals(#found[1].job.stdin, 1, 'body sent over stdin')
  lu.assertStrContains(found[1].job.stdin[1], 'nova@example.com')
end

function TestLarkIdentity:test_email_resolves_to_open_id()
  local result
  identity.resolve({ 'nova@example.com' }, function(r)
    result = r
  end)

  local found = jobs_matching(BATCH_FRAGMENT)
  lu.assertEquals(#found, 1)

  job.emit_stdout(found[1].id, {
    vim.json.encode({
      code = 0,
      data = {
        user_list = { { user_id = 'ou_resolved', email = 'nova@example.com' } },
      },
    }),
  })
  job.emit_exit(found[1].id, 0)

  lu.assertEquals(result['nova@example.com'], 'ou_resolved')
  lu.assertEquals(#result.failed, 0)
  lu.assertNil(result.error)
end

function TestLarkIdentity:test_email_match_is_case_insensitive()
  local result
  identity.resolve({ 'Nova@Example.COM' }, function(r)
    result = r
  end)

  local found = jobs_matching(BATCH_FRAGMENT)
  job.emit_stdout(found[1].id, {
    vim.json.encode({
      code = 0,
      data = {
        user_list = { { user_id = 'ou_resolved', email = 'nova@example.com' } },
      },
    }),
  })
  job.emit_exit(found[1].id, 0)

  -- The map is keyed by the configured text, so lookups stay case-agnostic.
  lu.assertEquals(result['Nova@Example.COM'], 'ou_resolved')
end

function TestLarkIdentity:test_phone_matches_on_digits()
  local result
  identity.resolve({ '+8613800138000' }, function(r)
    result = r
  end)

  local found = jobs_matching(BATCH_FRAGMENT)
  -- Feishu may echo a differently formatted number than the one sent.
  job.emit_stdout(found[1].id, {
    vim.json.encode({
      code = 0,
      data = {
        user_list = {
          { user_id = 'ou_resolved', mobile = '+86 138 0013 8000' },
        },
      },
    }),
  })
  job.emit_exit(found[1].id, 0)

  lu.assertEquals(result['+8613800138000'], 'ou_resolved')
end

function TestLarkIdentity:test_unmatched_entry_goes_to_failed()
  local result
  identity.resolve({ 'ghost@example.com' }, function(r)
    result = r
  end)

  local found = jobs_matching(BATCH_FRAGMENT)
  job.emit_stdout(found[1].id, {
    vim.json.encode({ code = 0, data = { user_list = {} } }),
  })
  job.emit_exit(found[1].id, 0)

  lu.assertNil(result['ghost@example.com'])
  lu.assertEquals(#result.failed, 1)
  lu.assertEquals(result.failed[1], 'ghost@example.com')
end

-- ─── resolve: failure paths ──────────────────────────────

function TestLarkIdentity:test_api_error_code_is_reported()
  local result
  identity.resolve({ 'nova@example.com' }, function(r)
    result = r
  end)

  local found = jobs_matching(BATCH_FRAGMENT)
  job.emit_stdout(found[1].id, {
    vim.json.encode({ code = 99991672, msg = 'no permission' }),
  })
  job.emit_exit(found[1].id, 0)

  lu.assertStrContains(result.error, '99991672')
  lu.assertEquals(#result.failed, 1)
end

function TestLarkIdentity:test_curl_failure_is_reported()
  local result
  identity.resolve({ 'nova@example.com' }, function(r)
    result = r
  end)

  local found = jobs_matching(BATCH_FRAGMENT)
  job.emit_stderr(found[1].id, { 'curl: (6) Could not resolve host' })
  job.emit_exit(found[1].id, 6, 0)

  lu.assertStrContains(result.error, 'curl exit 6')
  lu.assertEquals(#result.failed, 1)
end

function TestLarkIdentity:test_token_failure_is_reported()
  auth.reset() -- cold cache: ensure_token has to fetch
  local result
  identity.resolve({ 'nova@example.com' }, function(r)
    result = r
  end)

  local found = jobs_matching(TOKEN_FRAGMENT)
  lu.assertEquals(#found, 1, 'token request started')
  job.emit_stderr(found[1].id, { 'curl: (6) Could not resolve host' })
  job.emit_exit(found[1].id, 6, 0)
  wait(100)

  lu.assertEquals(#result.failed, 1)
  lu.assertStrContains(result.error, 'tenant_access_token')
end

function TestLarkIdentity:test_non_open_id_response_is_rejected()
  local result
  identity.resolve({ 'nova@example.com' }, function(r)
    result = r
  end)

  local found = jobs_matching(BATCH_FRAGMENT)
  -- Happens when user_id_type is missing / not honoured: the value looks
  -- resolved but never matches a sender id.
  job.emit_stdout(found[1].id, {
    vim.json.encode({
      code = 0,
      data = {
        user_list = { { user_id = 'us_wrong', email = 'nova@example.com' } },
      },
    }),
  })
  job.emit_exit(found[1].id, 0)

  lu.assertNil(result['nova@example.com'])
  lu.assertEquals(#result.failed, 1)
end

-- ─── batching ────────────────────────────────────────────

function TestLarkIdentity:test_more_than_fifty_entries_use_two_batches()
  local entries = {}
  for i = 1, 51 do
    table.insert(entries, string.format('user%d@example.com', i))
  end

  local result
  identity.resolve(entries, function(r)
    result = r
  end)

  lu.assertEquals(#jobs_matching(BATCH_FRAGMENT), 1, 'first batch only')

  local first = jobs_matching(BATCH_FRAGMENT)
  job.emit_stdout(first[1].id, {
    vim.json.encode({ code = 0, data = { user_list = {} } }),
  })
  job.emit_exit(first[1].id, 0)

  lu.assertEquals(#jobs_matching(BATCH_FRAGMENT), 2, 'second batch follows')

  local second = jobs_matching(BATCH_FRAGMENT)[2]
  job.emit_stdout(second.id, {
    vim.json.encode({ code = 0, data = { user_list = {} } }),
  })
  job.emit_exit(second.id, 0)

  lu.assertEquals(#result.failed, 51, 'every unmatched entry is reported')
end

-- ===========================================================================
-- Email-configured ACL in the integration
-- ===========================================================================

TestLarkAclEmail = {}

local function fresh_lark(storage_dir, acl)
  package.loaded['chat.integrations.lark'] = nil
  -- The token cache survives module reloads; reset it so the new instance
  -- starts cold, then seed it again: these specs are about ACL resolution,
  -- not token plumbing.
  auth.reset()
  auth._set_token('t-cached')
  -- config.setup() deep-merges: drop the previous spec's acl table so it can
  -- not leak into this one.
  if config.config.integrations and config.config.integrations.lark then
    config.config.integrations.lark.acl = nil
  end
  config.setup({
    storage_dir = storage_dir,
    integrations = {
      lark = {
        app_id = 'cli_test_app',
        app_secret = 'secret_test',
        chat_id = 'oc_test_chat',
        acl = acl,
      },
    },
  })
  return require('chat.integrations.lark')
end

--- Drive the connect-time resolution: one lookup job, one response.
local function feed_lookup(user_list)
  local found = jobs_matching(BATCH_FRAGMENT)
  lu.assertEquals(#found, 1, 'one resolution request')
  job.emit_stdout(found[1].id, {
    vim.json.encode({ code = 0, data = { user_list = user_list } }),
  })
  job.emit_exit(found[1].id, 0)
  wait(100)
end

function TestLarkAclEmail:setUp()
  job.reset()
  job.intercept()
  auth.reset()
  auth._set_token('t-cached')
  self.storage_dir = vim.fn.tempname() .. '_lark_acl_email_test/'
  vim.fn.mkdir(self.storage_dir, 'p')
  self._orig_available = curl.is_available
  curl.is_available = function()
    return true
  end
end

function TestLarkAclEmail:tearDown()
  curl.is_available = self._orig_available
  job.reset()
  auth.reset()
  vim.fn.delete(self.storage_dir, 'rf')
end

function TestLarkAclEmail:test_email_admin_is_recognised()
  local lark =
    fresh_lark(self.storage_dir, { admins = { 'admin@example.com' } })
  lark.connect(function() end)

  feed_lookup({ { user_id = 'ou_admin', email = 'admin@example.com' } })

  lu.assertTrue(lark.is_admin('ou_admin'), 'email admin resolved to open_id')
  lu.assertFalse(lark.is_admin('ou_member'))
end

function TestLarkAclEmail:test_email_admin_fails_closed_before_resolution()
  local lark =
    fresh_lark(self.storage_dir, { admins = { 'admin@example.com' } })
  -- No lookup response yet: the entry has no open_id, so it grants nothing.
  lu.assertFalse(lark.is_admin('ou_admin'))
end

function TestLarkAclEmail:test_email_whitelist_entry_allows_resolved_user()
  local lark = fresh_lark(self.storage_dir, {
    mode = 'whitelist',
    whitelist = { 'nova@example.com' },
  })
  lark.connect(function() end)

  feed_lookup({ { user_id = 'ou_nova', email = 'nova@example.com' } })

  lu.assertTrue(lark.is_allowed('ou_nova'))
  lu.assertFalse(lark.is_allowed('ou_other'))
end

function TestLarkAclEmail:test_unresolved_whitelist_entry_fails_closed()
  local lark = fresh_lark(self.storage_dir, {
    mode = 'whitelist',
    whitelist = { 'ghost@example.com' },
  })
  lark.connect(function() end)

  feed_lookup({}) -- nobody matched

  lu.assertFalse(lark.is_allowed('ou_anyone'))
end

function TestLarkAclEmail:test_unresolved_blacklist_entry_fails_open()
  local lark = fresh_lark(self.storage_dir, {
    mode = 'blacklist',
    blacklist = { 'ghost@example.com' },
  })
  lark.connect(function() end)

  feed_lookup({})

  -- The entry can not be identified, so it blocks nobody (logged as a warn).
  lu.assertTrue(lark.is_allowed('ou_anyone'))
end

function TestLarkAclEmail:test_open_id_entries_skip_the_lookup()
  local lark = fresh_lark(self.storage_dir, {
    mode = 'whitelist',
    whitelist = { 'ou_nova' },
  })
  lark.connect(function() end)

  lu.assertEquals(#jobs_matching(BATCH_FRAGMENT), 0, 'no lookup needed')
  lu.assertTrue(lark.is_allowed('ou_nova'))
  lu.assertFalse(lark.is_allowed('ou_other'))
end

function TestLarkAclEmail:test_resolution_cache_persists_across_connect()
  local lark =
    fresh_lark(self.storage_dir, { admins = { 'admin@example.com' } })
  lark.connect(function() end)
  feed_lookup({ { user_id = 'ou_admin', email = 'admin@example.com' } })
  lu.assertTrue(lark.is_admin('ou_admin'))
  lark.disconnect()

  reset_jobs()

  -- Reload with the same config: the persisted map must be reused.
  lark = fresh_lark(self.storage_dir, { admins = { 'admin@example.com' } })
  lark.connect(function() end)

  lu.assertEquals(#jobs_matching(BATCH_FRAGMENT), 0, 'cache hit costs no lookup')
  lu.assertTrue(lark.is_admin('ou_admin'), 'map restored from state file')
end

function TestLarkAclEmail:test_config_change_invalidates_cache()
  local lark =
    fresh_lark(self.storage_dir, { admins = { 'admin@example.com' } })
  lark.connect(function() end)
  feed_lookup({ { user_id = 'ou_admin', email = 'admin@example.com' } })
  lark.disconnect()

  reset_jobs()

  -- A new admin entry changes the checksum, so the map is re-resolved.
  lark = fresh_lark(self.storage_dir, {
    admins = { 'admin@example.com', 'nova@example.com' },
  })
  lark.connect(function() end)

  lu.assertEquals(#jobs_matching(BATCH_FRAGMENT), 1, 're-resolution requested')
  feed_lookup({
    { user_id = 'ou_admin', email = 'admin@example.com' },
    { user_id = 'ou_nova', email = 'nova@example.com' },
  })

  lu.assertTrue(lark.is_admin('ou_nova'))
  lu.assertTrue(lark.is_admin('ou_admin'))
end

function TestLarkAclEmail:test_total_failure_does_not_cache_the_checksum()
  local lark =
    fresh_lark(self.storage_dir, { admins = { 'admin@example.com' } })
  lark.connect(function() end)

  local found = jobs_matching(BATCH_FRAGMENT)
  lu.assertEquals(#found, 1)
  job.emit_stderr(found[1].id, { 'curl: (6) Could not resolve host' })
  job.emit_exit(found[1].id, 6, 0) -- transport failure
  wait(100)

  lu.assertFalse(lark.is_admin('ou_admin'), 'nothing resolved')
  lark.disconnect()

  reset_jobs()

  -- The next connect must retry instead of trusting a bogus cache.
  lark = fresh_lark(self.storage_dir, { admins = { 'admin@example.com' } })
  lark.connect(function() end)
  lu.assertEquals(#jobs_matching(BATCH_FRAGMENT), 1, 'retried after failure')
end

