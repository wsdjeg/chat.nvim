-- Coverage for lua/chat/integrations/lark/poll.lua.
--
-- The poll loop is a chain: one container request per step, the next one
-- scheduled from the previous `done()`. These specs pin the chain's edges:
-- what a tick does when the poller stops mid-round, how a brand new container
-- gets its cursor, and how non-text payloads reach the shared handler.
local lu = require('luaunit')
local job = require('job')
local config = require('chat.config')

local storage_dir

--- Reload the integration with fresh state, pointing STATE_FILE at temp storage.
local function fresh_lark(lark_extra)
  package.loaded['chat.integrations.lark'] = nil
  -- The tenant token cache is shared and survives reloads.
  require('chat.integrations.lark.auth').reset()
  -- config.setup() deep-merges: drop lists from previous specs explicitly.
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

TestLarkPoll = {}

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
    msg_type = opts.msg_type or 'text',
    body = {
      content = opts.content
        or vim.json.encode({ text = text }),
    },
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

function TestLarkPoll:setUp()
  job.reset()
  job.intercept()
  storage_dir = vim.fn.tempname() .. '_lark_poll_test/'
  vim.fn.mkdir(storage_dir, 'p')
  self.lark = fresh_lark()
end

function TestLarkPoll:tearDown()
  job.intercept(false)
  if self.lark then
    self.lark.disconnect()
  end
  wait(100)
  vim.fn.delete(storage_dir, 'rf')
end

-- ===========================================================================
-- disconnect() stops the round it interrupted
-- ===========================================================================

function TestLarkPoll:test_disconnect_aborts_container_traversal()
  -- The chain owns `state.is_fetching` and the next step: a response that
  -- settles after disconnect() must end the round, not process its body and
  -- fetch the containers still queued.
  --
  -- Sorted ids: 'oc_b' < 'oc_main', so oc_b is the step in flight.
  write_state({
    containers = {
      oc_b = { chat_type = 'group' },
      oc_main = { chat_type = 'group' },
    },
  })

  local received = {}
  self.lark = fresh_lark()
  self.lark.connect(function(msg)
    received[#received + 1] = msg
  end)
  wait(200)
  feed_token_and_bot()

  local first_id = find_job('container_id=oc_b')
  lu.assertNotNil(first_id, 'first container fetched')
  lu.assertNil(
    find_job('container_id=oc_main'),
    'second container waits for the first to settle'
  )

  local before = read_state()
  lu.assertNotNil(before)

  -- Stop the poller while the request is still in flight.
  self.lark.disconnect()
  wait(50)

  -- ... then let the request settle. Its body holds a perfectly valid group
  -- message (bot mention + allowed sender), so only the chain check can keep
  -- it out of the handler.
  local new_ms = tostring((os.time() + 60) * 1000)
  job.emit_stdout(first_id, {
    vim.json.encode({
      data = {
        items = {
          make_msg('om_after_disconnect', 'hello', {
            chat_id = 'oc_b',
            create_time = new_ms,
            mentions = { { id = 'ou_bot_1', name = 'chat.nvim' } },
          }),
        },
      },
    }),
  })
  job.emit_exit(first_id, 0)
  wait(200)

  lu.assertEquals(0, #received, 'a stopped poller must not answer')
  lu.assertNil(
    find_job('container_id=oc_main'),
    'the queued container must not be fetched'
  )

  -- Neither cursor nor dedup cache moved: the body was dropped, not handled.
  local after = read_state()
  lu.assertNotNil(after)
  lu.assertEquals(
    before.containers.oc_b.last_seen_time,
    after.containers.oc_b.last_seen_time,
    'cursor must not advance after disconnect'
  )
  lu.assertNil(
    after.processed_ids.om_after_disconnect,
    'message must not be marked processed'
  )
end

-- ===========================================================================
-- A container registered while running starts at "now", not in the past
-- ===========================================================================

function TestLarkPoll:test_container_added_while_running_owns_a_cursor()
  -- connect() resets the cursors of every container it loads, but a container
  -- registered afterwards (add_container, or a p2p chat provisioned later)
  -- would otherwise start with no cursor at all. The first fetch then omits
  -- `start_time`, the API answers with the newest 50 messages and each one is
  -- treated as unread: a peer's whole history gets answered in one burst.
  self.lark.connect(function() end)
  wait(200)
  feed_token_and_bot()

  -- Settle the main fetch so the chain is idle before registering.
  deliver('oc_main', {})

  local before = os.time()
  lu.assertTrue(
    self.lark.add_container('oc_new', { chat_type = 'p2p', peer = 'ou_peer' }),
    'container registered'
  )

  local cursor
  for _, ctr in ipairs(self.lark.get_containers()) do
    if ctr.chat_id == 'oc_new' then
      cursor = ctr.last_seen_time
    end
  end
  lu.assertNotNil(cursor, 'a newly registered container must own a cursor')
  cursor = tonumber(cursor)
  lu.assertTrue(cursor >= before * 1000, 'cursor starts at registration time')
  lu.assertTrue(cursor <= (os.time() + 1) * 1000, 'cursor is not in the future')

  -- Persisted with the container, so the very first fetch uses it even after
  -- an immediate restart.
  local state = read_state()
  lu.assertNotNil(state)
  lu.assertNotNil(state.containers.oc_new)
  lu.assertNotNil(
    state.containers.oc_new.last_seen_time,
    'cursor must survive a reload'
  )
end

function TestLarkPoll:test_stopped_poller_skips_request_after_token_resolution()
  -- `ensure_token` is asynchronous, so a tick can be inside it when
  -- disconnect() runs. Starting the request afterwards would keep a stopped
  -- poller reading containers.
  write_state({
    containers = {
      oc_b = { chat_type = 'group' },
    },
  })

  local received = {}
  self.lark = fresh_lark()
  self.lark.connect(function(msg)
    received[#received + 1] = msg
  end)
  wait(200)

  -- The token request is in flight, no fetch has been built yet.
  local token_id = find_job('tenant_access_token')
  lu.assertNotNil(token_id, 'token request started')
  lu.assertNil(find_job('container_id=oc_b'), 'no fetch before a token')

  self.lark.disconnect()
  wait(50)

  -- Resolve the token now: the callback runs with a stale chain.
  job.emit_stdout(token_id, { TOKEN_JSON })
  wait(200)

  lu.assertNil(
    find_job('container_id=oc_b'),
    'a fetch must not start after disconnect'
  )
  lu.assertEquals(0, #received)
end

-- ===========================================================================
-- The poll timer handle is released on disconnect
-- ===========================================================================

function TestLarkPoll:test_disconnect_closes_poll_timer()
  -- connect() allocates a fresh timer every time, so a disconnect() that only
  -- stops it leaks one uv handle per connect/disconnect cycle. The handle is
  -- captured by wrapping new_timer: `state.timer` is cleared by disconnect(),
  -- so the reference has to be kept outside the integration.
  local created = {}
  local real_new_timer = vim.uv.new_timer
  vim.uv.new_timer = function()
    local timer = real_new_timer()
    created[#created + 1] = timer
    return timer
  end

  local ok, err = pcall(function()
    self.lark.connect(function() end)
    wait(200)

    -- The polling timer, plus one watchdog per fetched container.
    lu.assertTrue(#created > 0, 'timers created while polling')

    self.lark.disconnect()
    wait(100)
  end)

  vim.uv.new_timer = real_new_timer

  lu.assertTrue(ok, tostring(err))
  -- A stopped-but-open handle keeps libuv resources for the whole process
  -- lifetime, and a closed one reports is_closing() == true.
  for index, timer in ipairs(created) do
    lu.assertTrue(
      timer:is_closing(),
      'timer #' .. index .. ' must be closed, not only stopped'
    )
  end
end


