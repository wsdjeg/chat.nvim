-- test/lark_auth_spec.lua
-- Covers lua/chat/lark/auth.lua: the shared tenant_access_token cache, the
-- stdout fast path, and the stderr diagnostics that make transport failures
-- readable (curl `-s` alone silences them, which produced the empty
-- "failed to obtain tenant_access_token: " error).
local lu = require('luaunit')
local job = require('job')
local config = require('chat.config')
local curl = require('chat.curl')

local auth = require('chat.lark.auth')

--- Job whose command line contains `fragment`.
local function find_job(fragment)
  for id, j in pairs(job.jobs) do
    if table.concat(j.cmd, ' '):find(fragment, 1, true) then
      return j, id
    end
  end
end

TestLarkAuth = {}

function TestLarkAuth:setUp()
  job.reset()
  job.intercept()
  auth.reset()

  self.storage_dir = vim.fn.tempname() .. '_lark_auth_test/'
  vim.fn.mkdir(self.storage_dir, 'p')
  config.setup({
    storage_dir = self.storage_dir,
    integrations = {
      lark = {
        app_id = 'cli_test_app',
        app_secret = 'secret_test',
      },
    },
  })

  self._orig_available = curl.is_available
  curl.is_available = function()
    return true
  end
end

function TestLarkAuth:tearDown()
  curl.is_available = self._orig_available
  job.reset()
  auth.reset()
  vim.fn.delete(self.storage_dir, 'rf')
end

--- Call fetch_token and capture the callback arguments.
local function fetch()
  local captured = {}
  auth.fetch_token(function(token, err)
    captured.token = token
    captured.err = err
  end)
  return captured
end

-- ─── cache ────────────────────────────────────────────────

function TestLarkAuth:test_cached_token_nil_when_cold()
  lu.assertNil(auth.cached_token())
end

function TestLarkAuth:test_set_token_seeds_cache()
  auth._set_token('t-seeded')
  lu.assertEquals(auth.cached_token(), 't-seeded')
end

function TestLarkAuth:test_expired_token_is_not_cached()
  -- Negative TTL pushes expires_at into the past, so the cache reports cold.
  auth._set_token('t-stale', -1)
  lu.assertNil(auth.cached_token())
end

function TestLarkAuth:test_reset_drops_token()
  auth._set_token('t-seeded')
  auth.reset()
  lu.assertNil(auth.cached_token())
end

function TestLarkAuth:test_ensure_token_uses_cache_without_spawning()
  auth._set_token('t-cached')
  local seen
  auth.ensure_token(function(token)
    seen = token
  end)
  lu.assertEquals(seen, 't-cached')
  lu.assertNil(find_job('tenant_access_token'), 'no request should be made')
end

-- ─── credentials ──────────────────────────────────────────

function TestLarkAuth:test_missing_credentials()
  -- config.setup deep-merges, so the credentials from setUp would survive a
  -- plain omission. `false` clears them explicitly (falsy for credentials()).
  config.setup({
    storage_dir = self.storage_dir,
    integrations = { lark = { app_id = false, app_secret = false } },
  })
  local got = fetch()
  lu.assertNil(got.token)
  lu.assertStrContains(got.err, 'app_id or app_secret not configured')
end

-- ─── request shape ────────────────────────────────────────

function TestLarkAuth:test_request_keeps_curl_errors_visible()
  fetch()
  local j = find_job('tenant_access_token')
  lu.assertNotNil(j)

  -- -s alone would swallow the transport error text; -S keeps it on stderr
  -- where on_stderr can collect it.
  lu.assertTrue(vim.tbl_contains(j.cmd, '-s'))
  lu.assertTrue(vim.tbl_contains(j.cmd, '-S'))
end

function TestLarkAuth:test_request_posts_credentials()
  fetch()
  local j = find_job('tenant_access_token')
  lu.assertNotNil(j)
  lu.assertEquals(j.cmd[vim.fn.index(j.cmd, '-X') + 2], 'POST')

  -- The credentials body travels inline via -d.
  local body = j.cmd[vim.fn.index(j.cmd, '-d') + 2] or ''
  lu.assertStrContains(body, 'cli_test_app')
end

-- ─── success paths ────────────────────────────────────────

function TestLarkAuth:test_token_resolved_from_stdout()
  local got = fetch()
  local _, id = find_job('tenant_access_token')

  job.emit_stdout(id, {
    vim.json.encode({ tenant_access_token = 't-live', expire = 7200 }),
  })

  -- Resolved before exit so the polling timer is never blocked.
  lu.assertEquals(got.token, 't-live')
  lu.assertNil(got.err)
  lu.assertEquals(auth.cached_token(), 't-live')
end

function TestLarkAuth:test_token_resolved_on_exit_fallback()
  local got = fetch()
  local _, id = find_job('tenant_access_token')

  job.emit_exit(id, 0, 0)
  -- No stdout was ever fed, so exit alone cannot produce a token; it must
  -- report a parse/resolve failure instead of hanging.
  lu.assertNil(got.token)
  lu.assertNotNil(got.err)
end

-- ─── failure paths: the actual bug ────────────────────────

function TestLarkAuth:test_transport_failure_surfaces_stderr()
  local got = fetch()
  local _, id = find_job('tenant_access_token')

  -- curl writes this to stderr for DNS failures; stdout stays empty.
  job.emit_stderr(id, { "curl: (6) Could not resolve host: open.feishu.cn" })
  job.emit_exit(id, 6, 0)

  lu.assertNil(got.token)
  lu.assertStrContains(got.err, 'curl exit code 6')
  lu.assertStrContains(got.err, 'Could not resolve host')
  -- The curl exit code also maps to a human hint.
  lu.assertStrContains(got.err, "Couldn't resolve host")
end

function TestLarkAuth:test_transport_failure_without_stderr_still_readable()
  local got = fetch()
  local _, id = find_job('tenant_access_token')

  job.emit_exit(id, 28, 0)

  lu.assertNil(got.token)
  lu.assertStrContains(got.err, 'curl exit code 28')
  lu.assertStrContains(got.err, 'Operation timeout')
end

function TestLarkAuth:test_api_error_body_is_reported()
  local got = fetch()
  local _, id = find_job('tenant_access_token')

  -- Feishu answers 200 with an error code in the body for bad credentials.
  job.emit_stdout(id, {
    vim.json.encode({ code = 10014, msg = 'app secret invalid' }),
  })
  job.emit_exit(id, 0, 0)

  lu.assertNil(got.token)
  lu.assertStrContains(got.err, 'app secret invalid')
end

function TestLarkAuth:test_cancelled_request_reports_signal()
  local got = fetch()
  local _, id = find_job('tenant_access_token')

  job.emit_stderr(id, { 'cancelled by user' })
  job.emit_exit(id, 130, 15)

  lu.assertNil(got.token)
  lu.assertStrContains(got.err, 'cancelled')
  lu.assertStrContains(got.err, 'signal: 15')
end

function TestLarkAuth:test_callback_runs_once()
  local calls = 0
  auth.fetch_token(function()
    calls = calls + 1
  end)
  local _, id = find_job('tenant_access_token')

  job.emit_stdout(id, {
    vim.json.encode({ tenant_access_token = 't-once' }),
  })
  job.emit_exit(id, 0, 0)

  lu.assertEquals(calls, 1)
end

return TestLarkAuth

