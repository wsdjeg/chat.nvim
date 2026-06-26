-- test/tools/schedule_task_spec.lua
-- Tests for schedule_task tool

local lu = require('luaunit')
local schedule_task = require('chat.tools.schedule_task')
local scheduler = require('chat.scheduler')

TestScheduleTask = {}

function TestScheduleTask:setUp()
  -- Clean up any leftover tasks
  for id, _ in pairs(scheduler.tasks) do
    scheduler.cancel(id)
  end
end

function TestScheduleTask:tearDown()
  for id, _ in pairs(scheduler.tasks) do
    scheduler.cancel(id)
  end
end

-- ── Scheme ─────────────────────────────────────────────────

function TestScheduleTask:testScheme()
  local scheme = schedule_task.scheme()
  lu.assertNotNil(scheme)
  lu.assertEquals(scheme.type, 'function')
  lu.assertEquals(scheme['function'].name, 'schedule_task')
  lu.assertNotNil(scheme['function'].description)
  lu.assertNotNil(scheme['function'].parameters)
  lu.assertEquals(scheme['function'].parameters.type, 'object')
  lu.assertNotNil(scheme['function'].parameters.properties.action)
  lu.assertNotNil(scheme['function'].parameters.properties.message)
  lu.assertNotNil(scheme['function'].parameters.properties.delay_seconds)
  lu.assertNotNil(scheme['function'].parameters.properties.trigger_at)
  lu.assertNotNil(scheme['function'].parameters.properties.interval)
  lu.assertNotNil(scheme['function'].parameters.properties.repeat_count)
  lu.assertNotNil(scheme['function'].parameters.properties.task_id)
end

-- ── Create ─────────────────────────────────────────────────

function TestScheduleTask:testCreateWithDelaySeconds()
  local ctx = { session = 'test-session-001' }
  local result = schedule_task.schedule_task({
    action = 'create',
    message = 'Test task with delay',
    delay_seconds = 3600,
  }, ctx)

  lu.assertNil(result.error)
  lu.assertNotNil(result.content)
  lu.assertStrContains(result.content, '定时任务已创建')
  lu.assertStrContains(result.content, 'Test task with delay')
  lu.assertStrContains(result.content, '1 小时')
end

function TestScheduleTask:testCreateWithTriggerAt()
  local ctx = { session = 'test-session-002' }
  local future = os.time() + 7200
  local result = schedule_task.schedule_task({
    action = 'create',
    message = 'Test with trigger_at',
    trigger_at = future,
  }, ctx)

  lu.assertNil(result.error)
  lu.assertNotNil(result.content)
  lu.assertStrContains(result.content, '定时任务已创建')
end

function TestScheduleTask:testCreatePeriodic()
  local ctx = { session = 'test-session-003' }
  local result = schedule_task.schedule_task({
    action = 'create',
    message = 'Periodic check',
    interval = 1800,
  }, ctx)

  lu.assertNil(result.error)
  lu.assertNotNil(result.content)
  lu.assertStrContains(result.content, '定时任务已创建')
  lu.assertStrContains(result.content, '30 分')
end

function TestScheduleTask:testCreatePeriodicWithRepeatCount()
  local ctx = { session = 'test-session-004' }
  local result = schedule_task.schedule_task({
    action = 'create',
    message = 'Limited periodic',
    interval = 60,
    repeat_count = 5,
  }, ctx)

  lu.assertNil(result.error)
  lu.assertStrContains(result.content, '5 次')
end

function TestScheduleTask:testCreateWithoutMessage()
  local ctx = { session = 'test-session' }
  local result = schedule_task.schedule_task({
    action = 'create',
    delay_seconds = 3600,
  }, ctx)

  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'message')
end

function TestScheduleTask:testCreateWithEmptyMessage()
  local ctx = { session = 'test-session' }
  local result = schedule_task.schedule_task({
    action = 'create',
    message = '',
    delay_seconds = 3600,
  }, ctx)

  lu.assertNotNil(result.error)
end

function TestScheduleTask:testCreateWithoutTimingParams()
  local ctx = { session = 'test-session' }
  local result = schedule_task.schedule_task({
    action = 'create',
    message = 'No timing',
  }, ctx)

  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'delay_seconds')
end

function TestScheduleTask:testCreateDelayAndTriggerAtConflict()
  local ctx = { session = 'test-session' }
  local result = schedule_task.schedule_task({
    action = 'create',
    message = 'Conflict',
    delay_seconds = 3600,
    trigger_at = os.time() + 7200,
  }, ctx)

  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, '不能同时使用')
end

function TestScheduleTask:testCreateIntervalAndDelayConflict()
  local ctx = { session = 'test-session' }
  local result = schedule_task.schedule_task({
    action = 'create',
    message = 'Conflict',
    interval = 3600,
    delay_seconds = 600,
  }, ctx)

  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, '不能与一次性参数同时使用')
end

function TestScheduleTask:testCreateIntervalAndTriggerAtConflict()
  local ctx = { session = 'test-session' }
  local result = schedule_task.schedule_task({
    action = 'create',
    message = 'Conflict',
    interval = 3600,
    trigger_at = os.time() + 7200,
  }, ctx)

  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, '不能与一次性参数同时使用')
end

-- ── List ───────────────────────────────────────────────────

function TestScheduleTask:testListEmpty()
  local ctx = { session = 'empty-session' }
  local result = schedule_task.schedule_task({
    action = 'list',
  }, ctx)

  lu.assertNil(result.error)
  lu.assertNotNil(result.content)
  lu.assertStrContains(result.content, '没有定时任务')
end

function TestScheduleTask:testListWithTasks()
  local ctx = { session = 'list-session' }

  -- Create a couple of tasks
  schedule_task.schedule_task({
    action = 'create',
    message = 'List test task 1',
    delay_seconds = 7200,
  }, ctx)

  schedule_task.schedule_task({
    action = 'create',
    message = 'List test task 2',
    interval = 3600,
  }, ctx)

  local result = schedule_task.schedule_task({
    action = 'list',
  }, ctx)

  lu.assertNil(result.error)
  lu.assertNotNil(result.content)
  lu.assertStrContains(result.content, '2 个定时任务')
  lu.assertStrContains(result.content, 'List test task 1')
  lu.assertStrContains(result.content, 'List test task 2')
end

function TestScheduleTask:testListShowsOneShotInfo()
  local ctx = { session = 'oneshot-list' }
  schedule_task.schedule_task({
    action = 'create',
    message = 'One-shot display test',
    delay_seconds = 86400,
  }, ctx)

  local result = schedule_task.schedule_task({ action = 'list' }, ctx)
  lu.assertStrContains(result.content, '一次性')
  lu.assertStrContains(result.content, '还剩')
end

function TestScheduleTask:testListShowsPeriodicInfo()
  local ctx = { session = 'periodic-list' }
  schedule_task.schedule_task({
    action = 'create',
    message = 'Periodic display test',
    interval = 3600,
    repeat_count = 10,
  }, ctx)

  local result = schedule_task.schedule_task({ action = 'list' }, ctx)
  lu.assertStrContains(result.content, '周期性')
  lu.assertStrContains(result.content, '0/10')
end

-- ── Cancel ─────────────────────────────────────────────────

function TestScheduleTask:testCancelExistingTask()
  local ctx = { session = 'cancel-session' }
  local create_result = schedule_task.schedule_task({
    action = 'create',
    message = 'To be cancelled',
    delay_seconds = 3600,
  }, ctx)

  -- Extract task ID from result
  local task_id = create_result.content:match('`(%d+%-%d+)`')
  lu.assertNotNil(task_id)

  local result = schedule_task.schedule_task({
    action = 'cancel',
    task_id = task_id,
  }, ctx)

  lu.assertNil(result.error)
  lu.assertNotNil(result.content)
  lu.assertStrContains(result.content, '已取消')
  lu.assertStrContains(result.content, task_id)
end

function TestScheduleTask:testCancelWithoutTaskId()
  local ctx = { session = 'cancel-session' }
  local result = schedule_task.schedule_task({
    action = 'cancel',
  }, ctx)

  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'task_id')
end

function TestScheduleTask:testCancelNonExistentTask()
  local ctx = { session = 'cancel-session' }
  local result = schedule_task.schedule_task({
    action = 'cancel',
    task_id = 'nonexistent-99999',
  }, ctx)

  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, '未找到')
end

-- ── Unknown Action ─────────────────────────────────────────

function TestScheduleTask:testUnknownAction()
  local ctx = { session = 'test-session' }
  local result = schedule_task.schedule_task({
    action = 'invalid_action',
  }, ctx)

  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, '未知操作')
end

-- ── Default Action ─────────────────────────────────────────

function TestScheduleTask:testDefaultActionIsCreate()
  -- When no action specified, should default to 'create'
  -- But create requires message, so it should error
  local ctx = { session = 'default-session' }
  local result = schedule_task.schedule_task({}, ctx)
  lu.assertNotNil(result.error)
end

-- ── Info ───────────────────────────────────────────────────

function TestScheduleTask:testInfoCreate()
  local info = schedule_task.info('{"action":"create","delay_seconds":3600}', {})
  lu.assertStrContains(info, '创建定时任务')
  lu.assertStrContains(info, '1 小时')
end

function TestScheduleTask:testInfoCreateWithTriggerAt()
  local info = schedule_task.info('{"action":"create","trigger_at":2000000000}', {})
  lu.assertStrContains(info, '创建定时任务')
end

function TestScheduleTask:testInfoCreateWithInterval()
  local info = schedule_task.info('{"action":"create","interval":86400}', {})
  lu.assertStrContains(info, '创建定时任务')
  lu.assertStrContains(info, '1 天')
end

function TestScheduleTask:testInfoList()
  local info = schedule_task.info('{"action":"list"}', {})
  lu.assertStrContains(info, '列出定时任务')
end

function TestScheduleTask:testInfoCancel()
  local info = schedule_task.info('{"action":"cancel","task_id":"12345-67890"}', {})
  lu.assertStrContains(info, '取消任务')
  lu.assertStrContains(info, '12345-67890')
end

function TestScheduleTask:testInfoDefault()
  local info = schedule_task.info('{}', {})
  lu.assertStrContains(info, '创建定时任务')
end

function TestScheduleTask:testInfoStringInput()
  local info = schedule_task.info('{"action":"list"}', {})
  lu.assertStrContains(info, '列出定时任务')
end

function TestScheduleTask:testInfoInvalidJson()
  -- Should not crash with invalid JSON
  local info = schedule_task.info('not-json', {})
  lu.assertStrContains(info, 'schedule_task')
end

-- ── Format Duration Edge Cases ─────────────────────────────

function TestScheduleTask:testCreateVeryShortDelay()
  local ctx = { session = 'short-delay' }
  local result = schedule_task.schedule_task({
    action = 'create',
    message = 'Very short',
    delay_seconds = 30,
  }, ctx)

  lu.assertNil(result.error)
  lu.assertStrContains(result.content, '30 秒')
end

function TestScheduleTask:testCreateLongDelay()
  local ctx = { session = 'long-delay' }
  local result = schedule_task.schedule_task({
    action = 'create',
    message = 'Very long',
    delay_seconds = 2592000, -- 30 days
  }, ctx)

  lu.assertNil(result.error)
  lu.assertStrContains(result.content, '30 天')
end

function TestScheduleTask:testCreateWithNilAction()
  -- action is nil, should default to 'create'
  local ctx = { session = 'nil-action' }
  local result = schedule_task.schedule_task(nil, ctx)
  lu.assertNotNil(result.error) -- needs message
end

return TestScheduleTask

