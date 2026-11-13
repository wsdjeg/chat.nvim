-- Coverage for lua/chat/integrations/lark/p2p.lua.
--
-- create_p2p() chains two requests (greeting -> message detail) and
-- provision_p2p() walks a list by chaining from its callback. Both chains depend
-- on `callback` firing exactly once, including the paths where `job.start()`
-- fails and returns 0: such a job never calls on_exit, so without an explicit
-- callback the chain -- and the whole provisioning run behind it -- stops
-- silently.
local lu = require('luaunit')
local job = require('job')
local config = require('chat.config')
local auth = require('chat.integrations.lark.auth')

local storage_dir

--- Reload the integration with fresh state, pointing STATE_FILE at temp storage.
local function fresh_lark(lark_extra)
  package.loaded['chat.integrations.lark'] = nil
  auth.reset()
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

TestLarkP2p = {}

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

--- How many jobs match the fragment (0 when none).
local function count_jobs(fragment)
  local count = 0
  for _, j in pairs(job.jobs) do
    if table.concat(j.cmd, ' '):find(fragment, 1, true) then
      count = count + 1
    end
  end
  return count
end

local function contains_p2p_container(lark, peer)
  for _, ctr in ipairs(lark.get_containers()) do
    if ctr.chat_type == 'p2p' and ctr.peer == peer then
      return true
    end
  end
  return false
end

function TestLarkP2p:setUp()
  job.reset()
  job.intercept()
  storage_dir = vim.fn.tempname() .. '_lark_p2p_test/'
  vim.fn.mkdir(storage_dir, 'p')
  self.lark = fresh_lark({
    p2p = { allow = { 'ou_peer', 'ou_a', 'ou_b' }, greeting = 'hello!' },
  })
  self._job_start = job.start
end

function TestLarkP2p:tearDown()
  job.start = self._job_start
  job.intercept(false)
  if self.lark then
    self.lark.disconnect()
  end
  wait(100)
  vim.fn.delete(storage_dir, 'rf')
end

-- ===========================================================================
-- Failed spawns still settle the callback
-- ===========================================================================

function TestLarkP2p:test_greeting_spawn_failure_reports_error()
  -- The greeting request is what creates the conversation. If it can not be
  -- spawned, no request exists and no on_exit will ever fire: the caller has
  -- to learn that instead of waiting for a callback that never comes.
  auth._set_token('t-seeded')
  job.start = function()
    return 0
  end

  local result
  self.lark.create_p2p('ou_peer', function(ok, msg)
    result = { ok = ok, msg = msg }
  end)
  wait(50)

  lu.assertNotNil(result, 'callback must fire when the greeting fails to spawn')
  lu.assertFalse(result.ok)
  lu.assertStrContains(result.msg, 'greeting')
  lu.assertEquals(0, count_jobs('receive_id_type=open_id'))
  lu.assertFalse(
    contains_p2p_container(self.lark, 'ou_peer'),
    'a failed greeting must not register a container'
  )
end

function TestLarkP2p:test_reveal_spawn_failure_reports_error()
  -- Step 2 (message detail) is spawned from the greeting's on_exit. A failure
  -- there strands the chain at the same place, one step later.
  auth._set_token('t-seeded')

  local result
  self.lark.create_p2p('ou_peer', function(ok, msg)
    result = { ok = ok, msg = msg }
  end)
  wait(50)

  local send_id, send_job = find_job('receive_id_type=open_id')
  lu.assertNotNil(send_job, 'greeting started')

  -- The greeting answers with a message id, as a successful POST would.
  job.emit_stdout(send_id, {
    vim.json.encode({ code = 0, data = { message_id = 'om_greet' } }),
  })

  -- The lookup can not be spawned from this point on.
  job.start = function()
    return 0
  end
  job.emit_exit(send_id, 0)
  wait(50)

  lu.assertNotNil(result, 'callback must fire when the lookup fails to spawn')
  lu.assertFalse(result.ok)
  lu.assertStrContains(result.msg, 'lookup')
  lu.assertNil(find_job('/im/v1/messages/om_greet'))
  lu.assertFalse(contains_p2p_container(self.lark, 'ou_peer'))
end

-- ===========================================================================
-- provision_p2p() keeps walking when a chat can not be opened
-- ===========================================================================

function TestLarkP2p:test_provision_walk_survives_spawn_failure()
  -- Every entry fails identically here. The walk is chained from create_p2p's
  -- callback, so a swallowed failure would stop it after the first entry and
  -- never report completion.
  auth._set_token('t-seeded')
  self.lark.connect(function() end)
  wait(200)

  -- Settle the main container fetch started by the first tick: an unanswered
  -- request leaves its 5s watchdog alive, and that timer would fire in a later
  -- spec as a stray job.
  local fetch_id = find_job('container_id=oc_main')
  if fetch_id then
    job.emit_stdout(fetch_id, { vim.json.encode({ data = { items = {} } }) })
    job.emit_exit(fetch_id, 0)
    wait(50)
  end

  -- connect() already greets the allow list, so the baseline is whatever it
  -- started; only *new* greeting requests matter from here on.
  local before = count_jobs('receive_id_type=open_id')

  job.start = function()
    return 0
  end

  local walked = 0
  self.lark.provision_p2p({ 'ou_a', 'ou_b' }, function()
    walked = walked + 1
  end)
  wait(150)

  lu.assertEquals(1, walked, 'the walk must finish instead of stalling')
  lu.assertEquals(
    before,
    count_jobs('receive_id_type=open_id'),
    'no greeting request can be started while spawning fails'
  )
  lu.assertFalse(contains_p2p_container(self.lark, 'ou_a'))
  lu.assertFalse(contains_p2p_container(self.lark, 'ou_b'))
end

