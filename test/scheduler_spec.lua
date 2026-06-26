-- test/scheduler_spec.lua
-- Tests for chat.scheduler module

local lu = require('luaunit')
local scheduler = require('chat.scheduler')

TestScheduler = {}

function TestScheduler:setUp()
  -- Clean up any leftover tasks from previous tests
  for id, _ in pairs(scheduler.tasks) do
    scheduler.cancel(id)
  end
end

function TestScheduler:tearDown()
  -- Clean up
  for id, _ in pairs(scheduler.tasks) do
    scheduler.cancel(id)
  end
end

-- ── Create ─────────────────────────────────────────────────

function TestScheduler:testCreateOneShotWithDelay()
  local id = scheduler.create({
    session = 'test-session',
    message = 'Test one-shot task',
    trigger_at = os.time() + 3600,
  })
  lu.assertNotNil(id)
  lu.assertTrue(type(id) == 'string')
  lu.assertTrue(#id > 0)

  local task = scheduler.get(id)
  lu.assertNotNil(task)
  lu.assertEquals(task.session, 'test-session')
  lu.assertEquals(task.message, 'Test one-shot task')
  lu.assertEquals(task.executed_count, 0)
  lu.assertNotNil(task.trigger_at)
  lu.assertNil(task.interval)
end

function TestScheduler:testCreatePeriodicTask()
  local id = scheduler.create({
    session = 'test-session',
    message = 'Test periodic task',
    interval = 3600,
  })
  lu.assertNotNil(id)

  local task = scheduler.get(id)
  lu.assertNotNil(task)
  lu.assertEquals(task.interval, 3600)
  lu.assertNil(task.trigger_at)
  lu.assertEquals(task.executed_count, 0)
end

function TestScheduler:testCreatePeriodicWithRepeatCount()
  local id = scheduler.create({
    session = 'test-session',
    message = 'Limited periodic task',
    interval = 60,
    repeat_count = 3,
  })
  lu.assertNotNil(id)

  local task = scheduler.get(id)
  lu.assertEquals(task.repeat_count, 3)
  lu.assertEquals(task.interval, 60)
end

function TestScheduler:testCreateMultipleTasks()
  local id1 = scheduler.create({
    session = 'session-a',
    message = 'Task 1',
    trigger_at = os.time() + 7200,
  })
  local id2 = scheduler.create({
    session = 'session-b',
    message = 'Task 2',
    interval = 1800,
  })

  lu.assertNotEquals(id1, id2)
  lu.assertNotNil(scheduler.get(id1))
  lu.assertNotNil(scheduler.get(id2))
end

-- ── List ───────────────────────────────────────────────────

function TestScheduler:testListAllTasks()
  scheduler.create({
    session = 'list-session',
    message = 'List test 1',
    trigger_at = os.time() + 3600,
  })
  scheduler.create({
    session = 'list-session',
    message = 'List test 2',
    interval = 600,
  })

  local tasks = scheduler.list()
  lu.assertEquals(#tasks, 2)
end

function TestScheduler:testListFilterBySession()
  scheduler.create({
    session = 'session-x',
    message = 'X task',
    trigger_at = os.time() + 3600,
  })
  scheduler.create({
    session = 'session-y',
    message = 'Y task',
    interval = 600,
  })

  local x_tasks = scheduler.list('session-x')
  lu.assertEquals(#x_tasks, 1)
  lu.assertEquals(x_tasks[1].session, 'session-x')

  local y_tasks = scheduler.list('session-y')
  lu.assertEquals(#y_tasks, 1)
  lu.assertEquals(y_tasks[1].session, 'session-y')
end

function TestScheduler:testListEmpty()
  local tasks = scheduler.list()
  lu.assertEquals(#tasks, 0)
end

function TestScheduler:testListHasRemainingSeconds()
  local id = scheduler.create({
    session = 'remaining-test',
    message = 'Remaining test',
    trigger_at = os.time() + 7200,
  })

  local tasks = scheduler.list()
  local found = false
  for _, t in ipairs(tasks) do
    if t.id == id then
      lu.assertNotNil(t.remaining_seconds)
      lu.assertTrue(t.remaining_seconds > 0)
      lu.assertTrue(t.remaining_seconds <= 7200)
      found = true
      break
    end
  end
  lu.assertTrue(found)
end

function TestScheduler:testListPeriodicRemainingSeconds()
  local id = scheduler.create({
    session = 'periodic-remaining',
    message = 'Periodic remaining',
    interval = 3600,
  })

  local tasks = scheduler.list()
  local found = false
  for _, t in ipairs(tasks) do
    if t.id == id then
      lu.assertNotNil(t.remaining_seconds)
      lu.assertTrue(t.remaining_seconds > 0)
      found = true
      break
    end
  end
  lu.assertTrue(found)
end

function TestScheduler:testListSortedByCreated()
  scheduler.create({
    session = 'sort-test',
    message = 'First',
    trigger_at = os.time() + 10000,
  })
  scheduler.create({
    session = 'sort-test',
    message = 'Second',
    trigger_at = os.time() + 5000,
  })

  local tasks = scheduler.list()
  lu.assertTrue(#tasks >= 2)
  -- Should be sorted by created time ascending
  for i = 2, #tasks do
    lu.assertTrue(tasks[i].created >= tasks[i-1].created)
  end
end

-- ── Cancel ─────────────────────────────────────────────────

function TestScheduler:testCancelExistingTask()
  local id = scheduler.create({
    session = 'cancel-test',
    message = 'To be cancelled',
    trigger_at = os.time() + 3600,
  })

  lu.assertNotNil(scheduler.get(id))
  local ok = scheduler.cancel(id)
  lu.assertTrue(ok)
  lu.assertNil(scheduler.get(id))
end

function TestScheduler:testCancelNonExistentTask()
  local ok = scheduler.cancel('nonexistent-id-12345')
  lu.assertFalse(ok)
end

function TestScheduler:testCancelTwice()
  local id = scheduler.create({
    session = 'double-cancel',
    message = 'Double cancel',
    trigger_at = os.time() + 3600,
  })

  lu.assertTrue(scheduler.cancel(id))
  lu.assertFalse(scheduler.cancel(id)) -- Second cancel should fail
end

-- ── Cancel Session ─────────────────────────────────────────

function TestScheduler:testCancelSession()
  scheduler.create({
    session = 'multi-task-session',
    message = 'Task A',
    trigger_at = os.time() + 3600,
  })
  scheduler.create({
    session = 'multi-task-session',
    message = 'Task B',
    interval = 600,
  })
  scheduler.create({
    session = 'other-session',
    message = 'Task C',
    trigger_at = os.time() + 7200,
  })

  scheduler.cancel_session('multi-task-session')

  -- Tasks from multi-task-session should be gone
  local remaining = scheduler.list('multi-task-session')
  lu.assertEquals(#remaining, 0)

  -- Other session tasks should remain
  local other = scheduler.list('other-session')
  lu.assertEquals(#other, 1)
end

function TestScheduler:testCancelSessionNoTasks()
  -- Should not error when cancelling session with no tasks
  scheduler.cancel_session('empty-session')
  lu.assertTrue(true)
end

-- ── Get ────────────────────────────────────────────────────

function TestScheduler:testGetExistingTask()
  local id = scheduler.create({
    session = 'get-test',
    message = 'Get me',
    trigger_at = os.time() + 3600,
  })

  local task = scheduler.get(id)
  lu.assertNotNil(task)
  lu.assertEquals(task.id, id)
  lu.assertEquals(task.session, 'get-test')
  lu.assertEquals(task.message, 'Get me')
end

function TestScheduler:testGetNonExistentTask()
  local task = scheduler.get('no-such-id')
  lu.assertNil(task)
end

-- ── Save / Init (persistence) ──────────────────────────────

function TestScheduler:testSaveDoesNotError()
  scheduler.create({
    session = 'save-test',
    message = 'Save me',
    trigger_at = os.time() + 3600,
  })

  -- save() should not throw
  scheduler.save()
  lu.assertTrue(true)
end

function TestScheduler:testSaveAndInitRoundTrip()
  -- Create a task
  local id = scheduler.create({
    session = 'roundtrip-session',
    message = 'Roundtrip task',
    trigger_at = os.time() + 86400, -- far future
  })

  -- Save to disk
  scheduler.save()

  -- Clear in-memory tasks WITHOUT calling cancel (which saves to disk)
  for tid, task in pairs(scheduler.tasks) do
    if task.timer then
      task.timer:stop()
      task.timer:close()
    end
    scheduler.tasks[tid] = nil
  end
  lu.assertEquals(#scheduler.list(), 0)

  -- Re-init from disk
  scheduler.init()

  -- Task should be restored
  local tasks = scheduler.list('roundtrip-session')
  lu.assertEquals(#tasks, 1)
  lu.assertEquals(tasks[1].id, id)
  lu.assertEquals(tasks[1].message, 'Roundtrip task')

  -- Clean up
  scheduler.cancel(id)
end


function TestScheduler:testInitSkipsExpiredTasks()
  -- Create an expired task directly in the save file
  local old_id = '9999999999-12345'
  scheduler.tasks[old_id] = {
    id = old_id,
    session = 'expired-session',
    trigger_at = os.time() - 3600, -- 1 hour ago
    message = 'Expired task',
    created = os.time() - 7200,
    executed_count = 0,
  }
  scheduler.save()

  -- Clear and re-init
  scheduler.tasks = {}
  scheduler.init()

  -- Expired task should not be loaded
  lu.assertNil(scheduler.get(old_id))
end

function TestScheduler:testInitLoadsPeriodicEvenIfOverdue()
  local old_id = '8888888888-54321'
  scheduler.tasks[old_id] = {
    id = old_id,
    session = 'overdue-periodic',
    interval = 60,
    message = 'Overdue periodic',
    created = os.time() - 7200,
    executed_count = 5,
  }
  scheduler.save()

  -- Clear and re-init
  scheduler.tasks = {}
  scheduler.init()

  -- Periodic task should be loaded even if overdue
  local task = scheduler.get(old_id)
  lu.assertNotNil(task)
  lu.assertEquals(task.interval, 60)

  -- Clean up
  scheduler.cancel(old_id)
end

-- ── Edge Cases ─────────────────────────────────────────────

function TestScheduler:testCreateTaskWithPastTrigger()
  -- Creating a task with past trigger_at should still work
  -- (it will fire immediately)
  local id = scheduler.create({
    session = 'past-trigger',
    message = 'Past trigger',
    trigger_at = os.time() - 3600,
  })
  lu.assertNotNil(id)
  lu.assertNotNil(scheduler.get(id))
  scheduler.cancel(id)
end

function TestScheduler:testShutdownClearsAllTimers()
  scheduler.create({
    session = 'shutdown-test',
    message = 'Shutdown task',
    trigger_at = os.time() + 3600,
  })

  scheduler.shutdown()

  -- All timers should be cleared
  for _, task in pairs(scheduler.tasks) do
    lu.assertNil(task.timer)
  end
end

function TestScheduler:testGenerateIdIsUnique()
  local ids = {}
  for _ = 1, 100 do
    local id = scheduler.create({
      session = 'unique-test',
      message = 'Unique',
      trigger_at = os.time() + 99999,
    })
    lu.assertNil(ids[id], 'Duplicate ID generated: ' .. id)
    ids[id] = true
  end

  -- Clean up
  for id, _ in pairs(ids) do
    scheduler.cancel(id)
  end
end

return TestScheduler

