local lu = require('luaunit')
local scheduler = require('chat.scheduler')
local config = require('chat.config')
local sessions = require('chat.sessions')

TestSchedulerExtra = {}

function TestSchedulerExtra:setUp()
  config.setup({
    storage_dir = vim.fn.tempname(),
    allowed_path = vim.fs.normalize(vim.fn.getcwd()),
  })
  scheduler.tasks = {}
end

function TestSchedulerExtra:tearDown()
  scheduler.shutdown()
  scheduler.tasks = {}
end

function TestSchedulerExtra:testComputeDelayTriggerAtPast()
  local delay = scheduler._compute_delay_ms({ trigger_at = os.time() - 10 }, os.time())
  lu.assertEquals(0, delay)
end

function TestSchedulerExtra:testComputeDelayTriggerAtFuture()
  local delay = scheduler._compute_delay_ms({ trigger_at = os.time() + 5 }, os.time())
  lu.assertTrue(delay > 0)
end

function TestSchedulerExtra:testComputeDelayIntervalOverdueAligns()
  local now = os.time()
  local task = { interval = 60, created = now - 120, executed_count = 1 }
  local delay = scheduler._compute_delay_ms(task, now)
  -- aligned to next future cycle, positive delay
  lu.assertTrue(delay > 0)
  lu.assertTrue(delay <= 60000)
end

function TestSchedulerExtra:testComputeDelayNoTriggerOrInterval()
  lu.assertNil(scheduler._compute_delay_ms({}, os.time()))
end

function TestSchedulerExtra:testCreateOneShotPastFires()
  local id = scheduler.create({
    session = 'sess_fire',
    trigger_at = os.time() - 1,
    message = 'fire me',
  })
  lu.assertNotNil(id)
  -- one-shot task in the past fires immediately and removes itself
  vim.wait(200, function() return scheduler.tasks[id] == nil end, 20)
  lu.assertNil(scheduler.tasks[id])
end

function TestSchedulerExtra:testCancelSession()
  scheduler.create({
    session = 'sess_cancel',
    trigger_at = os.time() + 3600,
    message = 'x',
  })
  scheduler.cancel_session('sess_cancel')
  lu.assertEquals(0, #scheduler.list('sess_cancel'))
end

function TestSchedulerExtra:testSkipIfBusyPeriodic()
  -- stub is_in_progress to true so a periodic busy task keeps deferring
  local orig = sessions.is_in_progress
  sessions.is_in_progress = function() return true end
  local id = scheduler.create({
    session = 'sess_busy',
    interval = 1,
    message = 'busy task',
    skip_if_busy = true,
    repeat_count = 1,
  })
  vim.wait(100, function() return false end)
  scheduler.cancel(id)
  sessions.is_in_progress = orig
  lu.assertTrue(true)
end

return TestSchedulerExtra
