-- Coverage for lua/chat/integrations/lark/send.lua.
--
-- The sender is a single-consumer queue: one chunk in flight at a time, the
-- next one served from the previous job's on_exit. These specs pin the guard
-- that enforces it, because the window between "queue head taken" and "job
-- started" is asynchronous (the tenant token is resolved there), and two
-- replies arriving inside it would otherwise interleave their chunks.
local lu = require('luaunit')
local job = require('job')
local config = require('chat.config')

local storage_dir

--- Reload the integration with fresh state, pointing STATE_FILE at temp storage.
local function fresh_lark(lark_extra)
  package.loaded['chat.integrations.lark'] = nil
  require('chat.integrations.lark.auth').reset()
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

TestLarkSend = {}

local function wait(ms)
  vim.wait(ms or 300, function()
    return false
  end, 20)
end

local TOKEN_JSON = vim.json.encode({
  tenant_access_token = 't-abc123',
  expire = 7200,
})

--- Find a started job whose command contains the given fragment.
local function find_job(fragment)
  for id, j in pairs(job.jobs) do
    if table.concat(j.cmd, ' '):find(fragment, 1, true) then
      return id, j
    end
  end
end

--- Resolve every outstanding token request, however many were started.
---
--- A dispatch that is not serialized starts its own token request, so the
--- regression only shows up once *all* of them answer.
local function resolve_all_tokens()
  for id, j in pairs(job.jobs) do
    if table.concat(j.cmd, ' '):find('tenant_access_token', 1, true) then
      job.emit_stdout(id, { TOKEN_JSON })
    end
  end
  wait(100)
end

--- How many jobs matching the fragment were started.
local function count_jobs(fragment)
  local count = 0
  for _, j in pairs(job.jobs) do
    if table.concat(j.cmd, ' '):find(fragment, 1, true) then
      count = count + 1
    end
  end
  return count
end

--- Fail every outstanding token request with an API error body.
---
--- Stdout alone is not enough: auth settles the request on stdout *or* exit,
--- and without the exit the callbacks never fire, so the sender would keep
--- waiting instead of taking the failure path this helper is meant to trigger.
local function fail_all_tokens()
  local failed = false
  for id, j in pairs(job.jobs) do
    if table.concat(j.cmd, ' '):find('tenant_access_token', 1, true) then
      job.emit_stdout(id, {
        vim.json.encode({ code = 99991400, msg = 'invalid param' }),
      })
      job.emit_exit(id, 0)
      failed = true
    end
  end
  wait(100)
  return failed
end

--- Every started delivery request (one per chunk), oldest first.
local function send_jobs()
  local list = {}
  for id, j in pairs(job.jobs) do
    if table.concat(j.cmd, ' '):find('receive_id_type=', 1, true) then
      table.insert(list, { id = id, job = j })
    end
  end
  table.sort(list, function(a, b)
    return a.id < b.id
  end)
  return list
end

--- Markdown body of a queued delivery request.
local function body_of(j)
  lu.assertNotNil(j.stdin[1], 'request body written before the job ran')
  local body = vim.json.decode(j.stdin[1])
  return vim.json.decode(body.content).body.elements[1].content
end

function TestLarkSend:setUp()
  job.reset()
  job.intercept()
  storage_dir = vim.fn.tempname() .. '_lark_send_test/'
  vim.fn.mkdir(storage_dir, 'p')
  self.lark = fresh_lark()
  self._job_start = job.start
end

function TestLarkSend:tearDown()
  job.start = self._job_start
  job.intercept(false)
  if self.lark then
    self.lark.disconnect()
  end
  wait(100)
  vim.fn.delete(storage_dir, 'rf')
end

-- ===========================================================================
-- In-flight guard covers the asynchronous token window
-- ===========================================================================

function TestLarkSend:test_two_replies_do_not_start_two_send_jobs()
  -- The token cache is cold, so the first reply stops inside ensure_token()
  -- with no job started yet. The second reply arrives in that exact window:
  -- it must queue behind the first instead of taking its own job.
  self.lark.send_message('first reply')
  self.lark.send_message('second reply')
  wait(50)

  lu.assertEquals(0, #send_jobs(), 'no delivery before the token resolves')

  resolve_all_tokens()

  local list = send_jobs()
  lu.assertEquals(
    1,
    #list,
    'exactly one delivery in flight, not one per reply'
  )
  lu.assertEquals('first reply', body_of(list[1].job), 'queue head goes first')
end

function TestLarkSend:test_queued_chunks_are_served_in_order()
  -- Chunks are served one at a time, in queue order: the second request only
  -- exists after the first job exits.
  self.lark.send_message('first reply')
  self.lark.send_message('second reply')

  resolve_all_tokens()

  local list = send_jobs()
  lu.assertEquals(1, #list)
  local first = list[1]
  lu.assertEquals('first reply', body_of(first.job))

  job.emit_exit(first.id, 0)
  wait(200)

  list = send_jobs()
  lu.assertEquals(2, #list, 'second chunk starts once the first settled')
  lu.assertEquals('second reply', body_of(list[2].job))
end

-- ===========================================================================
-- A dispatch that never reaches the network releases its claim
-- ===========================================================================

function TestLarkSend:test_token_failure_releases_claim_and_drains_queue()
  -- No credentials -> ensure_token() fails synchronously and no request is
  -- made. The claim must be released, or every later send would sit in a queue
  -- nobody serves.
  config.config.integrations.lark.app_secret = nil
  self.lark.send_message('dropped reply')
  wait(50)
  lu.assertEquals(0, #send_jobs(), 'no request without a token')

  -- Credentials restored: a new reply must go out immediately.
  config.config.integrations.lark.app_secret = 'secret_test'
  self.lark.send_message('later reply')
  wait(50)

  local token_id = find_job('tenant_access_token')
  lu.assertNotNil(token_id, 'token retried for the new reply')
  job.emit_stdout(token_id, { TOKEN_JSON })
  wait(100)

  local list = send_jobs()
  lu.assertEquals(1, #list, 'the abandoned claim was released')
  lu.assertEquals('later reply', body_of(list[1].job))
end

function TestLarkSend:test_spawn_failure_releases_claim()
  -- job.start() returning 0 means neither callback will ever fire. Without a
  -- guard the claim stays taken and the sender is dead for the session.
  self.lark.send_message('warm the token cache')
  wait(50)
  resolve_all_tokens()

  local first = send_jobs()[1]
  lu.assertNotNil(first, 'first delivery started')
  job.emit_exit(first.id, 0)
  wait(150)

  lu.assertEquals(1, #send_jobs(), 'queue drained')

  -- Arm a failing spawner, then queue one reply.
  job.start = function()
    return 0
  end
  self.lark.send_message('cannot spawn')
  wait(100)
  lu.assertEquals(1, #send_jobs(), 'no job recorded for the failed spawn')

  -- Restore the spawner: the sender must still work.
  job.start = self._job_start
  self.lark.send_message('after failure')
  wait(100)

  local list = send_jobs()
  lu.assertEquals(2, #list, 'sender recovered from the failed spawn')
  lu.assertEquals('after failure', body_of(list[2].job))
end

-- ===========================================================================
-- A token outage fails the whole batch, not once per chunk
-- ===========================================================================

--- Content long enough to be split into exactly five chunks.
local FIVE_CHUNKS = string.rep('a', 5 * 30720)

function TestLarkSend:test_token_outage_drops_batch_in_one_step()
  -- Every chunk needs the same token, so an outage fails all of them
  -- identically. Serving them one at a time asked for a token once per chunk
  -- and logged one error per chunk for a single outage.
  self.lark.send_message(FIVE_CHUNKS)
  wait(50)

  lu.assertEquals(1, count_jobs('tenant_access_token'), 'one token request')

  lu.assertTrue(fail_all_tokens(), 'the token request failed')
  wait(100)

  lu.assertEquals(
    1,
    count_jobs('tenant_access_token'),
    'the whole batch gives up on the first outage, no per-chunk retries'
  )
  lu.assertEquals(0, #send_jobs(), 'no delivery without a token')
end

function TestLarkSend:test_sender_recovers_after_a_dropped_batch()
  -- Dropping the batch must leave the sender idle, not stuck holding a claim.
  self.lark.send_message(FIVE_CHUNKS)
  wait(50)
  fail_all_tokens()
  wait(100)

  self.lark.send_message('after the outage')
  wait(50)

  resolve_all_tokens()

  local list = send_jobs()
  lu.assertEquals(1, #list, 'the new reply is delivered on its own')
  lu.assertEquals('after the outage', body_of(list[1].job))
end

function TestLarkSend:test_missing_credentials_drops_batch_silently()
  -- `ensure_token` fails synchronously here (no request is even started),
  -- which is the same global condition: one step, no queue left behind.
  config.config.integrations.lark.app_secret = nil
  self.lark.send_message(FIVE_CHUNKS)
  wait(50)

  lu.assertEquals(0, count_jobs('tenant_access_token'), 'no token request')

  config.config.integrations.lark.app_secret = 'secret_test'
  self.lark.send_message('after the failure')
  wait(50)

  local token_id = find_job('tenant_access_token')
  lu.assertNotNil(token_id, 'a new reply starts a token request')
  job.emit_stdout(token_id, { TOKEN_JSON })
  wait(100)

  local list = send_jobs()
  lu.assertEquals(1, #list, 'queue was emptied, only the new reply is pending')
  lu.assertEquals('after the failure', body_of(list[1].job))
end

